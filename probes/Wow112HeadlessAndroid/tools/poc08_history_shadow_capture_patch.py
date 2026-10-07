from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: WORLD_POC07_RS")

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = "\nfn poc07_request_auction_page(\n"
if s.count(marker) != 1:
    raise SystemExit(f"history helper anchor: expected 1 got {s.count(marker)}")

helper = r'''

fn poc08_history_json_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r")
}

fn poc08_history_scope_for_label(label: &str) -> &'static str {
    if label.contains("unified-full-ah") {
        "full_market"
    } else if label.contains("fresh-precheck")
        || label.contains("neighborhood")
        || label.contains("post-buy-reconcile")
        || label.contains("revalid") {
        "revalidation_window"
    } else {
        "targeted_item"
    }
}

fn poc08_history_shadow_capture_page(
    label: &str,
    page: u32,
    payload: &[u8],
    records: &[Poc06AuctionRecord],
) {
    let path = match env::var("WOW112_AH_HISTORY_SHADOW_NDJSON") {
        Ok(v) if !v.trim().is_empty() => v,
        _ => return,
    };
    let observed_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let total_offset = 4usize.saturating_add(records.len().saturating_mul(AUCTION_RECORD_SIZE));
    let total = if payload.len() >= total_offset.saturating_add(4) {
        u32::from_le_bytes([
            payload[total_offset], payload[total_offset + 1], payload[total_offset + 2], payload[total_offset + 3]
        ])
    } else {
        0
    };
    let session = env::var("WOW112_AH_HISTORY_SESSION")
        .unwrap_or_else(|_| format!("pid-{}", std::process::id()));
    let market = env::var("WOW112_AH_HISTORY_MARKET_ID")
        .unwrap_or_else(|_| "live-test:unverified".to_string());
    let server = env::var("WOW112_AH_HISTORY_SERVER_ID")
        .unwrap_or_else(|_| "unverified-server".to_string());
    let realm = env::var("WOW112_AH_HISTORY_REALM_ID")
        .unwrap_or_else(|_| "unverified-realm".to_string());
    let pool = env::var("WOW112_AH_HISTORY_AH_POOL_ID")
        .unwrap_or_else(|_| "unverified-pool".to_string());
    let epoch = env::var("WOW112_AH_HISTORY_MARKET_EPOCH")
        .unwrap_or_else(|_| "unverified-epoch".to_string());
    let scope = poc08_history_scope_for_label(label);
    let mut line = format!(
        "{{\"schema_version\":1,\"event_type\":\"RawAhPageObserved\",\"session_id\":\"{}\",\"capture_scope\":\"{}\",\"label\":\"{}\",\"market_id\":\"{}\",\"server_id\":\"{}\",\"realm_id\":\"{}\",\"ah_pool_id\":\"{}\",\"market_epoch\":\"{}\",\"observed_at_utc_ms\":{},\"page\":{},\"listfrom\":{},\"total\":{},\"record_count\":{},\"owner_identity\":\"omitted_v1\",\"storage_contract\":\"best_effort_no_mutation_coupling\",\"records\":[",
        poc08_history_json_escape(&session), scope, poc08_history_json_escape(label),
        poc08_history_json_escape(&market), poc08_history_json_escape(&server),
        poc08_history_json_escape(&realm), poc08_history_json_escape(&pool),
        poc08_history_json_escape(&epoch), observed_ms, page, page.saturating_mul(50), total, records.len()
    );
    for (index, r) in records.iter().enumerate() {
        if index != 0 { line.push(','); }
        line.push_str(&format!(
            "{{\"record_index\":{},\"auction_id\":{},\"item_id\":{},\"count\":{},\"buyout_total_copper\":{},\"owner_token\":null,\"start_bid_copper\":{},\"current_bid_copper\":{},\"min_increment_copper\":0,\"time_left_raw\":{}}}",
            index, r.auction_id, r.item_id, r.count, r.buyout, r.start_bid, r.highest_bid, r.time_left_ms
        ));
    }
    line.push_str("]}\n");
    let write_result = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
        std::io::Write::write_all(&mut file, line.as_bytes())?;
        std::io::Write::flush(&mut file)
    })();
    match write_result {
        Ok(()) => println!("[AH-HISTORY-SHADOW] CAPTURE PASS scope={} label={} page={} records={} total={} mutation_coupling=NONE", scope, label, page, records.len(), total),
        Err(error) => println!("[AH-HISTORY-SHADOW] STORAGE WARN scope={} label={} page={} error={} scan_continues=YES buy_retry_signal=NO", scope, label, page, error),
    }
}
'''

s = s.replace(marker, helper + marker, 1)

old = '''        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            let records = poc06_parse_auction_list_result(&payload)?;
            println!(
'''
new = '''        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            let records = poc06_parse_auction_list_result(&payload)?;
            poc08_history_shadow_capture_page(label, page, &payload, &records);
            println!(
'''
if s.count(old) != 1:
    raise SystemExit(f"history capture call anchor: expected 1 got {s.count(old)}")
s = s.replace(old, new, 1)

for required in [
    "WOW112_AH_HISTORY_SHADOW_NDJSON",
    "RawAhPageObserved",
    "full_market",
    "targeted_item",
    "revalidation_window",
    "best_effort_no_mutation_coupling",
    "buy_retry_signal=NO",
    "poc08_history_shadow_capture_page(label, page, &payload, &records);",
]:
    if required not in s:
        raise SystemExit("missing history marker " + required)

p.write_text(s, encoding="utf-8")
print("[POC08-HISTORY-SHADOW-CAPTURE-PATCH] PASS")
