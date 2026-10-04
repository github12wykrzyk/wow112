include!("world.rs");

const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
const SUMMONING_PORTAL_ENTRY: i32 = 36727;
const GAMEOBJECT_TYPE_RITUAL: i32 = 18;
const PORTAL_RETRY_GAP_MS: u64 = 180;
const PORTAL_DEFAULT_ATTEMPTS: u32 = 3;

#[derive(Debug, Clone)]
struct PortalAttemptState {
    entry: i32,
    type_id: i32,
    attempts: u32,
    last_attempt: Option<Instant>,
}

fn portal_attempt_limit() -> u32 {
    env::var("WOW112_PORTAL_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(PORTAL_DEFAULT_ATTEMPTS)
        .clamp(1, 8)
}

fn portal_mask_match(mask: &UpdateMask) -> Option<(i32, i32)> {
    match mask {
        UpdateMask::GameObject(gameobject) => {
            let entry = gameobject.object_entry().unwrap_or(0);
            let type_id = gameobject.gameobject_type_id().unwrap_or(-1);
            if entry == SUMMONING_PORTAL_ENTRY || type_id == GAMEOBJECT_TYPE_RITUAL {
                Some((entry, type_id))
            } else {
                None
            }
        }
        _ => None,
    }
}

fn collect_portal_candidates(
    objects: &[Object],
    portals: &mut std::collections::HashMap<u64, PortalAttemptState>,
) {
    for object in objects {
        let candidate = match object {
            Object::Values { guid1, mask1 } => {
                portal_mask_match(mask1).map(|meta| (guid1.guid(), meta))
            }
            Object::CreateObject { guid3, mask2, .. }
            | Object::CreateObject2 { guid3, mask2, .. } => {
                portal_mask_match(mask2).map(|meta| (guid3.guid(), meta))
            }
            _ => None,
        };

        if let Some((guid, (entry, type_id))) = candidate {
            portals.entry(guid).or_insert_with(|| {
                println!(
                    "[PORTAL] discovered guid=0x{guid:016X} entry={entry} type={type_id} match={}{}",
                    if entry == SUMMONING_PORTAL_ENTRY { "entry" } else { "" },
                    if type_id == GAMEOBJECT_TYPE_RITUAL {
                        if entry == SUMMONING_PORTAL_ENTRY { "+ritual" } else { "ritual" }
                    } else {
                        ""
                    }
                );
                PortalAttemptState {
                    entry,
                    type_id,
                    attempts: 0,
                    last_attempt: None,
                }
            });
        }
    }
}

fn inspect_portal_update_packet(
    opcode: u16,
    payload: &[u8],
    portals: &mut std::collections::HashMap<u64, PortalAttemptState>,
) {
    if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
        return;
    }

    let message = match parse_raw_server_message(opcode, payload) {
        Ok(message) => message,
        Err(error) => {
            println!(
                "[PORTAL-DIAG] object update skipped opcode=0x{opcode:04X} payload={} reason={error}",
                payload.len()
            );
            return;
        }
    };

    match message {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message) => {
            collect_portal_candidates(&message.objects, portals);
        }
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message) => {
            collect_portal_candidates(&message.objects, portals);
        }
        _ => {}
    }
}

fn service_portal_clicks(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    portals: &mut std::collections::HashMap<u64, PortalAttemptState>,
    max_attempts: u32,
) -> Result<(), String> {
    let now = Instant::now();
    let mut due = Vec::new();

    for (guid, state) in portals.iter() {
        if state.attempts >= max_attempts {
            continue;
        }
        let ready = match state.last_attempt {
            None => true,
            Some(last) => now.duration_since(last) >= Duration::from_millis(PORTAL_RETRY_GAP_MS),
        };
        if ready {
            due.push(*guid);
        }
    }

    for guid in due {
        let state = portals.get_mut(&guid).unwrap();
        let attempt = state.attempts + 1;
        println!(
            "[PORTAL] USE attempt={attempt}/{max_attempts} guid=0x{guid:016X} entry={} type={}",
            state.entry, state.type_id
        );
        write_encrypted_raw(
            stream,
            crypto.encrypter(),
            CMSG_GAMEOBJ_USE_OPCODE,
            &guid.to_le_bytes(),
        )?;
        state.attempts = attempt;
        state.last_attempt = Some(Instant::now());
    }

    Ok(())
}

