include!("world.rs");

use wow_world_messages::vanilla::{CMSG_GROUP_INVITE, SMSG_MESSAGECHAT_ChatType};

const SMSG_MESSAGECHAT_OPCODE: u16 = 0x0096;
const CMSG_MESSAGECHAT_OPCODE: u32 = 0x0095;
const CMSG_NAME_QUERY_OPCODE: u32 = 0x0050;
const SMSG_NAME_QUERY_RESPONSE_OPCODE: u16 = 0x0051;
const SMSG_GROUP_LIST_OPCODE: u16 = 0x007D;
const SMSG_PARTY_COMMAND_RESULT_OPCODE: u16 = 0x007F;
const CHAT_TYPE_WHISPER: u32 = 6;
const LANGUAGE_UNIVERSAL: u32 = 0;

fn tele_read_cstring(payload: &[u8], start: usize) -> Result<(String, usize), String> {
    let rest = payload
        .get(start..)
        .ok_or_else(|| format!("cstring offset out of range: {start}"))?;
    let nul = rest
        .iter()
        .position(|value| *value == 0)
        .ok_or_else(|| format!("unterminated cstring at offset {start}"))?;
    let value = String::from_utf8_lossy(&rest[..nul]).into_owned();
    Ok((value, start + nul + 1))
}

fn tele_parse_name_query_response(payload: &[u8]) -> Result<(u64, String), String> {
    if payload.len() < 10 {
        return Err(format!("name response too short: {}", payload.len()));
    }
    let guid = u64::from_le_bytes(
        payload[0..8]
            .try_into()
            .map_err(|_| "invalid name response guid".to_string())?,
    );
    let (character_name, next) = tele_read_cstring(payload, 8)?;
    let (_realm_name, _next) = tele_read_cstring(payload, next)?;
    if character_name.is_empty() {
        return Err(format!("empty character name for guid=0x{guid:016X}"));
    }
    Ok((guid, character_name))
}

fn tele_send_name_query(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    guid: u64,
) -> Result<(), String> {
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_NAME_QUERY_OPCODE,
        &guid.to_le_bytes(),
    )?;
    println!("[TELE-NAME] query guid=0x{guid:016X}");
    Ok(())
}

fn tele_send_whisper(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    target: &str,
    message: &str,
) -> Result<(), String> {
    if target.is_empty() || target.as_bytes().contains(&0) {
        return Err("invalid TELE whisper target".to_string());
    }
    if message.is_empty() || message.as_bytes().contains(&0) {
        return Err("invalid TELE whisper message".to_string());
    }
    if message.len() > 255 {
        return Err(format!("TELE test whisper too long: {} bytes", message.len()));
    }

    let mut payload = Vec::with_capacity(8 + target.len() + 1 + message.len() + 1);
    payload.extend_from_slice(&CHAT_TYPE_WHISPER.to_le_bytes());
    payload.extend_from_slice(&LANGUAGE_UNIVERSAL.to_le_bytes());
    payload.extend_from_slice(target.as_bytes());
    payload.push(0);
    payload.extend_from_slice(message.as_bytes());
    payload.push(0);

    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_MESSAGECHAT_OPCODE,
        &payload,
    )?;
    println!("[TELE-TX] target={target:?} text={message:?} result=sent_once");
    Ok(())
}

fn tele_send_group_invite(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    target: &str,
) -> Result<(), String> {
    if target.is_empty() || target.as_bytes().contains(&0) {
        return Err("invalid TELE invite target".to_string());
    }
    CMSG_GROUP_INVITE {
        name: target.to_string(),
    }
    .write_encrypted_client(&mut *stream, crypto.encrypter())
    .map_err(|e| format!("write TELE group invite failed: {e:?}"))?;
    println!("[TELE-INVITE] target={target:?} result=sent_once");
    Ok(())
}

fn tele_emit_resolved_whisper(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    sequence: u64,
    guid: u64,
    sender_name: &str,
    text: &str,
    test_reply: &str,
    reply_sent: &mut bool,
    test_invite_trigger: &str,
    invite_sent: &mut bool,
) -> Result<(), String> {
    println!(
        "[TELE-WHISPER] seq={} sender_name={:?} sender_guid=0x{:016X} text={:?}",
        sequence,
        sender_name,
        guid,
        text
    );

    if !test_reply.is_empty() && !*reply_sent {
        tele_send_whisper(stream, crypto, sender_name, test_reply)?;
        *reply_sent = true;
    }

    if !test_invite_trigger.is_empty()
        && !*invite_sent
        && text.trim().eq_ignore_ascii_case(test_invite_trigger)
    {
        tele_send_group_invite(stream, crypto, sender_name)?;
        *invite_sent = true;
    }
    Ok(())
}

