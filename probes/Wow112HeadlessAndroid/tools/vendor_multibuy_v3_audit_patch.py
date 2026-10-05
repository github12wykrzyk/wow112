from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: vendor_multibuy_v3_audit_patch.py INPUT_V2 OUTPUT_V3')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

marker = 'pub fn login_poc07_vendorlive_multibuy_v2('
idx = src.index(marker)
helper = r'''
fn poc07_full_scan_pass_v3(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    page_start: u32,
    page_count: u32,
    pass: u32,
) -> Result<Vec<(u32, Poc06AuctionRecord)>, String> {
    let started = std::time::Instant::now();
    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();
    let full_sweep = page_count == 0;
    let max_pages = if full_sweep { 2048 } else { page_count };
    let mut pages_done = 0u32;
    for offset in 0..max_pages {
        let page = page_start
            .checked_add(offset)
            .ok_or_else(|| "AH scan page overflow".to_string())?;
        let records = poc07_request_auction_page(
            stream,
            crypto,
            auctioneer_guid,
            auction_house,
            page,
            if pass == 1 { "poc07-audit-pass1" } else { "poc07-audit-pass2" },
        )?;
        let record_count = records.len();
        scanned.extend(records.into_iter().map(|record| (page, record)));
        pages_done += 1;
        if pages_done <= 4 || pages_done % 100 == 0 {
            let elapsed = started.elapsed().as_secs_f64().max(0.001);
            println!(
                "[POC07-AUDIT] PASS{} progress pages={} records={} pages_per_s={:.2}",
                pass, pages_done, scanned.len(), pages_done as f64 / elapsed
            );
        }
        if full_sweep && record_count < 50 {
            println!(
                "[POC07-AUDIT] PASS{} end page={} records_on_last_page={}",
                pass, page, record_count
            );
            break;
        }
    }
    let elapsed = started.elapsed().as_secs_f64().max(0.001);
    let unique = scanned.iter().map(|(_, r)| r.auction_id).collect::<HashSet<_>>().len();
    let duplicates = scanned.len().saturating_sub(unique);
    println!(
        "[POC07-AUDIT] PASS{} SCAN PASS pages={} records={} unique_auction_ids={} duplicate_rows={} elapsed_s={:.3} pages_per_s={:.2}",
        pass, pages_done, scanned.len(), unique, duplicates, elapsed, pages_done as f64 / elapsed
    );
    Ok(scanned)
}

'''
src = src[:idx] + helper + src[idx:]
src = src.replace('pub fn login_poc07_vendorlive_multibuy_v2(', 'pub fn login_poc07_vendorlive_multibuy_v3(', 1)

old_scan = r'''    let scan_started = std::time::Instant::now();
    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();
    let full_sweep = page_count == 0;
    let max_pages = if full_sweep { 2048 } else { page_count };
    let mut pages_done = 0u32;
    for offset in 0..max_pages {
        let page = page_start
            .checked_add(offset)
            .ok_or_else(|| "AH scan page overflow".to_string())?;
        let records = poc07_request_auction_page(
            stream,
            &mut crypto,
            auctioneer_guid,
            auction_house,
            page,
            "poc07-live-full-scan",
        )?;
        let record_count = records.len();
        scanned.extend(records.into_iter().map(|record| (page, record)));
        pages_done += 1;
        if pages_done <= 8 || pages_done % 50 == 0 {
            let elapsed = scan_started.elapsed().as_secs_f64().max(0.001);
            println!(
                "[POC07-LIVE-FULL] AH progress pages={} records={} pages_per_s={:.2}",
                pages_done, scanned.len(), pages_done as f64 / elapsed
            );
        }
        if full_sweep && record_count < 50 {
            println!("[POC07-LIVE-FULL] AH end detected page={} records_on_last_page={}", page, record_count);
            break;
        }
    }
    let scan_elapsed = scan_started.elapsed().as_secs_f64().max(0.001);
    println!(
        "[POC07-LIVE-FULL] AH SCAN PASS pages={} records={} elapsed_s={:.3} pages_per_s={:.2}",
        pages_done, scanned.len(), scan_elapsed, pages_done as f64 / scan_elapsed
    );'''

