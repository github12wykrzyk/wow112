from pathlib import Path
import re
import sys

if len(sys.argv) != 4:
    raise SystemExit('usage: MAIN_RS WORLD_POC07_RS WORLD_POC07_DELIVE_V2_RS')

main_path, poc07_path, v2_path = map(Path, sys.argv[1:])
main = main_path.read_text(encoding='utf-8')
poc07 = poc07_path.read_text(encoding='utf-8')
v2 = v2_path.read_text(encoding='utf-8')


def require_once(text, needle, label):
    n = text.count(needle)
    if n != 1:
        raise SystemExit(f'{label}: expected 1 got {n}')


# Main: history gets realm identity from the already authenticated session; no second login.
if 'mod ah_history_observer;' not in main:
    require_once(main, 'mod auth;\n', 'main module anchor')
    main = main.replace('mod auth;\n', 'mod ah_history_observer;\nmod auth;\n', 1)
if 'mod ah_history_observer_tests;' not in main:
    require_once(main, 'mod ah_history_observer;\n', 'history observer test module anchor')
    main = main.replace(
        'mod ah_history_observer;\n',
        'mod ah_history_observer;\n#[cfg(test)]\nmod ah_history_observer_tests;\n',
        1,
    )
if 'ah_history_observer::configure_realm(' not in main:
    anchor = '    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());\n'
    require_once(main, anchor, 'main realm anchor')
    main = main.replace(
        anchor,
        '    ah_history_observer::configure_realm(auth_addr, realm.realm_id, &realm.name);\n' + anchor,
        1,
    )

# Shared converter is deliberately owner-token free for V1 integration. Seller identity is
# not allowed to become stable accidentally; market identity is handled separately.
if 'fn poc08_history_records(' not in poc07:
    marker = 'fn poc07_request_auction_page(\n'
    require_once(poc07, marker, 'poc07 request marker')
    helper = r'''fn poc08_history_records(records: &[Poc06AuctionRecord]) -> Vec<crate::ah_history_observer::HistoryAuction> {
    records.iter().map(|record| crate::ah_history_observer::HistoryAuction {
        auction_id: record.auction_id,
        item_id: record.item_id,
        count: record.count,
        buyout_total_copper: record.buyout,
        start_bid_copper: record.start_bid,
        current_bid_copper: record.highest_bid,
        min_increment_copper: record.minimum_bid,
        time_left_raw: record.time_left_ms,
    }).collect()
}

'''
    poc07 = poc07.replace(marker, helper + marker, 1)

# Observe the raw server page BEFORE the unified scanner deduplicates auction IDs.
if 'observe_full_page_best_effort' not in poc07:
    pattern = re.compile(
        r'''(?ms)(\s*if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE \{\n)'''
        r'''(\s*)let records = poc06_parse_auction_list_result\(&payload\)\?;\n'''
        r'''(\s*)println!\(\n'''
        r'''(.*?)'''
        r'''(\s*)return Ok\(records\);\n'''
        r'''(\s*\})'''
    )
    match = pattern.search(poc07)
    if not match:
        raise SystemExit('poc07 list-result semantic block missing')
    indent = match.group(2)
    replacement = match.group(1) + indent + '''let count = read_u32_at(&payload, 0)? as usize;
''' + indent + '''let total_offset = 4usize
''' + indent + '''    .checked_add(count.checked_mul(AUCTION_RECORD_SIZE).ok_or_else(|| "history auction count overflow".to_string())?)
''' + indent + '''    .ok_or_else(|| "history auction total offset overflow".to_string())?;
''' + indent + '''if payload.len() < total_offset + 4 { return Err(format!("history list result truncated need={} actual={}", total_offset + 4, payload.len())); }
''' + indent + '''let total = read_u32_at(&payload, total_offset)?;
''' + indent + '''let records = poc06_parse_auction_list_result(&payload)?;
''' + indent + '''let history_records = poc08_history_records(&records);
''' + indent + '''if label == "poc08-unified-full-ah" {
''' + indent + '''    crate::ah_history_observer::observe_full_page_best_effort(auction_house, page, total, &history_records);
''' + indent + '''} else if label.contains("fresh-precheck") || label.contains("target-window") || label.contains("revalid") {
''' + indent + '''    crate::ah_history_observer::observe_revalidation_page_best_effort(auction_house, page, total, &history_records, label);
''' + indent + '''}
''' + match.group(3) + 'println!(\n' + match.group(4) + match.group(5) + 'return Ok(records);\n' + match.group(6)
    poc07 = poc07[:match.start()] + replacement + poc07[match.end():]

# Targeted material queries are a distinct canonical scope and use the same world socket.
if 'observe_targeted_page_best_effort' not in v2:
    anchor = '            let (records, total) = poc07_de_parse_auction_list_with_total(&payload)?;\n'
    require_once(v2, anchor, 'named query response anchor')
    v2 = v2.replace(
        anchor,
        anchor
        + '            let history_records = poc08_history_records(&records);\n'
        + '            crate::ah_history_observer::observe_targeted_page_best_effort(auction_house, material_id, page, total, &history_records);\n',
        1,
    )

for label, text, markers in [
    ('main', main, ['mod ah_history_observer;', 'mod ah_history_observer_tests;', 'configure_realm(auth_addr']),
    ('poc07', poc07, ['fn poc08_history_records(', 'observe_full_page_best_effort', 'observe_revalidation_page_best_effort']),
    ('v2', v2, ['observe_targeted_page_best_effort']),
]:
    for marker in markers:
        if marker not in text:
            raise SystemExit(f'{label}: missing marker {marker}')

main_path.write_text(main, encoding='utf-8')
poc07_path.write_text(poc07, encoding='utf-8')
v2_path.write_text(v2, encoding='utf-8')
print('[AH-HISTORY-SAME-SESSION-PATCH] PASS full=YES targeted=YES revalidation=YES second_login=NO offline_writer_test=YES')