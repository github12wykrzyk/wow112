include!("world_poc07_vendorlive.rs");

#[derive(Debug, Clone, Copy)]
struct Poc07DeItemInfo {
    item_id: u32,
    item_class: u32,
    quality: u32,
    inventory_type: u32,
    item_level: u32,
}

#[derive(Debug, Clone, Copy)]
struct Poc07DeOutcome {
    material_id: u32,
    probability_bps: u32,
    avg_qty_x100: u32,
}

const POC07_DE_MATERIALS: &[(u32, &str)] = &[
    (11083, "Soul Dust"),
    (11134, "Lesser Mystic Essence"),
    (11138, "Small Glowing Shard"),
    (11137, "Vision Dust"),
    (11135, "Greater Mystic Essence"),
    (11139, "Large Glowing Shard"),
    (11174, "Lesser Nether Essence"),
    (11177, "Small Radiant Shard"),
    (11176, "Dream Dust"),
    (11175, "Greater Nether Essence"),
    (11178, "Large Radiant Shard"),
    (16202, "Lesser Eternal Essence"),
    (14343, "Small Brilliant Shard"),
    (16204, "Illusion Dust"),
    (16203, "Greater Eternal Essence"),
    (14344, "Large Brilliant Shard"),
    (20725, "Nexus Crystal"),
];

fn poc07_de_mat_name(item_id: u32) -> &'static str {
    POC07_DE_MATERIALS
        .iter()
        .find(|(id, _)| *id == item_id)
        .map(|(_, name)| *name)
        .unwrap_or("unknown")
}

fn poc07_parse_item_info(
    payload: &[u8],
    expected_item_id: u32,
) -> Result<Option<Poc07DeItemInfo>, String> {
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

    let item_class = read_u32_at(payload, 4)?;
    let mut cursor = 12usize;
    for _ in 0..4 {
        cursor = poc07_read_cstring_end(payload, cursor)?;
    }
    // display_id, quality, flags, buy_price, sell_price, inventory_type,
    // allowable_class, allowable_race, item_level
    let required = cursor
        .checked_add(36)
        .ok_or_else(|| "item query response size overflow".to_string())?;
    if payload.len() < required {
        return Err(format!(
            "item query response truncated item={expected_item_id} need={required} actual={}",
            payload.len()
        ));
    }
    Ok(Some(Poc07DeItemInfo {
        item_id: expected_item_id,
        item_class,
        quality: read_u32_at(payload, cursor + 4)?,
        inventory_type: read_u32_at(payload, cursor + 20)?,
        item_level: read_u32_at(payload, cursor + 32)?,
    }))
}

