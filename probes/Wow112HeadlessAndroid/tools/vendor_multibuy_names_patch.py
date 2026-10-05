from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: vendor_multibuy_names_patch.py INPUT_FULLSWEEP OUTPUT_MULTIBUY')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

marker = 'pub fn login_poc07_vendorlive_fullsweep('
idx = src.index(marker)
helpers = r'''
fn poc07_parse_item_name_live(payload: &[u8], expected_item_id: u32) -> Result<Option<String>, String> {
    if payload.len() < 13 {
        return Err(format!("item name response too short item={expected_item_id} len={}", payload.len()));
    }
    let raw_entry = read_u32_at(payload, 0)?;
    if raw_entry & 0x8000_0000 != 0 {
        let missing = raw_entry & 0x7fff_ffff;
        if missing == expected_item_id { return Ok(None); }
        return Err(format!("item name not-found mismatch expected={expected_item_id} got={missing}"));
    }
    if raw_entry != expected_item_id {
        return Err(format!("item name response mismatch expected={expected_item_id} got={raw_entry}"));
    }
    let start = 12usize;
    let end_rel = payload[start..]
        .iter()
        .position(|b| *b == 0)
        .ok_or_else(|| format!("item name unterminated item={expected_item_id}"))?;
    let end = start + end_rel;
    Ok(Some(String::from_utf8_lossy(&payload[start..end]).into_owned()))
}

fn poc07_parse_mode_multibuy() -> Result<Poc07Mode, String> {
    let raw = std::env::var("WOW112_AUTOBUY_ACTION").unwrap_or_else(|_| "scan-only".to_string());
    match raw.trim().to_ascii_lowercase().as_str() {
        "" | "scan" | "scan-only" | "readonly" | "read-only" | "0" => Ok(Poc07Mode::ScanOnly),
        "buy" | "buy-one" | "buy-all" | "all-profitable" | "1" => {
            if std::env::var("WOW112_AUTOBUY_CONFIRM").unwrap_or_default() != "YES" {
                return Err("POC07 multibuy blocked: set WOW112_AUTOBUY_CONFIRM=YES explicitly".to_string());
            }
            Ok(Poc07Mode::BuyOne)
        }
        _ => Err(format!("unsupported WOW112_AUTOBUY_ACTION={raw:?}")),
    }
}

fn poc07_buy_exact_multi_one(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    mailbox_guid: u64,
    candidate: Poc07Candidate,
    item_name: &str,
    purchase_index: usize,
    mutation_committed: &mut bool,
) -> Result<bool, String> {
    // Baseline mailbox BEFORE final AH revalidation, so any post-send mail is provably new.
    let before_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;
    let fresh_records = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-multibuy-fresh-precheck",
    )?;
    let action = Poc06AhAction::GuardedBuy {
        auction_id: candidate.record.auction_id,
        item_id: candidate.record.item_id,
        count: candidate.record.count,
        expected_buyout: candidate.record.buyout,
        max_price: candidate.record.buyout,
    };
    let target = match poc06_validate_target(action, &fresh_records) {
        Ok(target) => target,
        Err(error) => {
            println!(
                "[POC07-MULTIBUY] SKIP_STALE index={} page={} auction_id={} item_id={} name={:?} reason={}",
                purchase_index,
                candidate.page,
                candidate.record.auction_id,
                candidate.record.item_id,
                item_name,
                error
            );
            return Ok(false);
        }
    };

    println!(
        "[POC07-MULTIBUY] SELECTED index={} page={} strategy={} auction_id={} item_id={} name={:?} count={} buyout={} ({}) vendor_unit={} gross={} expected_profit={}",
        purchase_index,
        candidate.page,
        candidate.strategy.as_str(),
        target.auction_id,
        target.item_id,
        item_name,
        target.count,
        target.buyout,
        poc06_format_money(target.buyout),
        candidate.unit_value,
        candidate.gross_value,
        candidate.expected_profit
    );

    let mut request = Vec::with_capacity(16);
    request.extend_from_slice(&auctioneer_guid.to_le_bytes());
    request.extend_from_slice(&target.auction_id.to_le_bytes());
    request.extend_from_slice(&target.buyout.to_le_bytes());
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        POC06_CMSG_AUCTION_PLACE_BID_OPCODE,
        &request,
    )
    .map_err(|error| format!("AH_MUTATION_UNCERTAIN auction_id={} during-send: {error}", target.auction_id))?;
    println!(
        "[POC07-MULTIBUY] SENT index={} auction_id={} price={} NO_AUTO_RETRY_FROM_THIS_POINT=YES",
        purchase_index, target.auction_id, target.buyout
    );

    let mut server_confirmed = false;
    for rx_index in 0..256usize {
        let (server_opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())
            .map_err(|error| format!("AH_MUTATION_UNCERTAIN auction_id={} after-send: {error}", target.auction_id))?;
        if server_opcode == POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE {
            if payload.len() < 12 {
                return Err(format!("AH_MUTATION_UNCERTAIN auction_id={}: command result too short {}", target.auction_id, payload.len()));
            }
            let response_auction_id = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            let response_action = u32::from_le_bytes(payload[4..8].try_into().unwrap());
            let response_error = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            if response_auction_id != target.auction_id { continue; }
            if response_action != POC06_AUCTION_ACTION_BID {
                return Err(format!("AH_MUTATION_UNCERTAIN auction_id={}: unexpected action={response_action}", target.auction_id));
            }
            if response_error != 0 {
                return Err(format!("AH_MUTATION_CONFIRMED_FAILURE auction_id={} server_error={response_error}", target.auction_id));
            }
            *mutation_committed = true;
            server_confirmed = true;
            println!("[POC07-MULTIBUY] SERVER PASS index={} auction_id={} action={} result=0", purchase_index, target.auction_id, response_action);
            break;
        }
        if rx_index < 8 {
            println!("[POC07-MULTIBUY-DIAG] wait index={} rx[{}] opcode=0x{:04X} payload={}", purchase_index, rx_index, server_opcode, payload.len());
        }
    }
    if !server_confirmed {
        return Err(format!("AH_MUTATION_UNCERTAIN auction_id={}: no command result within 256 packets", target.auction_id));
    }

    let after_auctions = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-multibuy-post-reconcile",
    )
    .map_err(|error| format!("AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: AH snapshot failed: {error}", target.auction_id))?;
    let after_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)
        .map_err(|error| format!("AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: mailbox snapshot failed: {error}", target.auction_id))?;
    poc06_reconcile_buy(target, &after_auctions, &before_mail, &after_mail)?;
    println!(
        "[POC07-MULTIBUY] BUY PASS index={} auction_id={} item_id={} name={:?} profit={} ({})",
        purchase_index,
        target.auction_id,
        target.item_id,
        item_name,
        candidate.expected_profit,
        poc06_format_money(candidate.expected_profit.max(0) as u32)
    );
    Ok(true)
}

'''
out = src[:idx] + helpers + src[idx:]
out = out.replace('pub fn login_poc07_vendorlive_fullsweep(', 'pub fn login_poc07_vendorlive_multibuy(', 1)
out = out.replace('let mode = poc07_parse_mode()?;', 'let mode = poc07_parse_mode_multibuy()?;', 1)

