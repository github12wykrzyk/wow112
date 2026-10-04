from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc07_de_v3_patch.py INPUT_V2 OUTPUT_V3')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'pub fn login_poc07_delive_v2('
idx = src.index(marker)
helpers = r'''
fn poc07_de_build_class_query_v3(
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

fn poc07_de_request_class_page_v3(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    item_class: u32,
    min_quality: u32,
    page: u32,
) -> Result<(Vec<Poc06AuctionRecord>, u32), String> {
    let list_from = page.checked_mul(50).ok_or_else(|| format!("AH filtered page overflow page={page}"))?;
    let query = poc07_de_build_class_query_v3(auctioneer_guid, list_from, item_class, min_quality);
    println!("[POC07-DE-FILTER] query class={item_class} min_quality={min_quality} page={page} listfrom={list_from} house={auction_house}");
    write_encrypted_raw(stream, crypto.encrypter(), CMSG_AUCTION_LIST_ITEMS_OPCODE, &query)?;
    let mut discovered = HashSet::new();
    for index in 0..256usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            let (records, total) = poc07_de_parse_auction_list_with_total(&payload)?;
            println!("[POC07-DE-FILTER] snapshot PASS class={item_class} min_quality={min_quality} page={page} records={} total={total}", records.len());
            return Ok((records, total));
        }
        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 4 {
            println!("[POC07-DE-FILTER-DIAG] wait class={item_class} page={page} rx[{index}] opcode=0x{opcode:04X} payload={}", payload.len());
        }
    }
    Err(format!("SMSG_AUCTION_LIST_RESULT not received for filtered class={item_class} page={page}"))
}

fn poc07_de_scan_class_full_v3(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    item_class: u32,
    min_quality: u32,
    max_pages: u32,
) -> Result<Vec<(u32, Poc06AuctionRecord)>, String> {
    let mut out = Vec::new();
    let mut page = 0u32;
    loop {
        if page >= max_pages {
            return Err(format!("DE filtered scan fail-closed: class={item_class} exceeded max_pages={max_pages}"));
        }
        let (records, total) = poc07_de_request_class_page_v3(stream, crypto, auctioneer_guid, auction_house, item_class, min_quality, page)?;
        let count = records.len() as u32;
        let diagnostic_page = item_class.saturating_mul(10_000).saturating_add(page);
        out.extend(records.into_iter().map(|record| (diagnostic_page, record)));
        let list_from = page.saturating_mul(50);
        if total == 0 || count == 0 || list_from.saturating_add(count) >= total {
            println!("[POC07-DE-FILTER] CLASS PASS class={item_class} pages={} records={} total={total}", page + 1, out.len());
            break;
        }
        page = page.saturating_add(1);
    }
    Ok(out)
}

'''
out = src[:idx] + helpers + src[idx:]
out = out.replace('pub fn login_poc07_delive_v2(', 'pub fn login_poc07_delive_v3(', 1)
out = out.replace('POC07-DE-LIVE-V2 is hard read-only; BUY is disabled in this build', 'POC07-DE-LIVE-V3 is hard read-only; BUY is disabled in this build', 1)
old_cfg = '''    let blacklist = poc07_parse_blacklist()?;\n    let page_start = poc07_env_u32_default("WOW112_AH_SCAN_PAGE_START", 12)?;\n    let page_count = poc07_env_u32_default("WOW112_AH_SCAN_PAGES", 64)?;\n    if page_count == 0 || page_count > 128 {\n        return Err(format!("WOW112_AH_SCAN_PAGES must be 1..128 for DE live scan, got {page_count}"));\n    }\n    let max_buyout = poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?;'''
new_cfg = '''    let blacklist = poc07_parse_blacklist()?;\n    let filter_max_pages = poc07_env_u32_default("WOW112_DE_FILTER_MAX_PAGES", 128)?;\n    if filter_max_pages == 0 || filter_max_pages > 256 {\n        return Err(format!("WOW112_DE_FILTER_MAX_PAGES must be 1..256, got {filter_max_pages}"));\n    }\n    let max_buyout = poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?;'''
assert old_cfg in out
out = out.replace(old_cfg, new_cfg, 1)
old_print = '''        "[POC07-DE-V2] mode=ScanOnly page_start={page_start} pages={page_count} max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} scope=quality2-3_ilvl31-65 blacklist={} mutation=DISABLED",\n        blacklist.len()'''
new_print = '''        "[POC07-DE-V3] mode=ScanOnly source=server-filtered class=weapon+armor min_quality=2 filter_max_pages={filter_max_pages} max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} scope=quality2-3_ilvl31-65 blacklist={} mutation=DISABLED",\n        blacklist.len()'''
assert old_print in out
out = out.replace(old_print, new_print, 1)
old_scan = '''    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();\n    for offset in 0..page_count {\n        let page = page_start\n            .checked_add(offset)\n            .ok_or_else(|| "AH scan page overflow".to_string())?;\n        let records = poc07_request_auction_page(\n            stream,\n            &mut crypto,\n            auctioneer_guid,\n            auction_house,\n            page,\n            "poc07-de-v2-scan",\n        )?;\n        scanned.extend(records.into_iter().map(|record| (page, record)));\n    }\n    println!("[POC07-DE-V2] AH SCAN PASS records={}", scanned.len());'''
new_scan = '''    let mut scanned: Vec<(u32, Poc06AuctionRecord)> = Vec::new();\n    let weapons = poc07_de_scan_class_full_v3(stream, &mut crypto, auctioneer_guid, auction_house, 2, 2, filter_max_pages)?;\n    let armor = poc07_de_scan_class_full_v3(stream, &mut crypto, auctioneer_guid, auction_house, 4, 2, filter_max_pages)?;\n    scanned.extend(weapons);\n    scanned.extend(armor);\n    println!("[POC07-DE-V3] FILTERED AH SCAN PASS records={}", scanned.len());'''
assert old_scan in out
out = out.replace(old_scan, new_scan, 1)
for old, new in [
    ('[POC07-DE-V2] item template classification start', '[POC07-DE-V3] item template classification start'),
    ('[POC07-DE-V2] TEMPLATE PASS', '[POC07-DE-V3] TEMPLATE PASS'),
    ('[POC07-DE-V2] VALUATION PASS', '[POC07-DE-V3] VALUATION PASS'),
    ('[POC07-DE-V2] REAL DE SCAN-ONLY PASS', '[POC07-DE-V3] REAL DE SCAN-ONLY PASS'),
    ('[POC07-DE-V2] AUTOBUY ENGINE PASS', '[POC07-DE-V3] AUTOBUY ENGINE PASS'),
]:
    out = out.replace(old, new)
Path(sys.argv[2]).write_text(out, encoding='utf-8')
