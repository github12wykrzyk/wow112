include!("world_poc07.rs");

const POC07_CMSG_ITEM_QUERY_SINGLE_OPCODE: u32 = 0x0056;
const POC07_SMSG_ITEM_QUERY_SINGLE_RESPONSE_OPCODE: u16 = 0x0058;

fn poc07_read_cstring_end(payload: &[u8], start: usize) -> Result<usize, String> {
    if start >= payload.len() {
        return Err(format!("item query cstring starts past payload: start={start} len={}", payload.len()));
    }
    let relative = payload[start..]
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| format!("item query unterminated cstring at offset={start}"))?;
    Ok(start + relative + 1)
}

fn poc07_parse_item_sell_price(payload: &[u8], expected_item_id: u32) -> Result<Option<u32>, String> {
    if payload.len() < 4 {
        return Err(format!("SMSG_ITEM_QUERY_SINGLE_RESPONSE too short: {}", payload.len()));
    }
    let raw_entry = read_u32_at(payload, 0)?;
    if raw_entry & 0x8000_0000 != 0 {
        let missing = raw_entry & 0x7FFF_FFFF;
        if missing == expected_item_id {
            return Ok(None);
        }
        return Err(format!(
            "item query not-found response mismatch expected={expected_item_id} got={missing}"
        ));
    }
    if raw_entry != expected_item_id {
        return Err(format!(
            "item query response mismatch expected={expected_item_id} got={raw_entry}"
        ));
    }
    if payload.len() < 12 {
        return Err(format!("item query response truncated before names item={expected_item_id}"));
    }

    let mut cursor = 12usize; // entry, class, subclass
    for _ in 0..4 {
        cursor = poc07_read_cstring_end(payload, cursor)?;
    }
    // display_id, quality, flags, buy_price, sell_price
    let required = cursor
        .checked_add(20)
        .ok_or_else(|| "item query response size overflow".to_string())?;
    if payload.len() < required {
        return Err(format!(
            "item query response truncated item={expected_item_id} need={required} actual={}",
            payload.len()
        ));
    }
    let sell_price = read_u32_at(payload, cursor + 16)?;
    Ok(Some(sell_price))
}