fn poc07_query_item_info(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    item_id: u32,
) -> Result<Option<Poc07DeItemInfo>, String> {
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
            match poc07_parse_item_info(&payload, item_id) {
                Ok(value) => return Ok(value),
                Err(error) if error.contains("response mismatch") => {
                    if index < 8 {
                        println!("[POC07-DE-DIAG] unrelated item response while waiting item_id={item_id}: {error}");
                    }
                    continue;
                }
                Err(error) => return Err(error),
            }
        }
        if index < 4 {
            println!(
                "[POC07-DE-DIAG] item-info wait item_id={item_id} rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }
    Err(format!(
        "SMSG_ITEM_QUERY_SINGLE_RESPONSE not received within 128 packets item_id={item_id}"
    ))
}

fn poc07_de_outcomes(info: Poc07DeItemInfo) -> Option<Vec<Poc07DeOutcome>> {
    // Deliberately conservative POC scope: vanilla uncommon/rare equipment only,
    // item levels 31..65. Low-level 5..30 and epics are skipped until a later
    // server-specific calibration pass.
    if info.item_class != 2 && info.item_class != 4 {
        return None;
    }
    let weapon = info.item_class == 2;
    match info.quality {
        2 => {
            let (dust, dust_qty, essence, essence_qty, shard, dust_bps, essence_bps, shard_bps) =
                match info.item_level {
                    31..=35 => (11083, 350, 11134, 150, 11138, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    36..=40 => (11137, 150, 11135, 150, 11139, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    41..=45 => (11137, 350, 11174, 150, 11177, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    46..=50 => (11176, 150, 11175, 150, 11178, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    51..=55 => (11176, 350, 16202, 150, 14343, if weapon { 2200 } else { 7500 }, if weapon { 7500 } else { 2000 }, if weapon { 300 } else { 500 }),
                    56..=60 => (16204, 150, 16203, 150, 14344, if weapon { 2200 } else { 7500 }, if weapon { 7500 } else { 2000 }, if weapon { 300 } else { 500 }),
                    61..=65 => (16204, 350, 16203, 250, 14344, if weapon { 2200 } else { 7500 }, if weapon { 7500 } else { 2000 }, if weapon { 300 } else { 500 }),
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
                31..=35 => 11138,
                36..=40 => 11139,
                41..=45 => 11177,
                46..=50 => 11178,
                51..=55 => 14343,
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

fn poc07_collect_de_material_prices(
    scanned: &[(u32, Poc06AuctionRecord)],
) -> Result<std::collections::HashMap<u32, u32>, String> {
    let mut prices = std::collections::HashMap::<u32, u32>::new();
    let wanted = POC07_DE_MATERIALS
        .iter()
        .map(|(id, _)| *id)
        .collect::<HashSet<_>>();

    for (_, record) in scanned {
        if record.buyout == 0 || record.count == 0 || !wanted.contains(&record.item_id) {
            continue;
        }
        let unit = (u64::from(record.buyout) + u64::from(record.count) - 1)
            / u64::from(record.count);
        let unit = u32::try_from(unit).map_err(|_| "DE material unit price overflow".to_string())?;
        prices
            .entry(record.item_id)
            .and_modify(|current| *current = (*current).min(unit))
            .or_insert(unit);
    }

    // Optional explicit values supplement/override the live AH sample. Same simple
    // item_id:value format as POC07's existing valuation maps.
    for (item_id, value) in poc07_parse_value_map("WOW112_DE_MAT_VALUES")? {
        if wanted.contains(&item_id) {
            prices.insert(item_id, value);
        }
    }

    println!(
        "[POC07-DE] material price coverage={}/{} source=live-scanned-AH+optional-overrides",
        prices.len(),
        POC07_DE_MATERIALS.len()
    );
    let mut rows = prices.iter().map(|(k, v)| (*k, *v)).collect::<Vec<_>>();
    rows.sort_unstable_by_key(|(item_id, _)| *item_id);
    for (item_id, price) in rows {
        println!(
            "[POC07-DE-MAT] item_id={item_id} name={:?} unit_buyout={} ({})",
            poc07_de_mat_name(item_id),
            price,
            poc06_format_money(price)
        );
    }
    Ok(prices)
}

fn poc07_de_expected_value(
    info: Poc07DeItemInfo,
    mat_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
) -> Option<u32> {
    let outcomes = poc07_de_outcomes(info)?;
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
    // Missing material prices intentionally contribute zero: conservative lower-bound EV.
    let gross = numerator / 1_000_000u128; // qty_x100 * probability_bps
    let net = gross.saturating_mul(u128::from(net_bps)) / 10_000u128;
    u32::try_from(net.min(u128::from(u32::MAX))).ok()
}

pub fn login_poc07_delive(
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

    // This binary is intentionally scan-only. Any attempt to arm mutation is rejected.
    if !matches!(poc07_parse_mode()?, Poc07Mode::ScanOnly) {
        return Err("POC07-DE-LIVE is hard read-only; BUY is disabled in this build".to_string());
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
        "[POC07-DE] mode=ScanOnly page_start={page_start} pages={page_count} max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} scope=quality2-3_ilvl31-65 blacklist={} mutation=DISABLED",
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
            "poc07-de-live-scan",
        )?;
        scanned.extend(records.into_iter().map(|record| (page, record)));
    }
    println!("[POC07-DE] AH SCAN PASS records={}", scanned.len());

    let mat_prices = poc07_collect_de_material_prices(&scanned)?;

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

    println!("[POC07-DE] item template valuation start unique_items={}", item_ids.len());
    let mut de_values = std::collections::HashMap::<u32, u32>::new();
    let mut supported = 0usize;
    let mut missing = 0usize;
    for (index, item_id) in item_ids.iter().copied().enumerate() {
        match poc07_query_item_info(stream, &mut crypto, item_id)? {
            Some(info) => {
                if let Some(value) = poc07_de_expected_value(info, &mat_prices, net_bps) {
                    if value > 0 {
                        de_values.insert(item_id, value);
                        supported += 1;
                        println!(
                            "[POC07-DE-VALUE] item_id={} class={} quality={} inventory={} ilvl={} conservative_net_ev={} ({}) progress={}/{}",
                            info.item_id,
                            info.item_class,
                            info.quality,
                            info.inventory_type,
                            info.item_level,
                            value,
                            poc06_format_money(value),
                            index + 1,
                            item_ids.len()
                        );
                    }
                }
            }
            None => missing += 1,
        }
    }
    println!(
        "[POC07-DE] valuation PASS queried={} supported={} missing_templates={} material_coverage={}/{}",
        item_ids.len(),
        supported,
        missing,
        mat_prices.len(),
        POC07_DE_MATERIALS.len()
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

    println!("[POC07-DE] REAL DE SCAN-ONLY PASS no_mutation=YES");
    if soak_seconds > 0 {
        maintain_world_session(stream, &mut crypto, soak_seconds)?;
    }
    println!("[POC07-DE] AUTOBUY ENGINE PASS mode=ScanOnly mutation=DISABLED");
    Ok(())
}
