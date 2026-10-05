from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: vendor_fullsweep_turbo_patch.py INPUT_VENDORLIVE OUTPUT_FULLSWEEP')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

marker = 'pub fn login_poc07_vendorlive('
idx = src.index(marker)
helpers = r'''
fn poc07_send_vendor_item_query_turbo(
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

fn poc07_fill_live_vendor_values_turbo(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    scanned: &[(u32, Poc06AuctionRecord)],
    max_buyout: u32,
    blacklist: &HashSet<u32>,
    vendor_values: &mut std::collections::HashMap<u32, u32>,
    window: usize,
) -> Result<(), String> {
    if window == 0 || window > 128 {
        return Err(format!("vendor turbo item-query window must be 1..128, got {window}"));
    }

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

    let started = std::time::Instant::now();
    let mut pending = HashSet::<u32>::new();
    let mut next = 0usize;
    let mut done = 0usize;
    let mut sellable = 0usize;
    let mut zero_or_missing = 0usize;
    let mut rx_packets = 0usize;

    while next < item_ids.len() && pending.len() < window {
        let item_id = item_ids[next];
        poc07_send_vendor_item_query_turbo(stream, crypto, item_id)?;
        pending.insert(item_id);
        next += 1;
    }

    println!(
        "[POC07-VENDOR-TURBO] ITEM-QUERY START total={} window={} initial_inflight={}",
        item_ids.len(), window, pending.len()
    );

    while !pending.is_empty() {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        rx_packets += 1;
        if opcode == POC07_SMSG_ITEM_QUERY_SINGLE_RESPONSE_OPCODE {
            if payload.len() < 4 {
                return Err(format!("vendor turbo item response too short len={}", payload.len()));
            }
            let raw_entry = read_u32_at(&payload, 0)?;
            let item_id = raw_entry & 0x7fff_ffff;
            if pending.remove(&item_id) {
                match poc07_parse_item_sell_price(&payload, item_id)? {
                    Some(value) if value > 0 => {
                        vendor_values.insert(item_id, value);
                        sellable += 1;
                    }
                    Some(_) | None => {
                        vendor_values.remove(&item_id);
                        zero_or_missing += 1;
                    }
                }
                done += 1;

                while next < item_ids.len() && pending.len() < window {
                    let next_id = item_ids[next];
                    poc07_send_vendor_item_query_turbo(stream, crypto, next_id)?;
                    pending.insert(next_id);
                    next += 1;
                }

                if done <= 16 || done % 100 == 0 || done == item_ids.len() {
                    let elapsed = started.elapsed().as_secs_f64().max(0.001);
                    println!(
                        "[POC07-VENDOR-TURBO] progress={}/{} inflight={} sent={} qps={:.1}",
                        done, item_ids.len(), pending.len(), next, done as f64 / elapsed
                    );
                }
                continue;
            }
        }

        if rx_packets <= 16 {
            println!(
                "[POC07-VENDOR-TURBO-DIAG] background rx opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    let elapsed = started.elapsed().as_secs_f64().max(0.001);
    println!(
        "[POC07-VENDOR-TURBO] ITEM-QUERY PASS queried={} sellable={} zero_or_missing={} elapsed_s={:.3} qps={:.1} window={} rx_packets={}",
        done, sellable, zero_or_missing, elapsed, done as f64 / elapsed, window, rx_packets
    );
    Ok(())
}

'''
out = src[:idx] + helpers + src[idx:]
out = out.replace('pub fn login_poc07_vendorlive(', 'pub fn login_poc07_vendorlive_fullsweep(', 1)

old_cfg = '''    let page_start = poc07_env_u32_default("WOW112_AH_SCAN_PAGE_START", 12)?;\n    let page_count = poc07_env_u32_default("WOW112_AH_SCAN_PAGES", 3)?;\n    if page_count == 0 || page_count > 32 {\n        return Err(format!("WOW112_AH_SCAN_PAGES must be 1..32, got {page_count}"));\n    }'''
new_cfg = '''    let page_start = poc07_env_u32_default("WOW112_AH_SCAN_PAGE_START", 0)?;\n    let page_count = poc07_env_u32_default("WOW112_AH_SCAN_PAGES", 0)?; // 0 = full sweep\n    let vendor_item_query_window = poc07_env_u32_default("WOW112_VENDOR_ITEM_QUERY_WINDOW", 64)? as usize;\n    if page_count > 2048 {\n        return Err(format!("WOW112_AH_SCAN_PAGES must be 0..2048, got {page_count}"));\n    }\n    if vendor_item_query_window == 0 || vendor_item_query_window > 128 {\n        return Err(format!("WOW112_VENDOR_ITEM_QUERY_WINDOW must be 1..128, got {vendor_item_query_window}"));\n    }'''
if old_cfg not in out:
    raise SystemExit('vendor fullsweep config marker not found')