new_scan = r'''    println!("[POC07-AUDIT] DOUBLE-SWEEP START purpose=coverage-drift-detection");
    let pass1 = poc07_full_scan_pass_v3(
        stream, &mut crypto, auctioneer_guid, auction_house, page_start, page_count, 1
    )?;
    let pass2 = poc07_full_scan_pass_v3(
        stream, &mut crypto, auctioneer_guid, auction_house, page_start, page_count, 2
    )?;

    let ids1 = pass1.iter().map(|(_, r)| r.auction_id).collect::<HashSet<_>>();
    let ids2 = pass2.iter().map(|(_, r)| r.auction_id).collect::<HashSet<_>>();
    let intersection = ids1.intersection(&ids2).count();
    let only1 = ids1.difference(&ids2).count();
    let only2 = ids2.difference(&ids1).count();

    // Union by exact auction_id. Pass 2 wins for the stored page because it is fresher.
    let mut union = std::collections::HashMap::<u32, (u32, Poc06AuctionRecord)>::new();
    for (page, record) in pass1.into_iter() {
        union.insert(record.auction_id, (page, record));
    }
    for (page, record) in pass2.into_iter() {
        union.insert(record.auction_id, (page, record));
    }
    let mut scanned = union.into_values().collect::<Vec<_>>();
    scanned.sort_by_key(|(page, record)| (*page, record.auction_id));

    println!(
        "[POC07-AUDIT] COVERAGE pass1_unique={} pass2_unique={} intersection={} only_pass1={} only_pass2={} union_unique={} drift_total={}",
        ids1.len(), ids2.len(), intersection, only1, only2, scanned.len(), only1 + only2
    );

    let mut scope_ok = 0usize;
    let mut no_buyout = 0usize;
    let mut over_max = 0usize;
    let mut zero_count = 0usize;
    let mut blacklisted = 0usize;
    let mut scope_item_ids = HashSet::<u32>::new();
    for (_, record) in scanned.iter() {
        if record.buyout == 0 { no_buyout += 1; continue; }
        if record.buyout > max_buyout { over_max += 1; continue; }
        if record.count == 0 { zero_count += 1; continue; }
        if blacklist.contains(&record.item_id) { blacklisted += 1; continue; }
        scope_ok += 1;
        scope_item_ids.insert(record.item_id);
    }
    println!(
        "[POC07-AUDIT] SCOPE union_records={} within_buy_scope={} unique_items_in_scope={} no_buyout={} over_max_buyout={} zero_count={} blacklisted={} max_buyout={}",
        scanned.len(), scope_ok, scope_item_ids.len(), no_buyout, over_max, zero_count, blacklisted, max_buyout
    );'''

if old_scan not in src:
    raise SystemExit('V3 scan block marker not found')
src = src.replace(old_scan, new_scan, 1)

# Split zero vendor price from missing item-template responses for auditability.
src = src.replace(
    '    let mut zero_or_missing = 0usize;\n',
    '    let mut zero_vendor = 0usize;\n    let mut missing_template = 0usize;\n    let mut zero_vendor_ids = Vec::<u32>::new();\n    let mut missing_template_ids = Vec::<u32>::new();\n',
    1,
)
old_match = r'''                    Some(_) | None => {
                        vendor_values.remove(&item_id);
                        zero_or_missing += 1;
                    }'''
new_match = r'''                    Some(_) => {
                        vendor_values.remove(&item_id);
                        zero_vendor += 1;
                        zero_vendor_ids.push(item_id);
                    }
                    None => {
                        vendor_values.remove(&item_id);
                        missing_template += 1;
                        missing_template_ids.push(item_id);
                    }'''
if old_match not in src:
    raise SystemExit('V3 vendor zero/missing match marker not found')
src = src.replace(old_match, new_match, 1)

old_summary = r'''    println!(
        "[POC07-VENDOR-TURBO] ITEM-QUERY PASS queried={} sellable={} zero_or_missing={} elapsed_s={:.3} qps={:.1} window={} rx_packets={}",
        done, sellable, zero_or_missing, elapsed, done as f64 / elapsed, window, rx_packets
    );'''
new_summary = r'''    println!(
        "[POC07-VENDOR-TURBO] ITEM-QUERY PASS queried={} sellable={} zero_vendor={} missing_template={} elapsed_s={:.3} qps={:.1} window={} rx_packets={}",
        done, sellable, zero_vendor, missing_template, elapsed, done as f64 / elapsed, window, rx_packets
    );
    println!(
        "[POC07-AUDIT] VALUATION coverage={} sellable={} zero_vendor={} missing_template={} accounting_ok={}",
        done, sellable, zero_vendor, missing_template, done == sellable + zero_vendor + missing_template
    );
    for item_id in zero_vendor_ids.iter().copied() {
        let name = item_names.get(&item_id).map(String::as_str).unwrap_or("<unknown>");
        println!("[POC07-AUDIT-ZERO-VENDOR] item_id={} name={:?}", item_id, name);
    }
    for item_id in missing_template_ids.iter().copied() {
        println!("[POC07-AUDIT-MISSING-TEMPLATE] item_id={}", item_id);
    }'''
if old_summary not in src:
    raise SystemExit('V3 vendor summary marker not found')
src = src.replace(old_summary, new_summary, 1)

src = src.replace('[POC07-MULTIBUY-V2] START', '[POC07-MULTIBUY-V3] START', 1)
src = src.replace('[POC07-MULTIBUY-V2] PASS qualified=', '[POC07-MULTIBUY-V3] PASS qualified=', 1)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