fn poc07_query_live_vendor_value(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    item_id: u32,
) -> Result<Option<u32>, String> {
    let mut request = Vec::with_capacity(12);
    request.extend_from_slice(&item_id.to_le_bytes());
    request.extend_from_slice(&0u64.to_le_bytes());
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        POC07_CMSG_ITEM_QUERY_SINGLE_OPCODE,
        &request,
    )?;

    for index in 0..128usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == POC07_SMSG_ITEM_QUERY_SINGLE_RESPONSE_OPCODE {
            match poc07_parse_item_sell_price(&payload, item_id) {
                Ok(value) => return Ok(value),
                Err(error) if error.contains("response mismatch") => {
                    if index < 8 {
                        println!("[POC07-VENDOR-DIAG] unrelated item response while waiting item_id={item_id}: {error}");
                    }
                    continue;
                }
                Err(error) => return Err(error),
            }
        }
        if index < 6 {
            println!(
                "[POC07-VENDOR-DIAG] wait item_id={item_id} rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }
    Err(format!(
        "SMSG_ITEM_QUERY_SINGLE_RESPONSE not received within 128 packets item_id={item_id}"
    ))
}

fn poc07_fill_live_vendor_values(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    scanned: &[(u32, Poc06AuctionRecord)],
    max_buyout: u32,
    blacklist: &HashSet<u32>,
    vendor_values: &mut std::collections::HashMap<u32, u32>,
) -> Result<(), String> {
    let mut item_ids = scanned
        .iter()
        .filter_map(|(_, record)| {
            if record.buyout == 0
                || record.buyout > max_buyout
                || record.count == 0
                || blacklist.contains(&record.item_id)
            {
                None
            } else {
                Some(record.item_id)
            }
        })
        .collect::<Vec<_>>();
    item_ids.sort_unstable();
    item_ids.dedup();

    println!(
        "[POC07-VENDOR] live server valuation start unique_items={} source=SMSG_ITEM_QUERY_SINGLE_RESPONSE",
        item_ids.len()
    );
    let mut sellable = 0usize;
    let mut zero_or_missing = 0usize;
    for (index, item_id) in item_ids.iter().copied().enumerate() {
        match poc07_query_live_vendor_value(stream, crypto, item_id)? {
            Some(value) if value > 0 => {
                vendor_values.insert(item_id, value);
                sellable += 1;
                println!(
                    "[POC07-VENDOR] value item_id={item_id} sell_price={value} ({}) progress={}/{}",
                    poc06_format_money(value),
                    index + 1,
                    item_ids.len()
                );
            }
            Some(_) | None => {
                vendor_values.remove(&item_id);
                zero_or_missing += 1;
                if index < 20 {
                    println!(
                        "[POC07-VENDOR] skip item_id={item_id} sell_price=0_or_missing progress={}/{}",
                        index + 1,
                        item_ids.len()
                    );
                }
            }
        }
    }
    println!(
        "[POC07-VENDOR] live server valuation PASS queried={} sellable={} zero_or_missing={}",
        item_ids.len(), sellable, zero_or_missing
    );
    Ok(())
}

pub fn login_poc07_vendorlive(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    ah_mutation_committed: &mut bool,
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
    let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter())
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

    let mode = poc07_parse_mode()?;
    let (use_vendor, use_de) = poc07_strategy_flags()?;
    let mut vendor_values = poc07_parse_value_map("WOW112_VENDOR_VALUES")?;
    let de_values = poc07_parse_value_map("WOW112_DE_VALUES")?;
    let blacklist = poc07_parse_blacklist()?;
    let page_start = poc07_env_u32_default("WOW112_AH_SCAN_PAGE_START", 12)?;
    let page_count = poc07_env_u32_default("WOW112_AH_SCAN_PAGES", 3)?;
    if page_count == 0 || page_count > 32 {
        return Err(format!("WOW112_AH_SCAN_PAGES must be 1..32, got {page_count}"));
    }
    let max_buyout = match mode {
        Poc07Mode::ScanOnly => poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?,
        Poc07Mode::BuyOne => poc06_env_u32("WOW112_AUTOBUY_MAX_BUYOUT")?,
    };
    let min_profit = i64::from(poc07_env_u32_default("WOW112_AUTOBUY_MIN_PROFIT", 1)?);

    if use_de && de_values.is_empty() && !use_vendor {
        return Err("DE-only strategy selected but WOW112_DE_VALUES is empty".to_string());
    }

    println!(
        "[POC07-LIVE] mode={mode:?} page_start={page_start} pages={page_count} max_buyout={max_buyout} min_profit={min_profit} vendor_source={} de_values={} blacklist={} hard_max_purchases=1",
        if use_vendor { "server-item-query" } else { "disabled" },
        de_values.len(),
        blacklist.len()
    );

    let (auctioneer_candidates, mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
    let (auctioneer_guid, auction_house) = poc05_send_auction_hello_candidates(stream, &mut crypto, auctioneer_candidates)?;

    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();
    for offset in 0..page_count {
        let page = page_start
            .checked_add(offset)
            .ok_or_else(|| "AH scan page overflow".to_string())?;
        let records = poc07_request_auction_page(
            stream,
            &mut crypto,
            auctioneer_guid,
            auction_house,
            page,
            "poc07-live-scan",
        )?;
        scanned.extend(records.into_iter().map(|record| (page, record)));
    }
    println!("[POC07-LIVE] AH SCAN PASS records={}", scanned.len());

    if use_vendor {
        poc07_fill_live_vendor_values(
            stream,
            &mut crypto,
            &scanned,
            max_buyout,
            &blacklist,
            &mut vendor_values,
        )?;
    }

    let mut candidates = Vec::new();
    for (page, record) in scanned {
        if let Some(candidate) = poc07_consider_candidate(
            page,
            record,
            &vendor_values,
            &de_values,
            use_vendor,
            use_de,
            max_buyout,
            min_profit,
            &blacklist,
        ) {
            candidates.push(candidate);
        }
    }
    candidates.sort_by(|a, b| {
        b.expected_profit
            .cmp(&a.expected_profit)
            .then_with(|| a.record.buyout.cmp(&b.record.buyout))
            .then_with(|| a.record.auction_id.cmp(&b.record.auction_id))
    });
    poc07_print_candidates(&candidates);

    match mode {
        Poc07Mode::ScanOnly => {
            println!("[POC07-LIVE] REAL VENDOR SCAN-ONLY PASS no_mutation=YES");
        }
        Poc07Mode::BuyOne => {
            let candidate = candidates
                .first()
                .copied()
                .ok_or_else(|| "POC07_NO_QUALIFIED_CANDIDATE no purchase sent".to_string())?;
            poc07_buy_exact_one(
                stream,
                &mut crypto,
                auctioneer_guid,
                auction_house,
                mailbox_guid,
                candidate,
                ah_mutation_committed,
            )?;
        }
    }

    if soak_seconds > 0 {
        maintain_world_session(stream, &mut crypto, soak_seconds)?;
    }
    println!("[POC07-LIVE] AUTOBUY ENGINE PASS mode={mode:?}");
    Ok(())
}