fn tele_log_party_packet(opcode: u16, payload: &[u8]) -> Result<bool, String> {
    if opcode != SMSG_GROUP_LIST_OPCODE && opcode != SMSG_PARTY_COMMAND_RESULT_OPCODE {
        return Ok(false);
    }

    let message = parse_raw_server_message(opcode, payload)
        .map_err(|error| format!("parse TELE party packet opcode=0x{opcode:04X} failed: {error}"))?;
    match message {
        ServerOpcodeMessage::SMSG_GROUP_LIST(group) => {
            println!(
                "[TELE-PARTY] roster members={} leader_guid=0x{:016X} group_type={:?}",
                group.members.len(),
                group.leader.guid(),
                group.group_type
            );
            for (index, member) in group.members.iter().enumerate() {
                println!(
                    "[TELE-PARTY] member[{index}] name={:?} guid=0x{:016X} online={} flags={}",
                    member.name,
                    member.guid.guid(),
                    member.is_online,
                    member.flags
                );
            }
        }
        ServerOpcodeMessage::SMSG_PARTY_COMMAND_RESULT(result) => {
            println!("[TELE-PARTY] command_result={result:?}");
        }
        other => {
            println!("[TELE-DIAG] unexpected party decode opcode=0x{opcode:04X} message={other:?}");
        }
    }
    Ok(true)
}

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
    let mut name_cache: std::collections::HashMap<u64, String> = std::collections::HashMap::new();
    let mut pending_whispers: std::collections::HashMap<u64, Vec<(u64, String)>> =
        std::collections::HashMap::new();
    let test_reply = std::env::var("WOW112_TELE_TEST_REPLY")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default();
    let test_invite_trigger = std::env::var("WOW112_TELE_TEST_INVITE_TRIGGER")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default();
    let mut reply_sent = false;
    let mut invite_sent = false;

    println!(
        "[TELE] SESSION ACTIVE name_resolution=cmsg-name-query chat_tx={} invite={} cast=disabled portal_use=disabled duration={}",
        if test_reply.is_empty() { "disabled" } else { "armed_once" },
        if test_invite_trigger.is_empty() { "disabled" } else { "armed_once" },
        if soak_seconds == 0 {
            "infinite".to_string()
        } else {
            format!("{soak_seconds}s")
        }
    );
    if !test_invite_trigger.is_empty() {
        println!("[TELE-INVITE] armed trigger={test_invite_trigger:?}");
    }

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

                if tele_log_party_packet(opcode, &payload)? {
                    continue;
                }

                if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                    match tele_parse_name_query_response(&payload) {
                        Ok((guid, character_name)) => {
                            println!(
                                "[TELE-NAME] resolved guid=0x{:016X} name={:?}",
                                guid, character_name
                            );
                            name_cache.insert(guid, character_name.clone());
                            if let Some(items) = pending_whispers.remove(&guid) {
                                for (sequence, text) in items {
                                    tele_emit_resolved_whisper(
                                        stream,
                                        crypto,
                                        sequence,
                                        guid,
                                        &character_name,
                                        &text,
                                        &test_reply,
                                        &mut reply_sent,
                                        &test_invite_trigger,
                                        &mut invite_sent,
                                    )?;
                                }
                            }
                        }
                        Err(error) => println!(
                            "[TELE-DIAG] name response skipped payload={} reason={error}",
                            payload.len()
                        ),
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
                    match chat.chat_type {
                        SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } => {
                            whisper_count = whisper_count.saturating_add(1);
                            let guid = sender2.guid();
                            if let Some(sender_name) = name_cache.get(&guid).cloned() {
                                tele_emit_resolved_whisper(
                                    stream,
                                    crypto,
                                    whisper_count,
                                    guid,
                                    &sender_name,
                                    &text,
                                    &test_reply,
                                    &mut reply_sent,
                                    &test_invite_trigger,
                                    &mut invite_sent,
                                )?;
                            } else {
                                let first_pending = !pending_whispers.contains_key(&guid);
                                pending_whispers
                                    .entry(guid)
                                    .or_default()
                                    .push((whisper_count, text));
                                if first_pending {
                                    tele_send_name_query(stream, crypto, guid)?;
                                }
                            }
                        }
                        SMSG_MESSAGECHAT_ChatType::WhisperInform { sender2 } => {
                            println!(
                                "[TELE-TX-ECHO] target_guid=0x{:016X} text={:?}",
                                sender2.guid(),
                                text
                            );
                        }
                        _ => {}
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
    println!("[TELE] SESSION PASS");
    Ok(())
}
