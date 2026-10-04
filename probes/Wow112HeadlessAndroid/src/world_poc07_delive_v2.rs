include!("world_poc07_delive.rs");

fn poc07_de_outcomes_v2(info: Poc07DeItemInfo) -> Option<Vec<Poc07DeOutcome>> {
    if info.item_class != 2 && info.item_class != 4 {
        return None;
    }
    let weapon = info.item_class == 2;
    let (dust_bps, essence_bps, shard_bps) = if weapon {
        (2000u32, 7500u32, 300u32)
    } else {
        (7500u32, 2000u32, 300u32)
    };

    match info.quality {
        2 => {
            let (dust, dust_qty, essence, essence_qty, shard) = match info.item_level {
                31..=35 => (11137, 150, 11135, 150, 11139),
                36..=40 => (11137, 350, 11174, 150, 11177),
                41..=45 => (11176, 150, 11175, 150, 11178),
                46..=50 => (11176, 350, 16202, 150, 14343),
                51..=55 => (16204, 150, 16203, 150, 14344),
                56..=65 => (16204, 350, 16203, 200, 14344),
                _ => return None,
            };
            Some(vec![
                Poc07DeOutcome { material_id: dust, probability_bps: dust_bps, avg_qty_x100: dust_qty },
                Poc07DeOutcome { material_id: essence, probability_bps: essence_bps, avg_qty_x100: essence_qty },
                Poc07DeOutcome { material_id: shard, probability_bps: shard_bps, avg_qty_x100: 100 },
            ])
        }
        3 => {
            let shard = match info.item_level {
                31..=35 => 11139,
                36..=40 => 11177,
                41..=45 => 11178,
                46..=50 => 14343,
                51..=55 => 14344,
                56..=65 => {
                    return Some(vec![
                        Poc07DeOutcome { material_id: 14344, probability_bps: 9950, avg_qty_x100: 100 },
                        Poc07DeOutcome { material_id: 20725, probability_bps: 50, avg_qty_x100: 100 },
                    ]);
                }
                _ => return None,
            };
            Some(vec![Poc07DeOutcome {
                material_id: shard,
                probability_bps: 10_000,
                avg_qty_x100: 100,
            }])
        }
        _ => None,
    }
}

fn poc07_de_build_named_query(
    auctioneer_guid: u64,
    list_from: u32,
    name: &str,
) -> Result<Vec<u8>, String> {
    if name.as_bytes().contains(&0) {
        return Err("AH item name contains NUL".to_string());
    }
    let mut payload = Vec::with_capacity(32 + name.len());
    payload.extend_from_slice(&auctioneer_guid.to_le_bytes());
    payload.extend_from_slice(&list_from.to_le_bytes());
    payload.extend_from_slice(name.as_bytes());
    payload.push(0); // searched name cstring
    payload.push(0); // level min
    payload.push(0); // level max
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // inventory type
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // class
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // subclass
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // quality
    payload.push(0); // usable only
    Ok(payload)
}

fn poc07_de_parse_auction_list_with_total(
    payload: &[u8],
) -> Result<(Vec<Poc06AuctionRecord>, u32), String> {
    if payload.len() < 8 {
        return Err(format!("SMSG_AUCTION_LIST_RESULT payload too short: {}", payload.len()));
    }
    let count = read_u32_at(payload, 0)? as usize;
    let total_offset = 4usize
        .checked_add(count.checked_mul(AUCTION_RECORD_SIZE).ok_or_else(|| "auction count overflow".to_string())?)
        .ok_or_else(|| "auction total offset overflow".to_string())?;
    if payload.len() < total_offset + 4 {
        return Err(format!(
            "SMSG_AUCTION_LIST_RESULT truncated for total count={} need={} actual={}",
            count,
            total_offset + 4,
            payload.len()
        ));
    }
    let total = read_u32_at(payload, total_offset)?;
    let records = poc06_parse_auction_list_result(payload)?;
    Ok((records, total))
}