old_vendor_decl = '    let mut vendor_values = poc07_parse_value_map("WOW112_VENDOR_VALUES")?;\n'
new_vendor_decl = '    let mut vendor_values = poc07_parse_value_map("WOW112_VENDOR_VALUES")?;\n    let mut item_names = std::collections::HashMap::<u32, String>::new();\n    let max_purchases = poc07_env_u32_default("WOW112_AUTOBUY_MAX_PURCHASES", 0)?; // 0 = all qualified\n'
if old_vendor_decl not in out:
    raise SystemExit('multibuy vendor declaration marker not found')
out = out.replace(old_vendor_decl, new_vendor_decl, 1)

# Extend turbo valuation to capture live item names as well as SellPrice.
old_sig = '''    vendor_values: &mut std::collections::HashMap<u32, u32>,\n    window: usize,\n) -> Result<(), String> {'''
new_sig = '''    vendor_values: &mut std::collections::HashMap<u32, u32>,\n    item_names: &mut std::collections::HashMap<u32, String>,\n    window: usize,\n) -> Result<(), String> {'''
if old_sig not in out:
    raise SystemExit('multibuy turbo signature marker not found')
out = out.replace(old_sig, new_sig, 1)

old_dedup = '''    item_ids.sort_unstable();\n    item_ids.dedup();'''
new_dedup = '''    item_ids.sort_unstable();\n    item_ids.dedup();\n    // Always resolve the previously purchased test item so its authoritative live name is printed.\n    if item_ids.binary_search(&50748).is_err() {\n        item_ids.push(50748);\n        item_ids.sort_unstable();\n    }'''
out = out.replace(old_dedup, new_dedup, 1)

old_pending = '''            if pending.remove(&item_id) {\n                match poc07_parse_item_sell_price(&payload, item_id)? {'''
new_pending = '''            if pending.remove(&item_id) {\n                if let Some(name) = poc07_parse_item_name_live(&payload, item_id)? {\n                    if item_id == 50748 {\n                        println!("[POC07-VENDOR-NAME] item_id=50748 name={:?}", name);\n                    }\n                    item_names.insert(item_id, name);\n                }\n                match poc07_parse_item_sell_price(&payload, item_id)? {'''
if old_pending not in out:
    raise SystemExit('multibuy pending marker not found')
