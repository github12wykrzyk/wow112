from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc07_de_v52_turbo_patch.py INPUT_V5 OUTPUT_V52')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'pub fn login_poc07_delive_v5('
idx = src.index(marker)

helpers = r'''
fn poc07_de_send_item_query_v52(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    item_id: u32,
) -> Result<(), String> {
    let mut request = Vec::with_capacity(12);
    request.extend_from_slice(&item_id.to_le_bytes());
    request.extend_from_slice(&0u64.to_le_bytes());
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        POC07_CMSG_ITEM_QUERY_SINGLE_OPCODE,
        &request,
    )
}

fn poc07_de_query_item_infos_turbo_v52(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    item_ids: &[u32],
    window: usize,
) -> Result<std::collections::HashMap<u32, Option<Poc07DeItemInfo>>, String> {
    if window == 0 || window > 128 {
        return Err(format!("V5.2 turbo item-query window must be 1..128, got {window}"));
    }
    let started = std::time::Instant::now();
    let mut results = std::collections::HashMap::<u32, Option<Poc07DeItemInfo>>::new();
    let mut pending = HashSet::<u32>::new();
    let mut next = 0usize;
    let mut rx_packets = 0usize;

    while next < item_ids.len() && pending.len() < window {
        let item_id = item_ids[next];
        poc07_de_send_item_query_v52(stream, crypto, item_id)?;
        pending.insert(item_id);
        next += 1;
    }
    println!(
        "[POC07-DE-V52-TURBO] ITEM-QUERY START total={} window={} initial_inflight={}",
        item_ids.len(),
        window,
        pending.len()
    );

    while !pending.is_empty() {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        rx_packets += 1;
        if opcode == POC07_SMSG_ITEM_QUERY_SINGLE_RESPONSE_OPCODE {
            if payload.len() < 4 {
                return Err(format!("V5.2 turbo item response too short len={}", payload.len()));
            }
            let raw_entry = read_u32_at(&payload, 0)?;
            let item_id = raw_entry & 0x7fff_ffff;
            if pending.remove(&item_id) {
                let parsed = poc07_parse_item_info(&payload, item_id)?;
                results.insert(item_id, parsed);

                while next < item_ids.len() && pending.len() < window {
                    let next_id = item_ids[next];
                    poc07_de_send_item_query_v52(stream, crypto, next_id)?;
                    pending.insert(next_id);
                    next += 1;
                }

                let done = results.len();
                if done <= 16 || done % 100 == 0 || done == item_ids.len() {
                    let elapsed = started.elapsed().as_secs_f64().max(0.001);
                    println!(
                        "[POC07-DE-V52-TURBO] ITEM-QUERY progress={}/{} inflight={} sent={} qps={:.1}",
                        done,
                        item_ids.len(),
                        pending.len(),
                        next,
                        done as f64 / elapsed
                    );
                }
                continue;
            }
            if results.contains_key(&item_id) {
                println!("[POC07-DE-V52-TURBO-DIAG] duplicate item response item_id={item_id}");
            } else if rx_packets <= 32 {
                println!("[POC07-DE-V52-TURBO-DIAG] unrelated item response item_id={item_id}");
            }
            continue;
        }
        if rx_packets <= 16 {
            println!(
                "[POC07-DE-V52-TURBO-DIAG] background rx opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    let elapsed = started.elapsed().as_secs_f64().max(0.001);
    println!(
        "[POC07-DE-V52-TURBO] ITEM-QUERY PASS total={} elapsed_s={:.3} qps={:.1} rx_packets={} window={}",
        results.len(),
        elapsed,
        results.len() as f64 / elapsed,
        rx_packets,
        window
    );
    Ok(results)
}

'''

out = src[:idx] + helpers + src[idx:]
out = out.replace('pub fn login_poc07_delive_v5(', 'pub fn login_poc07_delive_v52(', 1)
out = out.replace('POC07-DE-LIVE-V5 is hard read-only; BUY is disabled in this build', 'POC07-DE-LIVE-V5.2 is hard read-only; BUY is disabled in this build', 1)
out = out.replace('[POC07-DE-V5]', '[POC07-DE-V5.2]')

old_cfg = '''    let filter_max_pages = poc07_env_u32_default("WOW112_DE_FILTER_MAX_PAGES", 256)?;\n    if net_bps == 0 || net_bps > 10_000 { return Err(format!("WOW112_DE_NET_BPS must be 1..10000, got {net_bps}")); }\n    if filter_max_pages == 0 || filter_max_pages > 512 { return Err(format!("WOW112_DE_FILTER_MAX_PAGES must be 1..512, got {filter_max_pages}")); }'''
new_cfg = '''    let filter_max_pages = poc07_env_u32_default("WOW112_DE_FILTER_MAX_PAGES", 256)?;\n    let item_query_window = poc07_env_u32_default("WOW112_DE_ITEM_QUERY_WINDOW", 32)? as usize;\n    if net_bps == 0 || net_bps > 10_000 { return Err(format!("WOW112_DE_NET_BPS must be 1..10000, got {net_bps}")); }\n    if filter_max_pages == 0 || filter_max_pages > 512 { return Err(format!("WOW112_DE_FILTER_MAX_PAGES must be 1..512, got {filter_max_pages}")); }\n    if item_query_window == 0 || item_query_window > 128 { return Err(format!("WOW112_DE_ITEM_QUERY_WINDOW must be 1..128, got {item_query_window}")); }'''
if old_cfg not in out:
    raise SystemExit('V5.2 config marker not found')
out = out.replace(old_cfg, new_cfg, 1)

old_mode = '''    println!("[POC07-DE-V5.2] mode=ScanOnly source=server-filtered(class=2+4,min_quality=2) max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} filter_max_pages={filter_max_pages} de_scope=q2-q3_itemLevel1-65_count1 blacklist={} mutation=DISABLED disenchant_id_gate=UNAVAILABLE_NO_BUY", blacklist.len());'''
new_mode = '''    println!("[POC07-DE-V5.2] mode=ScanOnly source=server-filtered(class=2+4,min_quality=2) max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} filter_max_pages={filter_max_pages} item_query_window={item_query_window} de_scope=q2-q3_itemLevel1-65_count1 blacklist={} mutation=DISABLED disenchant_id_gate=OFFLINE_EXTERNAL", blacklist.len());\n    println!("[POC07-DE-V52-TURBO] AH paging=response-paced sleep_ms=0 item_query_window={item_query_window}");'''
if old_mode not in out:
    raise SystemExit('V5.2 mode marker not found')
out = out.replace(old_mode, new_mode, 1)

old_scan = '''    let mut scanned = Vec::<(u32, Poc06AuctionRecord)>::new();\n    scanned.extend(poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 2, ceiling, filter_max_pages)?);\n    scanned.extend(poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 4, ceiling, filter_max_pages)?);\n    println!("[POC07-DE-V5.2] FILTERED ECONOMIC AH SCAN PASS records={} ceiling={} ({})", scanned.len(), ceiling, poc06_format_money(ceiling));'''
new_scan = '''    let ah_scan_started = std::time::Instant::now();\n    let mut scanned = Vec::<(u32, Poc06AuctionRecord)>::new();\n    let weapon_started = std::time::Instant::now();\n    let weapon_rows = poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 2, ceiling, filter_max_pages)?;\n    let weapon_elapsed = weapon_started.elapsed().as_secs_f64().max(0.001);\n    let weapon_pages = weapon_rows.iter().map(|(p, _)| p % 10_000).max().map(|p| p + 1).unwrap_or(0);\n    println!("[POC07-DE-V52-TURBO] AH-CLASS PASS class=2 pages~{} kept={} elapsed_s={:.3} pages_per_s={:.2}", weapon_pages, weapon_rows.len(), weapon_elapsed, weapon_pages as f64 / weapon_elapsed);\n    scanned.extend(weapon_rows);\n    let armor_started = std::time::Instant::now();\n    let armor_rows = poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 4, ceiling, filter_max_pages)?;\n    let armor_elapsed = armor_started.elapsed().as_secs_f64().max(0.001);\n    let armor_pages = armor_rows.iter().map(|(p, _)| p % 10_000).max().map(|p| p + 1).unwrap_or(0);\n    println!("[POC07-DE-V52-TURBO] AH-CLASS PASS class=4 pages~{} kept={} elapsed_s={:.3} pages_per_s={:.2}", armor_pages, armor_rows.len(), armor_elapsed, armor_pages as f64 / armor_elapsed);\n    scanned.extend(armor_rows);\n    let ah_elapsed = ah_scan_started.elapsed().as_secs_f64().max(0.001);\n    println!("[POC07-DE-V5.2] FILTERED ECONOMIC AH SCAN PASS records={} ceiling={} ({}) elapsed_s={:.3}", scanned.len(), ceiling, poc06_format_money(ceiling), ah_elapsed);'''
if old_scan not in out:
    raise SystemExit('V5.2 AH scan marker not found')
out = out.replace(old_scan, new_scan, 1)

old_loop = '''    let mut de_values = std::collections::HashMap::<u32, u32>::new();\n    let mut model_supported = 0usize;\n    let mut priced_supported = 0usize;\n    let mut missing_templates = 0usize;\n    for (index, item_id) in item_ids.iter().copied().enumerate() {\n        match poc07_query_item_info(stream, &mut crypto, item_id)? {\n            Some(info) => {\n                let model = poc07_de_outcomes_v4(info);\n                if model.is_some() { model_supported += 1; }\n                let value = poc07_de_expected_value_v4(info, &mat_prices, net_bps);\n                if let Some(ev) = value {\n                    if ev > 0 {\n                        de_values.insert(item_id, ev);\n                        priced_supported += 1;\n                    }\n                }\n                if index < 40 || value.is_some() {\n                    println!("[POC07-DE-ITEMINFO-V4] item_id={} class={} quality={} inventory={} ilvl={} model_supported={} fully_priced={} net_ev={} progress={}/{}", info.item_id, info.item_class, info.quality, info.inventory_type, info.item_level, model.is_some(), value.is_some(), value.unwrap_or(0), index + 1, item_ids.len());\n                }\n            }\n            None => missing_templates += 1,\n        }\n    }'''
new_loop = '''    let item_query_started = std::time::Instant::now();\n    let turbo_infos = poc07_de_query_item_infos_turbo_v52(stream, &mut crypto, &item_ids, item_query_window)?;\n    let mut de_values = std::collections::HashMap::<u32, u32>::new();\n    let mut model_supported = 0usize;\n    let mut priced_supported = 0usize;\n    let mut missing_templates = 0usize;\n    for (index, item_id) in item_ids.iter().copied().enumerate() {\n        match turbo_infos.get(&item_id).copied().flatten() {\n            Some(info) => {\n                let model = poc07_de_outcomes_v4(info);\n                if model.is_some() { model_supported += 1; }\n                let value = poc07_de_expected_value_v4(info, &mat_prices, net_bps);\n                if let Some(ev) = value {\n                    if ev > 0 {\n                        de_values.insert(item_id, ev);\n                        priced_supported += 1;\n                    }\n                }\n                if index < 40 || value.is_some() {\n                    println!("[POC07-DE-ITEMINFO-V52] item_id={} class={} quality={} inventory={} ilvl={} model_supported={} fully_priced={} net_ev={} progress={}/{}", info.item_id, info.item_class, info.quality, info.inventory_type, info.item_level, model.is_some(), value.is_some(), value.unwrap_or(0), index + 1, item_ids.len());\n                }\n            }\n            None => missing_templates += 1,\n        }\n    }\n    let item_query_elapsed = item_query_started.elapsed().as_secs_f64().max(0.001);\n    println!("[POC07-DE-V52-TURBO] TEMPLATE STAGE PASS queried={} elapsed_s={:.3} qps={:.1} window={}", item_ids.len(), item_query_elapsed, item_ids.len() as f64 / item_query_elapsed, item_query_window);'''
if old_loop not in out:
    raise SystemExit('V5.2 sequential item loop marker not found')
out = out.replace(old_loop, new_loop, 1)

Path(sys.argv[2]).write_text(out, encoding='utf-8')