fn portal_click_loop(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    soak_seconds: u64,
) -> Result<(), String> {
    let previous_timeout = stream.read_timeout().ok().flatten();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set portal read timeout failed: {e}"))?;

    let max_attempts = portal_attempt_limit();
    let deadline = if soak_seconds == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_secs(soak_seconds))
    };
    let mut portals = std::collections::HashMap::<u64, PortalAttemptState>::new();
    let mut last_ping = Instant::now();
    let mut ping_sequence = 1u32;
    let mut awaiting_pong: Option<(u32, Instant)> = None;

    println!(
        "[PORTAL] CLICKER ACTIVE entry={} ritual_type={} attempts={} retry_gap_ms={} duration={}",
        SUMMONING_PORTAL_ENTRY,
        GAMEOBJECT_TYPE_RITUAL,
        max_attempts,
        PORTAL_RETRY_GAP_MS,
        if soak_seconds == 0 { "infinite".to_string() } else { format!("{soak_seconds}s") }
    );

    loop {
        if deadline.is_some_and(|value| Instant::now() >= value) {
            println!("[PORTAL] soak complete discovered={}", portals.len());
            let _ = stream.set_read_timeout(previous_timeout);
            return Ok(());
        }

        service_portal_clicks(stream, crypto, &mut portals, max_attempts)?;

        if let Some((sequence, sent_at)) = awaiting_pong {
            if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                return Err(format!("world keepalive pong timeout sequence={sequence}"));
            }
        }

        if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS) && awaiting_pong.is_none() {
            let mut payload = Vec::with_capacity(8);
            payload.extend_from_slice(&ping_sequence.to_le_bytes());
            payload.extend_from_slice(&0u32.to_le_bytes());
            write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
            println!("[PORTAL] keepalive ping sequence={ping_sequence}");
            awaiting_pong = Some((ping_sequence, Instant::now()));
            ping_sequence = ping_sequence.wrapping_add(1);
            last_ping = Instant::now();
        }

        match read_encrypted_raw(stream, crypto.decrypter()) {
            Ok((opcode, payload)) => {
                if opcode == SMSG_PONG_OPCODE {
                    if payload.len() >= 4 {
                        let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                        println!("[PORTAL] keepalive pong sequence={sequence}");
                        if awaiting_pong.map(|value| value.0) == Some(sequence) {
                            awaiting_pong = None;
                        }
                    }
                    continue;
                }
                inspect_portal_update_packet(opcode, &payload, &mut portals);
                service_portal_clicks(stream, crypto, &mut portals, max_attempts)?;
            }
            Err(error)
                if error.contains("TimedOut")
                    || error.contains("timed out")
                    || error.contains("WouldBlock") =>
            {
                continue;
            }
            Err(error) => return Err(error),
        }
    }
}

pub fn login_portal_clicker(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
) -> Result<(), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .map_err(|e| format!("set world read timeout failed: {e}"))?;

    let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
        .map_err(|e| format!("read world auth challenge failed: {e:?}"))?;

    let seed = ProofSeed::new();
    let seed_value = seed.seed();
    let normalized_username = NormalizedString::new(username)
        .map_err(|e| format!("invalid account name for world auth: {e:?}"))?;
    let (client_proof, mut crypto) = seed.into_client_header_crypto(
        &normalized_username,
        session_key,
        challenge.server_seed,
    );

    let auth_session = CMSG_AUTH_SESSION {
        build: OCTOWOW_WORLD_BUILD,
        server_id: server_id as u32,
        username: username.to_string(),
        client_seed: seed_value,
        client_proof,
        addon_info: octo_fingerprint_addons(),
    };

    let mut auth_wire = Vec::new();
    auth_session
        .write_unencrypted_client(&mut auth_wire)
        .map_err(|e| format!("encode world auth session failed: {e:?}"))?;
    stream
        .write_all(&auth_wire)
        .map_err(|e| format!("write world auth session failed: {e:?}"))?;

    world_diag_peek(stream, "auth-response-raw", Duration::from_millis(1500));
    skip_octowow_addon_info(stream, crypto.decrypter())?;

    let auth_response = {
        let mut found = None;
        for index in 0..16usize {
            let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read world pre-auth opcode failed: {e:?}"))?;
            match opcode {
                ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) => {
                    found = Some(response);
                    break;
                }
                other => {
                    if index < 8 {
                        println!("[WORLD] pre-auth rx[{index}] {other:?}");
                    }
                }
            }
        }
        found.ok_or_else(|| "world auth response not received within 16 packets".to_string())?
    };

    if !matches!(*auth_response, SMSG_AUTH_RESPONSE::AuthOk { .. }) {
        return Err(format!("world auth rejected: {auth_response:?}"));
    }
    println!("[WORLD] auth PASS world-build={OCTOWOW_WORLD_BUILD}");

    CMSG_CHAR_ENUM {}
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write character enum request failed: {e:?}"))?;
    let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
        &mut *stream,
        crypto.decrypter(),
    )
    .map_err(|e| format!("read character enum failed: {e:?}"))?;

    if characters.characters.is_empty() {
        return Err("account has no characters".to_string());
    }
    println!("[WORLD] characters={}", characters.characters.len());
    for (index, character) in characters.characters.iter().enumerate() {
        println!("[WORLD] character[{index}] name={}", character.name);
    }

    let selected = match character_name {
        Some(wanted) => characters
            .characters
            .iter()
            .find(|character| character.name.eq_ignore_ascii_case(wanted))
            .ok_or_else(|| format!("character not found: {wanted}"))?,
        None => &characters.characters[0],
    };
    println!("[WORLD] logging character={}", selected.name);
    CMSG_PLAYER_LOGIN { guid: selected.guid }
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write player login failed: {e:?}"))?;

    let mut login_verified = false;
    for index in 0..256usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
            .map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;
        if index < 24 {
            println!("[WORLD] rx[{index}] {opcode:?}");
        }
        if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
            println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS");
            login_verified = true;
            break;
        }
    }
    if !login_verified {
        return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string());
    }

    portal_click_loop(stream, &mut crypto, soak_seconds)?;
    println!("[PORTAL] CLICKER PASS");
    Ok(())
}
