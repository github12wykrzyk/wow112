include!("world.rs");

use wow_world_messages::vanilla::CMSG_GROUP_INVITE;

const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
const CMSG_GROUP_ACCEPT_OPCODE: u32 = 0x0072;
const CMSG_GROUP_SET_LEADER_OPCODE: u32 = 0x0078;
const SMSG_GROUP_LIST_OPCODE: u16 = 0x007D;
const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
const SUMMONING_PORTAL_ENTRY: i32 = 36727;
const GAMEOBJECT_TYPE_RITUAL: i32 = 18;
const PORTAL_RETRY_GAP_MS: u64 = 180;
const PORTAL_DEFAULT_ATTEMPTS: u32 = 3;
const PARTY_INVITE_RETRY_GAP_MS: u64 = 5000;
const PARTY_LEADER_RETRY_GAP_MS: u64 = 5000;
const DEFAULT_SUMMONER_NAMES: &str = "teletanaris,bolthyjal,feltaxi";

#[derive(Debug, Clone)]
struct PortalAttemptState {
    entry: i32,
    type_id: i32,
    attempts: u32,
    last_attempt: Option<Instant>,
}

#[derive(Debug, Clone)]
struct PartyMember {
    name: String,
    guid: u64,
}

fn portal_attempt_limit() -> u32 {
    env::var("WOW112_PORTAL_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(PORTAL_DEFAULT_ATTEMPTS)
        .clamp(1, 8)
}

fn configured_summoner_names() -> Vec<String> {
    let raw = env::var("WOW112_SUMMONER_NAMES")
        .unwrap_or_else(|_| DEFAULT_SUMMONER_NAMES.to_string());
    let mut names = Vec::new();
    for value in raw.split(|ch: char| ch == ',' || ch == ';' || ch.is_whitespace()) {
        let name = value.trim().to_ascii_lowercase();
        if !name.is_empty() && !names.iter().any(|item| item == &name) {
            names.push(name);
        }
    }
    names
}

fn fixed_slave_master(player_name: &str) -> Option<&'static str> {
    if player_name.eq_ignore_ascii_case("silione")
        || player_name.eq_ignore_ascii_case("silitwo")
    {
        Some("kalisum")
    } else if player_name.eq_ignore_ascii_case("hyjaluno")
        || player_name.eq_ignore_ascii_case("hyjalone")
    {
        Some("bolthyjal")
    } else if player_name.eq_ignore_ascii_case("hydratwo")
        || player_name.eq_ignore_ascii_case("hydraone")
    {
        Some("feltaxi")
    } else if player_name.eq_ignore_ascii_case("winterone")
        || player_name.eq_ignore_ascii_case("wintertwoo")
    {
        Some("taxiwinter")
    } else {
        None
    }
}

fn write_group_invite(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    target: &str,
) -> Result<(), String> {
    println!("[PARTY] invite fixed master by name: {target}");
    CMSG_GROUP_INVITE {
        name: target.to_string(),
    }
    .write_encrypted_client(&mut *stream, crypto.encrypter())
    .map_err(|e| format!("write fixed-master group invite failed target={target}: {e:?}"))
}

fn accept_fixed_master_invite_once(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    payload: &[u8],
    fixed_master: &str,
    accept_committed: &mut bool,
) -> Result<(), String> {
    let message = parse_raw_server_message(SMSG_GROUP_INVITE_OPCODE, payload)
        .map_err(|error| format!("parse fixed-master group invite failed: {error}"))?;
    let ServerOpcodeMessage::SMSG_GROUP_INVITE(invite) = message else {
        return Ok(());
    };

    if !invite.name.eq_ignore_ascii_case(fixed_master) {
        println!(
            "[PARTY] ignore invite from untrusted inviter={} fixed_master={}",
            invite.name, fixed_master
        );
        return Ok(());
    }

    if *accept_committed {
        println!(
            "[PARTY] trusted invite duplicate ignored inviter={} reason=accept_already_committed retry_allowed=false",
            invite.name
        );
        return Ok(());
    }

    // Mutation rule: commit guard BEFORE socket I/O. If the write result is
    // uncertain, the session hard-stops and never retries this accept.
    *accept_committed = true;
    println!(
        "[PARTY] trusted master invite ACCEPT COMMITTED inviter={} opcode=0x0072 retry_allowed=false",
        invite.name
    );
    write_encrypted_raw(stream, crypto.encrypter(), CMSG_GROUP_ACCEPT_OPCODE, &[])
        .map_err(|error| {
            format!(
                "GROUP_ACCEPT_MUTATION_UNCERTAIN inviter={} retry_allowed=false cause={error}",
                invite.name
            )
        })?;
    println!(
        "[PARTY] trusted master invite ACCEPT SENT inviter={} opcode=0x0072 retry_allowed=false",
        invite.name
    );
    Ok(())
}

