from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc07_de_v4_patch.py INPUT_V2 OUTPUT_V4')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'pub fn login_poc07_delive_v2('
idx = src.index(marker)
prefix = src[:idx]

v4 = r'''
const POC07_DE_MATERIALS_V4: &[(u32, &str)] = &[
    (10938, "Lesser Magic Essence"),
    (10939, "Greater Magic Essence"),
    (10940, "Strange Dust"),
    (10978, "Small Glimmering Shard"),
    (10998, "Lesser Astral Essence"),
    (11082, "Greater Astral Essence"),
    (11083, "Soul Dust"),
    (11084, "Large Glimmering Shard"),
    (11134, "Lesser Mystic Essence"),
    (11135, "Greater Mystic Essence"),
    (11137, "Vision Dust"),
    (11138, "Small Glowing Shard"),
    (11139, "Large Glowing Shard"),
    (11174, "Lesser Nether Essence"),
    (11175, "Greater Nether Essence"),
    (11176, "Dream Dust"),
    (11177, "Small Radiant Shard"),
    (11178, "Large Radiant Shard"),
    (14343, "Small Brilliant Shard"),
    (14344, "Large Brilliant Shard"),
    (16202, "Lesser Eternal Essence"),
    (16203, "Greater Eternal Essence"),
    (16204, "Illusion Dust"),
    (20725, "Nexus Crystal"),
];

fn poc07_de_material_name_v4(item_id: u32) -> &'static str {
    POC07_DE_MATERIALS_V4
        .iter()
        .find(|(id, _)| *id == item_id)
        .map(|(_, name)| *name)
        .unwrap_or("unknown")
}

fn poc07_de_outcomes_v4(info: Poc07DeItemInfo) -> Option<Vec<Poc07DeOutcome>> {
    if info.item_class != 2 && info.item_class != 4 {
        return None;
    }
    let weapon = info.item_class == 2;

    match info.quality {
        2 => {
            let (dust, dust_qty, essence, essence_qty, shard, dust_bps, essence_bps, shard_bps) =
                match info.item_level {
                    5..=15 if !weapon => (10940, 150, 10938, 150, 0, 8000, 2000, 0),
                    6..=15 if weapon => (10940, 150, 10938, 150, 0, 2000, 8000, 0),
                    16..=20 => (10940, 250, 10939, 150, 10978, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    21..=25 => (10940, 500, 10998, 150, 10978, if weapon { 1500 } else { 7500 }, if weapon { 7500 } else { 1500 }, 1000),
                    26..=30 => (11083, 150, 11082, 150, 11084, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    31..=35 => (11083, 350, 11134, 150, 11138, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    36..=40 => (11137, 150, 11135, 150, 11139, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    41..=45 => (11137, 350, 11174, 150, 11177, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    46..=50 => (11176, 150, 11175, 150, 11178, if weapon { 2000 } else { 7500 }, if weapon { 7500 } else { 2000 }, 500),
                    51..=55 => (11176, 350, 16202, 150, 14343, if weapon { 2200 } else { 7500 }, if weapon { 7500 } else { 2000 }, if weapon { 300 } else { 500 }),
                    56..=60 => (16204, 150, 16203, 150, 14344, if weapon { 2200 } else { 7500 }, if weapon { 7500 } else { 2000 }, if weapon { 300 } else { 500 }),
                    61..=65 => (16204, 350, 16203, 250, 14344, if weapon { 2200 } else { 7500 }, if weapon { 7500 } else { 2000 }, if weapon { 300 } else { 500 }),
                    _ => return None,
                };
            let mut out = vec![
                Poc07DeOutcome { material_id: dust, probability_bps: dust_bps, avg_qty_x100: dust_qty },
                Poc07DeOutcome { material_id: essence, probability_bps: essence_bps, avg_qty_x100: essence_qty },
            ];
            if shard != 0 && shard_bps != 0 {
                out.push(Poc07DeOutcome { material_id: shard, probability_bps: shard_bps, avg_qty_x100: 100 });
            }
            Some(out)
        }
        3 => {
            let shard = match info.item_level {
                1..=25 => 10978,
                26..=30 => 11084,
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
            Some(vec![Poc07DeOutcome { material_id: shard, probability_bps: 10_000, avg_qty_x100: 100 }])
        }
        _ => None,
    }
}

fn poc07_de_parse_item_name_v4(payload: &[u8], expected_item_id: u32) -> Result<Option<String>, String> {
    if payload.len() < 13 {
        return Err(format!("item-name response too short item={expected_item_id} len={}", payload.len()));
    }
    let raw_entry = read_u32_at(payload, 0)?;
    if raw_entry & 0x8000_0000 != 0 {
        let missing = raw_entry & 0x7fff_ffff;
        if missing == expected_item_id {
            return Ok(None);
        }
        return Err(format!("item-name not-found mismatch expected={expected_item_id} got={missing}"));
    }
    if raw_entry != expected_item_id {
        return Err(format!("item-name response mismatch expected={expected_item_id} got={raw_entry}"));
    }
    let start = 12usize;
    let rel_end = payload[start..]
        .iter()
        .position(|b| *b == 0)
        .ok_or_else(|| format!("item-name missing NUL item={expected_item_id}"))?;
    let name = String::from_utf8_lossy(&payload[start..start + rel_end]).to_string();
    if name.is_empty() {
        return Err(format!("item-name empty item={expected_item_id}"));
    }
    Ok(Some(name))
}

fn poc07_de_query_item_name_v4(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    item_id: u32,
) -> Result<Option<String>, String> {
    let mut request = Vec::with_capacity(12);
    request.extend_from_slice(&item_id.to_le_bytes());
    request.extend_from_slice(&0u64.to_le_bytes());
    write_encrypted_raw(stream, crypto.encrypter(), POC07_CMSG_ITEM_QUERY_SINGLE_OPCODE, &request)?;
    for index in 0..128usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == POC07_SMSG_ITEM_QUERY_SINGLE_RESPONSE_OPCODE {
            match poc07_de_parse_item_name_v4(&payload, item_id) {
                Ok(value) => return Ok(value),
                Err(error) if error.contains("mismatch") => {
                    if index < 4 {
                        println!("[POC07-DE-V4-DIAG] unrelated item-name response item_id={item_id}: {error}");
                    }
                    continue;
                }
                Err(error) => return Err(error),
            }
        }
        if index < 3 {
            println!("[POC07-DE-V4-DIAG] item-name wait item_id={item_id} rx[{index}] opcode=0x{opcode:04X} payload={}", payload.len());
        }
    }
    Err(format!("item-name response not received item_id={item_id}"))
}

fn poc07_collect_de_material_prices_v4(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
) -> Result<std::collections::HashMap<u32, u32>, String> {
    let overrides = poc07_parse_value_map("WOW112_DE_MAT_VALUES")?;
    let mut prices = std::collections::HashMap::<u32, u32>::new();

    for (material_id, english_name) in POC07_DE_MATERIALS_V4.iter().copied() {
        if let Some(value) = overrides.get(&material_id).copied() {
            prices.insert(material_id, value);
            println!("[POC07-DE-MAT-V4] OVERRIDE item_id={material_id} name={english_name:?} unit={} ({})", value, poc06_format_money(value));
            continue;
        }

        let live_name = poc07_de_query_item_name_v4(stream, crypto, material_id)?
            .unwrap_or_else(|| english_name.to_string());
        let mut page = 0u32;
        let mut found: Option<u32> = None;
        let mut total_seen = 0u32;
        loop {
            if page >= 256 {
                return Err(format!("DE material price fail-closed item_id={material_id}: exceeded 256 pages"));
            }
            let (records, total) = poc07_de_request_named_page(
                stream,
                crypto,
                auctioneer_guid,
                auction_house,
                material_id,
                &live_name,
                page,
            )?;
            total_seen = total;
            for record in records.iter().copied() {
                if record.item_id != material_id || record.buyout == 0 || record.count == 0 {
                    continue;
                }
                let unit = (u64::from(record.buyout) + u64::from(record.count) - 1) / u64::from(record.count);
                let unit = u32::try_from(unit).map_err(|_| "DE material unit price overflow".to_string())?;
                found = Some(found.map(|current| current.min(unit)).unwrap_or(unit));
            }
            if found.is_some() {
                break;
            }
            let list_from = page.saturating_mul(50);
            if total == 0 || records.is_empty() || list_from.saturating_add(records.len() as u32) >= total {
                break;
            }
            page = page.saturating_add(1);
        }

        if let Some(price) = found {
            prices.insert(material_id, price);
            println!("[POC07-DE-MAT-V4] PASS item_id={material_id} name={live_name:?} source_name={english_name:?} first_positive_page={page} total_name_matches={total_seen} unit_buyout={} ({})", price, poc06_format_money(price));
        } else {
            println!("[POC07-DE-MAT-V4] MISSING item_id={material_id} name={live_name:?} total_name_matches={total_seen} strict_value=UNAVAILABLE");
        }
    }

    println!("[POC07-DE-V4] MATERIAL PRICE PASS coverage={}/{} strict_missing={}", prices.len(), POC07_DE_MATERIALS_V4.len(), POC07_DE_MATERIALS_V4.len().saturating_sub(prices.len()));
    Ok(prices)
}

fn poc07_de_expected_value_v4(
    info: Poc07DeItemInfo,
    prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
) -> Option<u32> {
    let outcomes = poc07_de_outcomes_v4(info)?;
    let mut numerator: u128 = 0;
    for outcome in outcomes {
        let price = prices.get(&outcome.material_id).copied()?;
        numerator = numerator.saturating_add(
            u128::from(price)
                .saturating_mul(u128::from(outcome.avg_qty_x100))
                .saturating_mul(u128::from(outcome.probability_bps)),
        );
    }
    let gross = numerator / 1_000_000u128;
    let net = gross.saturating_mul(u128::from(net_bps)) / 10_000u128;
    u32::try_from(net.min(u128::from(u32::MAX))).ok()
}

fn poc07_de_global_ceiling_v4(
    prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
    max_buyout: u32,
    min_profit: i64,
) -> Result<u32, String> {
    let mut max_ev = 0u32;
    let mut priced_tiers = 0usize;
    for item_class in [2u32, 4u32] {
        for quality in [2u32, 3u32] {
            for item_level in 1u32..=65u32 {
                let info = Poc07DeItemInfo { item_id: 0, item_class, quality, inventory_type: 0, item_level };
                if poc07_de_outcomes_v4(info).is_none() {
                    continue;
                }
                if let Some(ev) = poc07_de_expected_value_v4(info, prices, net_bps) {
                    priced_tiers += 1;
                    max_ev = max_ev.max(ev);
                }
            }
        }
    }
    if priced_tiers == 0 || max_ev == 0 {
        return Err("POC07-DE-V4 has no fully-priced disenchant tier; refusing incomplete economic scan".to_string());
    }
    let required_profit = u64::try_from(min_profit.max(0)).unwrap_or(0);
    let economic_ceiling = u64::from(max_ev).saturating_sub(required_profit);
    let ceiling = u64::from(max_buyout).min(economic_ceiling).min(u64::from(u32::MAX)) as u32;
    println!("[POC07-DE-V4] ECONOMIC CEILING PASS priced_tiers={priced_tiers} max_unit_net_ev={} ({}) min_profit={} scan_buyout_ceiling={} ({}) scope=count1-only", max_ev, poc06_format_money(max_ev), min_profit, ceiling, poc06_format_money(ceiling));
    Ok(ceiling)
}

fn poc07_de_build_class_query_v4(
    auctioneer_guid: u64,
    list_from: u32,
    item_class: u32,
    min_quality: u32,
) -> Vec<u8> {
    let mut payload = Vec::with_capacity(32);
    payload.extend_from_slice(&auctioneer_guid.to_le_bytes());
    payload.extend_from_slice(&list_from.to_le_bytes());
    payload.push(0);
    payload.push(0);
    payload.push(0);
    payload.extend_from_slice(&u32::MAX.to_le_bytes());
    payload.extend_from_slice(&item_class.to_le_bytes());
    payload.extend_from_slice(&u32::MAX.to_le_bytes());
    payload.extend_from_slice(&min_quality.to_le_bytes());
    payload.push(0);
    payload
}

fn poc07_de_request_class_page_v4(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    item_class: u32,
    page: u32,
) -> Result<(Vec<Poc06AuctionRecord>, u32), String> {
    let list_from = page.checked_mul(50).ok_or_else(|| format!("AH filtered page overflow page={page}"))?;
    let query = poc07_de_build_class_query_v4(auctioneer_guid, list_from, item_class, 2);
    println!("[POC07-DE-FILTER-V4] query class={item_class} min_quality=2 page={page} listfrom={list_from} house={auction_house}");
    write_encrypted_raw(stream, crypto.encrypter(), CMSG_AUCTION_LIST_ITEMS_OPCODE, &query)?;
    let mut discovered = HashSet::new();
    for index in 0..256usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            let (records, total) = poc07_de_parse_auction_list_with_total(&payload)?;
            println!("[POC07-DE-FILTER-V4] snapshot PASS class={item_class} page={page} records={} total={total}", records.len());
            return Ok((records, total));
        }
        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 3 {
            println!("[POC07-DE-FILTER-V4-DIAG] wait class={item_class} page={page} rx[{index}] opcode=0x{opcode:04X} payload={}", payload.len());
        }
    }
    Err(format!("filtered AH response not received class={item_class} page={page}"))
}

fn poc07_de_scan_class_v4(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    item_class: u32,
    ceiling: u32,
    max_pages: u32,
) -> Result<Vec<(u32, Poc06AuctionRecord)>, String> {
    let mut out = Vec::new();
    let mut page = 0u32;
    let mut last_positive = 0u32;
    loop {
        if page >= max_pages {
            return Err(format!("DE filtered scan fail-closed class={item_class}: exceeded max_pages={max_pages} before total/ceiling stop"));
        }
        let (records, total) = poc07_de_request_class_page_v4(stream, crypto, auctioneer_guid, auction_house, item_class, page)?;
        let count = records.len() as u32;
        let mut crossed = false;
        for record in records.iter().copied() {
            if record.buyout == 0 {
                continue;
            }
            if record.buyout < last_positive {
                return Err(format!("DE filtered scan ordering violation class={item_class} page={page}: buyout={} after={last_positive}", record.buyout));
            }
            last_positive = record.buyout;
            if record.buyout > ceiling {
                crossed = true;
                break;
            }
            if record.count != 1 {
                println!("[POC07-DE-V4-DIAG] unsupported stacked equipment skipped class={item_class} auction_id={} item_id={} count={} buyout={}", record.auction_id, record.item_id, record.count, record.buyout);
                continue;
            }
            let diagnostic_page = item_class.saturating_mul(10_000).saturating_add(page);
            out.push((diagnostic_page, record));
        }
        if crossed {
            println!("[POC07-DE-FILTER-V4] EARLY STOP PASS class={item_class} page={page} first_over_ceiling={} ({}) ceiling={} ({}) kept_records={}", last_positive, poc06_format_money(last_positive), ceiling, poc06_format_money(ceiling), out.len());
            break;
        }
        let list_from = page.saturating_mul(50);
        if total == 0 || count == 0 || list_from.saturating_add(count) >= total {
            println!("[POC07-DE-FILTER-V4] TOTAL STOP PASS class={item_class} pages={} total={total} kept_records={}", page + 1, out.len());
            break;
        }
        page = page.saturating_add(1);
    }
    Ok(out)
}

pub fn login_poc07_delive_v4(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    _ah_mutation_committed: &mut bool,
) -> Result<(), String> {
    stream.set_read_timeout(Some(Duration::from_secs(20))).map_err(|e| format!("set world read timeout failed: {e}"))?;

    let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
        .map_err(|e| format!("read world auth challenge failed: {e:?}"))?;
    let seed = ProofSeed::new();
    let seed_value = seed.seed();
    let normalized_username = NormalizedString::new(username).map_err(|e| format!("invalid account name for world auth: {e:?}"))?;
    let (client_proof, mut crypto) = seed.into_client_header_crypto(&normalized_username, session_key, challenge.server_seed);
    let auth_session = CMSG_AUTH_SESSION {
        build: OCTOWOW_WORLD_BUILD,
        server_id: server_id as u32,
        username: username.to_string(),
        client_seed: seed_value,
        client_proof,
        addon_info: octo_fingerprint_addons(),
    };
    let mut auth_wire = Vec::new();
    auth_session.write_unencrypted_client(&mut auth_wire).map_err(|e| format!("encode world auth session failed: {e:?}"))?;
    let safe_prefix_len = auth_wire.len().min(24);
    println!("[WORLD-DIAG] auth-session-out len={} prefix={} world-build={} server-id={} addons=octo-standard-12", auth_wire.len(), hex_prefix(&auth_wire[..safe_prefix_len]), OCTOWOW_WORLD_BUILD, server_id);
    stream.write_all(&auth_wire).map_err(|e| format!("write world auth session failed: {e:?}"))?;
    world_diag_peek(stream, "auth-response-raw", Duration::from_millis(1500));
    skip_octowow_addon_info(stream, crypto.decrypter())?;

    let auth_response = {
        let mut found = None;
        for index in 0..16usize {
            let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter()).map_err(|e| format!("read world pre-auth opcode failed: {e:?}"))?;
            match opcode {
                ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) => { found = Some(response); break; }
                other if index < 8 => println!("[WORLD] pre-auth rx[{index}] {other:?}"),
                _ => {}
            }
        }
        found.ok_or_else(|| "world auth response not received within 16 packets".to_string())?
    };
    if !matches!(*auth_response, SMSG_AUTH_RESPONSE::AuthOk { .. }) {
        return Err(format!("world auth rejected: {auth_response:?}"));
    }
    println!("[WORLD] auth PASS world-build={OCTOWOW_WORLD_BUILD}");

    CMSG_CHAR_ENUM {}.write_encrypted_client(&mut *stream, crypto.encrypter()).map_err(|e| format!("write character enum request failed: {e:?}"))?;
    let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter()).map_err(|e| format!("read character enum failed: {e:?}"))?;
    if characters.characters.is_empty() { return Err("account has no characters".to_string()); }
    println!("[WORLD] characters={}", characters.characters.len());
    for (index, character) in characters.characters.iter().enumerate() { println!("[WORLD] character[{index}] name={}", character.name); }
    let selected = match character_name {
        Some(wanted) => characters.characters.iter().find(|character| character.name.eq_ignore_ascii_case(wanted)).ok_or_else(|| format!("character not found: {wanted}"))?,
        None => &characters.characters[0],
    };
    let player_guid = selected.guid.guid();
    println!("[WORLD] logging character={}", selected.name);
    CMSG_PLAYER_LOGIN { guid: selected.guid }.write_encrypted_client(&mut *stream, crypto.encrypter()).map_err(|e| format!("write player login failed: {e:?}"))?;

    let mut login_verified = false;
    for index in 0..256usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter()).map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;
        if index < 24 { println!("[WORLD] rx[{index}] {opcode:?}"); }
        if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) { println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS"); login_verified = true; break; }
    }
    if !login_verified { return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string()); }

    if !matches!(poc07_parse_mode()?, Poc07Mode::ScanOnly) {
        return Err("POC07-DE-LIVE-V4 is hard read-only; BUY is disabled in this build".to_string());
    }
    let blacklist = poc07_parse_blacklist()?;
    let max_buyout = poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?;
    let min_profit = i64::from(poc07_env_u32_default("WOW112_AUTOBUY_MIN_PROFIT", 1)?);
    let net_bps = poc07_env_u32_default("WOW112_DE_NET_BPS", 8500)?;
    let filter_max_pages = poc07_env_u32_default("WOW112_DE_FILTER_MAX_PAGES", 256)?;
    if net_bps == 0 || net_bps > 10_000 { return Err(format!("WOW112_DE_NET_BPS must be 1..10000, got {net_bps}")); }
    if filter_max_pages == 0 || filter_max_pages > 512 { return Err(format!("WOW112_DE_FILTER_MAX_PAGES must be 1..512, got {filter_max_pages}")); }
    println!("[POC07-DE-V4] mode=ScanOnly source=server-filtered(class=2+4,min_quality=2) max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} filter_max_pages={filter_max_pages} de_scope=q2-q3_itemLevel1-65_count1 blacklist={} mutation=DISABLED disenchant_id_gate=UNAVAILABLE_NO_BUY", blacklist.len());

    let (auctioneer_candidates, _mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
    let (auctioneer_guid, auction_house) = poc05_send_auction_hello_candidates(stream, &mut crypto, auctioneer_candidates)?;

    let mat_prices = poc07_collect_de_material_prices_v4(stream, &mut crypto, auctioneer_guid, auction_house)?;
    let ceiling = poc07_de_global_ceiling_v4(&mat_prices, net_bps, max_buyout, min_profit)?;
    if ceiling == 0 {
        println!("[POC07-DE-V4] ECONOMIC STOP no positive buyout can meet min_profit; no scan needed");
        println!("[POC07-DE-V4] REAL DE SCAN-ONLY PASS no_mutation=YES");
        return Ok(());
    }

    let mut scanned = Vec::<(u32, Poc06AuctionRecord)>::new();
    scanned.extend(poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 2, ceiling, filter_max_pages)?);
    scanned.extend(poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 4, ceiling, filter_max_pages)?);
    println!("[POC07-DE-V4] FILTERED ECONOMIC AH SCAN PASS records={} ceiling={} ({})", scanned.len(), ceiling, poc06_format_money(ceiling));

    let mut item_ids = scanned.iter().filter_map(|(_, record)| {
        if record.buyout == 0 || record.buyout > ceiling || record.count != 1 || blacklist.contains(&record.item_id) { None } else { Some(record.item_id) }
    }).collect::<Vec<_>>();
    item_ids.sort_unstable();
    item_ids.dedup();
    println!("[POC07-DE-V4] item template valuation start unique_affordable_items={}", item_ids.len());

    let mut de_values = std::collections::HashMap::<u32, u32>::new();
    let mut model_supported = 0usize;
    let mut priced_supported = 0usize;
    let mut missing_templates = 0usize;
    for (index, item_id) in item_ids.iter().copied().enumerate() {
        match poc07_query_item_info(stream, &mut crypto, item_id)? {
            Some(info) => {
                let model = poc07_de_outcomes_v4(info);
                if model.is_some() { model_supported += 1; }
                let value = poc07_de_expected_value_v4(info, &mat_prices, net_bps);
                if let Some(ev) = value {
                    if ev > 0 {
                        de_values.insert(item_id, ev);
                        priced_supported += 1;
                    }
                }
                if index < 40 || value.is_some() {
                    println!("[POC07-DE-ITEMINFO-V4] item_id={} class={} quality={} inventory={} ilvl={} model_supported={} fully_priced={} net_ev={} progress={}/{}", info.item_id, info.item_class, info.quality, info.inventory_type, info.item_level, model.is_some(), value.is_some(), value.unwrap_or(0), index + 1, item_ids.len());
                }
            }
            None => missing_templates += 1,
        }
    }
    println!("[POC07-DE-V4] TEMPLATE+VALUATION PASS queried={} model_supported={} fully_priced={} missing_templates={} material_coverage={}/{}", item_ids.len(), model_supported, priced_supported, missing_templates, mat_prices.len(), POC07_DE_MATERIALS_V4.len());

    let empty_vendor = std::collections::HashMap::<u32, u32>::new();
    let mut candidates = Vec::new();
    for (page, record) in scanned {
        if let Some(candidate) = poc07_consider_candidate(page, record, &empty_vendor, &de_values, false, true, max_buyout, min_profit, &blacklist) {
            candidates.push(candidate);
        }
    }
    candidates.sort_by(|a, b| b.expected_profit.cmp(&a.expected_profit).then_with(|| a.record.buyout.cmp(&b.record.buyout)).then_with(|| a.record.auction_id.cmp(&b.record.auction_id)));
    poc07_print_candidates(&candidates);
    println!("[POC07-DE-V4] CANDIDATE SAFETY disenchant_id_gate=UNVERIFIED all_candidates=READ_ONLY_NO_BUY");
    println!("[POC07-DE-V4] REAL DE SCAN-ONLY PASS no_mutation=YES");
    if soak_seconds > 0 { maintain_world_session(stream, &mut crypto, soak_seconds)?; }
    println!("[POC07-DE-V4] ENGINE PASS mode=ScanOnly mutation=DISABLED");
    Ok(())
}
'''

Path(sys.argv[2]).write_text(prefix + v4, encoding='utf-8')
