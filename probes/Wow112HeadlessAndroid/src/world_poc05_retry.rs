include!("world_poc05.rs");

fn discover_poc05_context_retry(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    player_guid: u64,
) -> Result<(HashSet<u64>, u64), String> {
    let mut auctioneers = HashSet::new();
    let mut mailboxes = HashSet::new();
    let mut snapshot = Poc05Snapshot::default();
    let mut settle_packets = 0usize;

    if let Ok(value) = env::var("WOW112_AH_GUID") {
        let guid = parse_guid_override("WOW112_AH_GUID", &value)?;
        println!("[AH] using configured auctioneer guid=0x{guid:016X}");
        auctioneers.insert(guid);
    }

    let mailbox_override = if let Ok(value) = env::var("WOW112_MAILBOX_GUID") {
        let guid = parse_guid_override("WOW112_MAILBOX_GUID", &value)?;
        println!("[MAIL] using configured mailbox guid=0x{guid:016X}");
        mailboxes.insert(guid);
        Some(guid)
    } else {
        None
    };

    println!("[POC05] collecting player gold + inventory and interaction targets");
    for index in 0..1536usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        poc05_inspect_update_packet(
            opcode,
            &payload,
            player_guid,
            &mut snapshot,
            &mut auctioneers,
            &mut mailboxes,
        );

        if snapshot.coinage.is_some() {
            settle_packets = settle_packets.saturating_add(1);
        }

        if index < 20 {
            println!(
                "[POC05-DIAG] snapshot rx[{index}] opcode=0x{opcode:04X} payload={} coinage={} items={} targets={}/{}",
                payload.len(),
                snapshot.coinage.is_some(),
                snapshot.items.len(),
                auctioneers.len(),
                mailboxes.len()
            );
        }

        if snapshot.coinage.is_some()
            && settle_packets >= POC05_SETTLE_PACKETS
            && !auctioneers.is_empty()
            && !mailboxes.is_empty()
        {
            poc05_print_snapshot(&snapshot)?;

            let mailbox = mailbox_override.unwrap_or_else(|| *mailboxes.iter().next().unwrap());
            let mut candidates = auctioneers.iter().copied().collect::<Vec<_>>();
            candidates.sort_unstable();
            println!(
                "[POC05] context ready after rx[{index}] auctioneer_candidates={} mailbox=0x{mailbox:016X}",
                candidates.len()
            );
            for (candidate_index, guid) in candidates.iter().enumerate() {
                println!("[AH] candidate[{candidate_index}]=0x{guid:016X}");
            }
            return Ok((auctioneers, mailbox));
        }
    }

    Err(format!(
        "POC-05 context incomplete after 1536 packets: coinage={} inventory={} auctioneers={} mailboxes={}",
        snapshot.coinage.is_some(),
        snapshot.items.len(),
        auctioneers.len(),
        mailboxes.len()
    ))
}

fn poc05_send_auction_hello_candidates(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    mut discovered: HashSet<u64>,
) -> Result<(u64, u32), String> {
    if discovered.is_empty() {
        return Err("POC-05 has no auctioneer candidates".to_string());
    }

    let mut attempted = HashSet::new();
    let preferred = env::var("WOW112_AH_GUID")
        .ok()
        .and_then(|value| parse_guid_override("WOW112_AH_GUID", &value).ok())
        .filter(|guid| discovered.contains(guid));
    let first_guid = preferred.unwrap_or_else(|| *discovered.iter().next().unwrap());

    println!(
        "[AH] opening auction house guid=0x{first_guid:016X} seeded_candidates={}",
        discovered.len()
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        u32::from(MSG_AUCTION_HELLO_OPCODE),
        &first_guid.to_le_bytes(),
    )?;
    attempted.insert(first_guid);

    for index in 0..512usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == MSG_AUCTION_HELLO_OPCODE {
            if payload.len() < 12 {
                return Err(format!(
                    "MSG_AUCTION_HELLO payload too short: {}",
                    payload.len()
                ));
            }
            let response_guid = u64::from_le_bytes(payload[0..8].try_into().unwrap());
            let auction_house = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            println!(
                "[AH] MSG_AUCTION_HELLO PASS guid=0x{response_guid:016X} house={auction_house} attempted={} candidates={}",
                attempted.len(),
                discovered.len()
            );
            return Ok((response_guid, auction_house));
        }

        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[AH-DIAG] hello wait rx[{index}] opcode=0x{opcode:04X} payload={} attempted={} candidates={}",
                payload.len(),
                attempted.len(),
                discovered.len()
            );
        }

        if (index + 1) % 16 == 0 {
            if let Some(next_guid) = discovered
                .iter()
                .copied()
                .find(|guid| !attempted.contains(guid))
            {
                println!("[AH] hello retry with auctioneer guid=0x{next_guid:016X}");
                write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    u32::from(MSG_AUCTION_HELLO_OPCODE),
                    &next_guid.to_le_bytes(),
                )?;
                attempted.insert(next_guid);
            }
        }
    }

    Err(format!(
        "server did not return MSG_AUCTION_HELLO within 512 packets; attempted={} candidates={}",
        attempted.len(),
        discovered.len()
    ))
}

fn poc05_probe_read_only_auction_house_candidates(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_candidates: HashSet<u64>,
) -> Result<(), String> {
    let (auctioneer_guid, auction_house) =
        poc05_send_auction_hello_candidates(stream, crypto, auctioneer_candidates)?;

    let query = build_read_only_auction_query(auctioneer_guid);
    println!(
        "[AH] sending READ-ONLY page0 query house={auction_house} payload={} filters=ANY",
        query.len()
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_AUCTION_LIST_ITEMS_OPCODE,
        &query,
    )?;

    let mut discovered = HashSet::new();
    for index in 0..256usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            parse_auction_list_result(&payload)?;
            println!("[AH] POC-05 READ-ONLY PASS");
            return Ok(());
        }

        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[AH-DIAG] list wait rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    Err("SMSG_AUCTION_LIST_RESULT not received within 256 packets".to_string())
}

pub fn login_poc05_retry(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    mutation_committed: &mut bool,
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
    let safe_prefix_len = auth_wire.len().min(24);
    println!(
        "[WORLD-DIAG] auth-session-out len={} prefix={} world-build={} server-id={} addons=octo-standard-12",
        auth_wire.len(),
        hex_prefix(&auth_wire[..safe_prefix_len]),
        OCTOWOW_WORLD_BUILD,
        server_id
    );
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
    let player_guid = selected.guid.guid();
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

    let action = poc05_mail_action_from_env()?;
    println!("[POC05] requested mailbox action={action:?} committed_before_session={mutation_committed}");

    let (auctioneer_candidates, mailbox_guid) =
        discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
    poc05_probe_read_only_auction_house_candidates(
        stream,
        &mut crypto,
        auctioneer_candidates,
    )?;
    let mails = poc05_request_mail_list(stream, &mut crypto, mailbox_guid)?;
    poc05_perform_mail_action(
        stream,
        &mut crypto,
        mailbox_guid,
        action,
        &mails,
        mutation_committed,
    )?;
    maintain_world_session(stream, &mut crypto, soak_seconds)?;
    println!("[POC05] POC-05 INVENTORY/GOLD/MAIL CONTROL PASS");
    Ok(())
}