fn read_party_u8(payload: &[u8], offset: &mut usize) -> Result<u8, String> {
    if *offset + 1 > payload.len() {
        return Err("SMSG_GROUP_LIST truncated u8".to_string());
    }
    let value = payload[*offset];
    *offset += 1;
    Ok(value)
}

fn read_party_u32(payload: &[u8], offset: &mut usize) -> Result<u32, String> {
    if *offset + 4 > payload.len() {
        return Err("SMSG_GROUP_LIST truncated u32".to_string());
    }
    let value = u32::from_le_bytes(payload[*offset..*offset + 4].try_into().unwrap());
    *offset += 4;
    Ok(value)
}

fn read_party_u64(payload: &[u8], offset: &mut usize) -> Result<u64, String> {
    if *offset + 8 > payload.len() {
        return Err("SMSG_GROUP_LIST truncated u64".to_string());
    }
    let value = u64::from_le_bytes(payload[*offset..*offset + 8].try_into().unwrap());
    *offset += 8;
    Ok(value)
}

fn read_party_cstring(payload: &[u8], offset: &mut usize) -> Result<String, String> {
    if *offset >= payload.len() {
        return Err("SMSG_GROUP_LIST truncated string".to_string());
    }
    let tail = &payload[*offset..];
    let end = tail
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| "SMSG_GROUP_LIST unterminated string".to_string())?;
    let value = String::from_utf8_lossy(&tail[..end]).to_string();
    *offset += end + 1;
    Ok(value)
}