fn poc07_de_request_named_page(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    material_id: u32,
    material_name: &str,
    page: u32,
) -> Result<(Vec<Poc06AuctionRecord>, u32), String> {
    let list_from = page
        .checked_mul(50)
        .ok_or_else(|| format!("AH material page overflow page={page}"))?;
    let query = poc07_de_build_named_query(auctioneer_guid, list_from, material_name)?;
    println!(
        "[POC07-DE-MATQ] query item_id={material_id} name={material_name:?} page={page} listfrom={list_from} house={auction_house}"
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
            let (records, total) = poc07_de_parse_auction_list_with_total(&payload)?;
            println!(
                "[POC07-DE-MATQ] snapshot PASS item_id={material_id} page={page} records={} total={total}",
                records.len()
            );
            return Ok((records, total));
        }
        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 4 {
            println!(
                "[POC07-DE-MATQ-DIAG] wait item_id={material_id} page={page} rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }
    Err(format!(
        "SMSG_AUCTION_LIST_RESULT not received for material item_id={material_id} page={page}"
    ))
}

fn poc07_collect_de_material_prices_v2(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    needed: &HashSet<u32>,
) -> Result<std::collections::HashMap<u32, u32>, String> {
    let mut prices = std::collections::HashMap::<u32, u32>::new();

    for (material_id, material_name) in POC07_DE_MATERIALS.iter().copied() {
        if !needed.contains(&material_id) {
            continue;
        }
        let mut page = 0u32;
        let mut lowest: Option<u32> = None;
        let mut total_seen = 0u32;
        loop {
            if page >= 256 {
                return Err(format!(
                    "DE material query fail-closed: more than 256 pages item_id={material_id} name={material_name:?}"
                ));
            }
            let (records, total) = poc07_de_request_named_page(
                stream,
                crypto,
                auctioneer_guid,
                auction_house,
                material_id,
                material_name,
                page,
            )?;
            total_seen = total;
            for record in records.iter().copied() {
                if record.item_id != material_id || record.buyout == 0 || record.count == 0 {
                    continue;
                }
                let unit = (u64::from(record.buyout) + u64::from(record.count) - 1)
                    / u64::from(record.count);
                let unit = u32::try_from(unit)
                    .map_err(|_| "DE material unit price overflow".to_string())?;
                lowest = Some(lowest.map(|value| value.min(unit)).unwrap_or(unit));
            }

            let list_from = page.saturating_mul(50);
            if total == 0 || records.is_empty() || list_from.saturating_add(records.len() as u32) >= total {
                break;
            }
            page = page.saturating_add(1);
        }

        if let Some(price) = lowest {
            prices.insert(material_id, price);
            println!(
                "[POC07-DE-MAT] FULL item_id={material_id} name={material_name:?} total={total_seen} pages={} unit_buyout={} ({})",
                page + 1,
                price,
                poc06_format_money(price)
            );
        } else {
            println!(
                "[POC07-DE-MAT] MISSING item_id={material_id} name={material_name:?} total={total_seen} conservative_value=0"
            );
        }
    }

    for (item_id, value) in poc07_parse_value_map("WOW112_DE_MAT_VALUES")? {
        if needed.contains(&item_id) {
            prices.insert(item_id, value);
            println!(
                "[POC07-DE-MAT] OVERRIDE item_id={item_id} name={:?} unit_value={} ({})",
                poc07_de_mat_name(item_id),
                value,
                poc06_format_money(value)
            );
        }
    }

    println!(
        "[POC07-DE] targeted material price coverage={}/{} source=full-name-filtered-AH+optional-overrides",
        prices.len(),
        needed.len()
    );
    Ok(prices)
}

fn poc07_de_expected_value_v2(
    info: Poc07DeItemInfo,
    mat_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
) -> Option<u32> {
    let outcomes = poc07_de_outcomes_v2(info)?;
    let mut numerator: u128 = 0;
    let mut known = 0usize;
    for outcome in outcomes {
        if let Some(price) = mat_prices.get(&outcome.material_id).copied() {
            known += 1;
            numerator = numerator.saturating_add(
                u128::from(price)
                    .saturating_mul(u128::from(outcome.avg_qty_x100))
                    .saturating_mul(u128::from(outcome.probability_bps)),
            );
        }
    }
    if known == 0 {
        return None;
    }
    let gross = numerator / 1_000_000u128;
    let net = gross.saturating_mul(u128::from(net_bps)) / 10_000u128;
    u32::try_from(net.min(u128::from(u32::MAX))).ok()
}

pub fn login_poc07_delive_v2(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    _ah_mutation_committed: &mut bool,
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

    if !matches!(poc07_parse_mode()?, Poc07Mode::ScanOnly) {
        return Err("POC07-DE-LIVE-V2 is hard read-only; BUY is disabled in this build".to_string());
    }
    let blacklist = poc07_parse_blacklist()?;
    let page_start = poc07_env_u32_default("WOW112_AH_SCAN_PAGE_START", 12)?;
    let page_count = poc07_env_u32_default("WOW112_AH_SCAN_PAGES", 64)?;
    if page_count == 0 || page_count > 128 {
        return Err(format!("WOW112_AH_SCAN_PAGES must be 1..128 for DE live scan, got {page_count}"));
    }
    let max_buyout = poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?;
    let min_profit = i64::from(poc07_env_u32_default("WOW112_AUTOBUY_MIN_PROFIT", 1)?);
    let net_bps = poc07_env_u32_default("WOW112_DE_NET_BPS", 8500)?;
    if net_bps == 0 || net_bps > 10_000 {
        return Err(format!("WOW112_DE_NET_BPS must be 1..10000, got {net_bps}"));
    }

    println!(
        "[POC07-DE-V2] mode=ScanOnly page_start={page_start} pages={page_count} max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} scope=quality2-3_ilvl31-65 blacklist={} mutation=DISABLED",
        blacklist.len()
    );

    let (auctioneer_candidates, _mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
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
            "poc07-de-v2-scan",
        )?;
        scanned.extend(records.into_iter().map(|record| (page, record)));
    }
    println!("[POC07-DE-V2] AH SCAN PASS records={}", scanned.len());

    let mut item_ids = scanned
        .iter()
        .filter_map(|(_, record)| {
            if record.buyout == 0
                || record.buyout > max_buyout
                || record.count == 0
                || blacklist.contains(&record.item_id)
                || POC07_DE_MATERIALS.iter().any(|(id, _)| *id == record.item_id)
            {
                None
            } else {
                Some(record.item_id)
            }
        })
        .collect::<Vec<_>>();
    item_ids.sort_unstable();
    item_ids.dedup();

    println!("[POC07-DE-V2] item template classification start unique_items={}", item_ids.len());
    let mut item_infos = std::collections::HashMap::<u32, Poc07DeItemInfo>::new();
    let mut needed_materials = HashSet::<u32>::new();
    let mut template_supported = 0usize;
    let mut missing = 0usize;
    for (index, item_id) in item_ids.iter().copied().enumerate() {
        match poc07_query_item_info(stream, &mut crypto, item_id)? {
            Some(info) => {
                let outcomes = poc07_de_outcomes_v2(info);
                let supported = outcomes.is_some();
                if index < 40 || supported {
                    println!(
                        "[POC07-DE-ITEMINFO] item_id={} class={} quality={} inventory={} ilvl={} de_supported={} progress={}/{}",
                        info.item_id,
                        info.item_class,
                        info.quality,
                        info.inventory_type,
                        info.item_level,
                        supported,
                        index + 1,
                        item_ids.len()
                    );
                }
                if let Some(outcomes) = outcomes {
                    template_supported += 1;
                    for outcome in outcomes {
                        needed_materials.insert(outcome.material_id);
                    }
                    item_infos.insert(item_id, info);
                }
            }
            None => missing += 1,
        }
    }
    println!(
        "[POC07-DE-V2] TEMPLATE PASS queried={} de_supported_templates={} missing_templates={} needed_materials={}",
        item_ids.len(),
        template_supported,
        missing,
        needed_materials.len()
    );

    let mat_prices = poc07_collect_de_material_prices_v2(
        stream,
        &mut crypto,
        auctioneer_guid,
        auction_house,
        &needed_materials,
    )?;

    let mut de_values = std::collections::HashMap::<u32, u32>::new();
    let mut priced_supported = 0usize;
    for info in item_infos.values().copied() {
        if let Some(value) = poc07_de_expected_value_v2(info, &mat_prices, net_bps) {
            if value > 0 {
                de_values.insert(info.item_id, value);
                priced_supported += 1;
                println!(
                    "[POC07-DE-VALUE] item_id={} class={} quality={} inventory={} ilvl={} conservative_net_ev={} ({})",
                    info.item_id,
                    info.item_class,
                    info.quality,
                    info.inventory_type,
                    info.item_level,
                    value,
                    poc06_format_money(value)
                );
            }
        }
    }
    println!(
        "[POC07-DE-V2] VALUATION PASS template_supported={} priced_supported={} material_coverage={}/{}",
        template_supported,
        priced_supported,
        mat_prices.len(),
        needed_materials.len()
    );

    let empty_vendor = std::collections::HashMap::<u32, u32>::new();
    let mut candidates = Vec::new();
    for (page, record) in scanned {
        if let Some(candidate) = poc07_consider_candidate(
            page,
            record,
            &empty_vendor,
            &de_values,
            false,
            true,
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

    println!("[POC07-DE-V2] REAL DE SCAN-ONLY PASS no_mutation=YES");
    if soak_seconds > 0 {
        maintain_world_session(stream, &mut crypto, soak_seconds)?;
    }
    println!("[POC07-DE-V2] AUTOBUY ENGINE PASS mode=ScanOnly mutation=DISABLED");
    Ok(())
}