out = out.replace(old_pending, new_pending, 1)

old_call_tail = '''            &blacklist,\n            &mut vendor_values,\n            vendor_item_query_window,\n        )?;'''
new_call_tail = '''            &blacklist,\n            &mut vendor_values,\n            &mut item_names,\n            vendor_item_query_window,\n        )?;'''
if old_call_tail not in out:
    raise SystemExit('multibuy turbo call marker not found')
out = out.replace(old_call_tail, new_call_tail, 1)

old_mode_text = 'blacklist={} hard_max_purchases=1"'
new_mode_text = 'blacklist={} purchase_limit={} (0=ALL_QUALIFIED)"'
if old_mode_text not in out:
    raise SystemExit('multibuy mode text marker not found')
out = out.replace(old_mode_text, new_mode_text, 1)
old_mode_args = '''        de_values.len(),\n        blacklist.len()\n    );'''
new_mode_args = '''        de_values.len(),\n        blacklist.len(),\n        max_purchases\n    );'''
if old_mode_args not in out:
    raise SystemExit('multibuy mode args marker not found')
out = out.replace(old_mode_args, new_mode_args, 1)

old_candidate_tail = '''    poc07_print_candidates(&candidates);\n\n    match mode {\n        Poc07Mode::ScanOnly => {\n            println!("[POC07-LIVE] REAL VENDOR SCAN-ONLY PASS no_mutation=YES");\n        }\n        Poc07Mode::BuyOne => {\n            let candidate = candidates\n                .first()\n                .copied()\n                .ok_or_else(|| "POC07_NO_QUALIFIED_CANDIDATE no purchase sent".to_string())?;\n            poc07_buy_exact_one(\n                stream,\n                &mut crypto,\n                auctioneer_guid,\n                auction_house,\n                mailbox_guid,\n                candidate,\n                ah_mutation_committed,\n            )?;\n        }\n    }'''
new_candidate_tail = '''    poc07_print_candidates(&candidates);\n    for (rank, candidate) in candidates.iter().take(50).enumerate() {\n        let name = item_names.get(&candidate.record.item_id).map(String::as_str).unwrap_or("<unknown>");\n        println!(\n            "[POC07-CANDIDATE-NAME] rank={} page={} auction_id={} item_id={} name={:?} buyout={} vendor_unit={} gross={} profit={}",\n            rank, candidate.page, candidate.record.auction_id, candidate.record.item_id, name, candidate.record.buyout, candidate.unit_value, candidate.gross_value, candidate.expected_profit\n        );\n    }\n\n    match mode {\n        Poc07Mode::ScanOnly => {\n            println!("[POC07-LIVE] REAL VENDOR SCAN-ONLY PASS no_mutation=YES");\n        }\n        Poc07Mode::BuyOne => {\n            if candidates.is_empty() {\n                return Err("POC07_NO_QUALIFIED_CANDIDATE no purchase sent".to_string());\n            }\n            // Buy from highest page downward. Removing a later auction cannot shift earlier pages,\n            // which keeps each candidate's original page stable for exact fresh revalidation.\n            let mut purchase_order = candidates.clone();\n            purchase_order.sort_by(|a, b| {\n                b.page.cmp(&a.page)\n                    .then_with(|| b.record.auction_id.cmp(&a.record.auction_id))\n            });\n            let limit = if max_purchases == 0 { purchase_order.len() } else { purchase_order.len().min(max_purchases as usize) };\n            println!("[POC07-MULTIBUY] START qualified={} purchase_limit={} order=PAGE_DESC min_profit={}", candidates.len(), limit, min_profit);\n            let mut bought = 0usize;\n            let mut stale_skipped = 0usize;\n            for (index, candidate) in purchase_order.into_iter().take(limit).enumerate() {\n                let name_owned = item_names.get(&candidate.record.item_id).cloned().unwrap_or_else(|| "<unknown>".to_string());\n                match poc07_buy_exact_multi_one(\n                    stream,\n                    &mut crypto,\n                    auctioneer_guid,\n                    auction_house,\n                    mailbox_guid,\n                    candidate,\n                    &name_owned,\n                    index + 1,\n                    ah_mutation_committed,\n                )? {\n                    true => bought += 1,\n                    false => stale_skipped += 1,\n                }\n            }\n            println!("[POC07-MULTIBUY] PASS qualified={} attempted={} bought={} stale_skipped={} min_profit={}", candidates.len(), limit, bought, stale_skipped, min_profit);\n        }\n    }'''
if old_candidate_tail not in out:
    raise SystemExit('multibuy candidate/mode marker not found')
out = out.replace(old_candidate_tail, new_candidate_tail, 1)

Path(sys.argv[2]).write_text(out, encoding='utf-8')