out = out.replace(old_cfg, new_cfg, 1)

old_mode = '''    println!(\n        "[POC07-LIVE] mode={mode:?} page_start={page_start} pages={page_count} max_buyout={max_buyout} min_profit={min_profit} vendor_source={} de_values={} blacklist={} hard_max_purchases=1",\n        if use_vendor { "server-item-query" } else { "disabled" },\n        de_values.len(),\n        blacklist.len()\n    );'''
new_mode = '''    println!(\n        "[POC07-LIVE-FULL] mode={mode:?} page_start={page_start} pages={} max_buyout={max_buyout} min_profit={min_profit} vendor_source={} vendor_item_query_window={} de_values={} blacklist={} hard_max_purchases=1",\n        if page_count == 0 { "FULL".to_string() } else { page_count.to_string() },\n        if use_vendor { "server-item-query" } else { "disabled" },\n        vendor_item_query_window,\n        de_values.len(),\n        blacklist.len()\n    );'''
if old_mode not in out:
    raise SystemExit('vendor fullsweep mode marker not found')
out = out.replace(old_mode, new_mode, 1)

old_scan = '''    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();\n    for offset in 0..page_count {\n        let page = page_start\n            .checked_add(offset)\n            .ok_or_else(|| "AH scan page overflow".to_string())?;\n        let records = poc07_request_auction_page(\n            stream,\n            &mut crypto,\n            auctioneer_guid,\n            auction_house,\n            page,\n            "poc07-live-scan",\n        )?;\n        scanned.extend(records.into_iter().map(|record| (page, record)));\n    }\n    println!("[POC07-LIVE] AH SCAN PASS records={}", scanned.len());'''
new_scan = '''    let scan_started = std::time::Instant::now();\n    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();\n    let full_sweep = page_count == 0;\n    let max_pages = if full_sweep { 2048 } else { page_count };\n    let mut pages_done = 0u32;\n    for offset in 0..max_pages {\n        let page = page_start\n            .checked_add(offset)\n            .ok_or_else(|| "AH scan page overflow".to_string())?;\n        let records = poc07_request_auction_page(\n            stream,\n            &mut crypto,\n            auctioneer_guid,\n            auction_house,\n            page,\n            "poc07-live-full-scan",\n        )?;\n        let record_count = records.len();\n        scanned.extend(records.into_iter().map(|record| (page, record)));\n        pages_done += 1;\n        if pages_done <= 8 || pages_done % 50 == 0 {\n            let elapsed = scan_started.elapsed().as_secs_f64().max(0.001);\n            println!(\n                "[POC07-LIVE-FULL] AH progress pages={} records={} pages_per_s={:.2}",\n                pages_done, scanned.len(), pages_done as f64 / elapsed\n            );\n        }\n        if full_sweep && record_count < 50 {\n            println!("[POC07-LIVE-FULL] AH end detected page={} records_on_last_page={}", page, record_count);\n            break;\n        }\n    }\n    let scan_elapsed = scan_started.elapsed().as_secs_f64().max(0.001);\n    println!(\n        "[POC07-LIVE-FULL] AH SCAN PASS pages={} records={} elapsed_s={:.3} pages_per_s={:.2}",\n        pages_done, scanned.len(), scan_elapsed, pages_done as f64 / scan_elapsed\n    );'''
if old_scan not in out:
    raise SystemExit('vendor fullsweep scan marker not found')
out = out.replace(old_scan, new_scan, 1)

old_call = '''        poc07_fill_live_vendor_values(\n            stream,\n            &mut crypto,\n            &scanned,\n            max_buyout,\n            &blacklist,\n            &mut vendor_values,\n        )?;'''
new_call = '''        poc07_fill_live_vendor_values_turbo(\n            stream,\n            &mut crypto,\n            &scanned,\n            max_buyout,\n            &blacklist,\n            &mut vendor_values,\n            vendor_item_query_window,\n        )?;'''
if old_call not in out:
    raise SystemExit('vendor turbo call marker not found')
out = out.replace(old_call, new_call, 1)

Path(sys.argv[2]).write_text(out, encoding='utf-8')
