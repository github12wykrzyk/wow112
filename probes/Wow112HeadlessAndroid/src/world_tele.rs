include!("world.rs");

use wow_world_messages::vanilla::SMSG_MESSAGECHAT_ChatType;

const SMSG_MESSAGECHAT_OPCODE: u16 = 0x0096;

fn tele_sniffer_loop(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    soak_seconds: u64,
) -> Result<(), String> {
    let previous_timeout = stream.read_timeout().ok().flatten();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set TELE read timeout failed: {e}"))?;

    let deadline = if soak_seconds == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_secs(soak_seconds))
    };
    let mut last_ping = Instant::now();
    let mut ping_sequence = 1u32;
    let mut awaiting_pong: Option<(u32, Instant)> = None;
    let mut whisper_count = 0u64;

    println!(
        "[TELE] WHISPER SNIFFER ACTIVE rx_only=yes chat_tx=disabled invite=disabled cast=disabled portal_use=disabled duration={}",
        if soak_seconds == 0 {
            "infinite".to_string()
        } else {
            format!("{soak_seconds}s")
        }
    );

    loop {
        if deadline.is_some_and(|value| Instant::now() >= value) {
            println!("[TELE] soak complete whispers={whisper_count}");
            let _ = stream.set_read_timeout(previous_timeout);
            return Ok(());
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
            println!("[TELE] keepalive ping sequence={ping_sequence}");
            awaiting_pong = Some((ping_sequence, Instant::now()));
            ping_sequence = ping_sequence.wrapping_add(1);
            last_ping = Instant::now();
        }

        match read_encrypted_raw(stream, crypto.decrypter()) {
            Ok((opcode, payload)) => {
                if opcode == SMSG_PONG_OPCODE {
                    if payload.len() >= 4 {
                        let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                        println!("[TELE] keepalive pong sequence={sequence}");
                        if awaiting_pong.map(|value| value.0) == Some(sequence) {
                            awaiting_pong = None;
                        }
                    }
                    continue;
                }

                if opcode != SMSG_MESSAGECHAT_OPCODE {
                    continue;
                }

                let message = match parse_raw_server_message(opcode, &payload) {
                    Ok(message) => message,
                    Err(error) => {
                        println!(
                            "[TELE-DIAG] chat packet skipped opcode=0x{opcode:04X} payload={} reason={error}",
                            payload.len()
                        );
                        continue;
                    }
                };

                if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                    let text = chat.message;
                    if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                        whisper_count = whisper_count.saturating_add(1);
                        println!(
                            "[TELE-WHISPER] seq={} sender_guid=0x{:016X} text={:?}",
                            whisper_count,
                            sender2.guid(),
                            text
                        );
                    }
                }
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

pub fn login_tele_sniffer(
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

    tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;
    println!("[TELE] WHISPER SNIFFER PASS");
    Ok(())
}