fn service_party_leader_handoff(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    payload: &[u8],
    summoner_names: &[String],
    auto_invite_missing: bool,
    last_invite: &mut Option<(String, Instant)>,
    last_transfer: &mut Option<(u64, Instant)>,
) -> Result<(), String> {
    let mut offset = 0usize;
    let _group_type = read_party_u8(payload, &mut offset)?;
    let _own_flags = read_party_u8(payload, &mut offset)?;
    let member_count = read_party_u32(payload, &mut offset)? as usize;
    if member_count > 39 {
        return Err(format!("SMSG_GROUP_LIST unreasonable member_count={member_count}"));
    }

    let mut members = Vec::with_capacity(member_count);
    for _ in 0..member_count {
        let name = read_party_cstring(payload, &mut offset)?;
        let guid = read_party_u64(payload, &mut offset)?;
        let _status = read_party_u8(payload, &mut offset)?;
        let _flags = read_party_u8(payload, &mut offset)?;
        members.push(PartyMember { name, guid });
    }

    let leader_guid = read_party_u64(payload, &mut offset)?;
    if leader_guid == 0 {
        return Ok(());
    }

    // SMSG_GROUP_LIST excludes this client from the member list. If the leader GUID
    // belongs to one of the listed members, somebody else already owns leadership.
    if members.iter().any(|member| member.guid == leader_guid) {
        if auto_invite_missing {
            *last_invite = None;
        }
        return Ok(());
    }

    let mut target = None;
    for wanted in summoner_names {
        if let Some(member) = members
            .iter()
            .find(|member| member.name.eq_ignore_ascii_case(wanted))
        {
            target = Some(member);
            break;
        }
    }

    if target.is_none() {
        if !auto_invite_missing {
            return Ok(());
        }
        let Some(wanted) = summoner_names.first() else {
            return Ok(());
        };
        if let Some((name, sent_at)) = last_invite.as_ref() {
            if name.eq_ignore_ascii_case(wanted)
                && sent_at.elapsed() < Duration::from_millis(PARTY_INVITE_RETRY_GAP_MS)
            {
                return Ok(());
            }
        }

        write_group_invite(stream, crypto, wanted)?;
        *last_invite = Some((wanted.to_string(), Instant::now()));
        return Ok(());
    }

    let target = target.unwrap();
    *last_invite = None;

    if let Some((guid, sent_at)) = *last_transfer {
        if guid == target.guid && sent_at.elapsed() < Duration::from_millis(PARTY_LEADER_RETRY_GAP_MS) {
            return Ok(());
        }
    }

    println!(
        "[PARTY] I am leader -> transfer to {} guid=0x{:016X}",
        target.name, target.guid
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_GROUP_SET_LEADER_OPCODE,
        &target.guid.to_le_bytes(),
    )?;
    *last_transfer = Some((target.guid, Instant::now()));
    Ok(())
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
    player_name: &str,
    soak_seconds: u64,
) -> Result<(), String> {
    let previous_timeout = stream.read_timeout().ok().flatten();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set portal read timeout failed: {e}"))?;

    let max_attempts = portal_attempt_limit();
    let fixed_master = fixed_slave_master(player_name);
    let summoner_names = match fixed_master {
        Some(master) => vec![master.to_string()],
        None => configured_summoner_names(),
    };
    let auto_invite_missing = fixed_master.is_some();
    let deadline = if soak_seconds == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_secs(soak_seconds))
    };
    let mut portals = std::collections::HashMap::<u64, PortalAttemptState>::new();
    let mut last_summoner_invite: Option<(String, Instant)> = None;
    let mut last_leader_transfer: Option<(u64, Instant)> = None;
    let mut trusted_accept_committed = false;
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
    println!(
        "[PARTY] auto leader handoff enabled player={} summoners={}",
        player_name,
        summoner_names.join(",")
    );

    if let Some(master) = fixed_master {
        println!("[PARTY] fixed slave/master pair active slave={player_name} master={master}");
        write_group_invite(stream, crypto, master)?;
        last_summoner_invite = Some((master.to_string(), Instant::now()));
    }

    loop {
        if deadline.is_some_and(|value| Instant::now() >= value) {
            println!("[PORTAL] soak complete discovered={}", portals.len());
            let _ = stream.set_read_timeout(previous_timeout);
            return Ok(());
        }

        service_portal_clicks(stream, crypto, &mut portals, max_attempts)?;

        if auto_invite_missing {
            if let (Some(master), Some((name, sent_at))) = (fixed_master, last_summoner_invite.as_ref()) {
                if name.eq_ignore_ascii_case(master)
                    && sent_at.elapsed() >= Duration::from_millis(PARTY_INVITE_RETRY_GAP_MS)
                {
                    write_group_invite(stream, crypto, master)?;
                    last_summoner_invite = Some((master.to_string(), Instant::now()));
                }
            }
        }

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
                if opcode == SMSG_GROUP_INVITE_OPCODE {
                    if let Some(master) = fixed_master {
                        accept_fixed_master_invite_once(
                            stream,
                            crypto,
                            &payload,
                            master,
                            &mut trusted_accept_committed,
                        )?;
                    }
                    continue;
                }
                if opcode == SMSG_GROUP_LIST_OPCODE {
                    if let Err(error) = service_party_leader_handoff(
                        stream,
                        crypto,
                        &payload,
                        &summoner_names,
                        auto_invite_missing,
                        &mut last_summoner_invite,
                        &mut last_leader_transfer,
                    ) {
                        println!("[PARTY-DIAG] roster invite/handoff skipped: {error}");
                    }
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

    portal_click_loop(stream, &mut crypto, &selected.name, soak_seconds)?;
    println!("[PORTAL] CLICKER PASS");
    Ok(())
}
