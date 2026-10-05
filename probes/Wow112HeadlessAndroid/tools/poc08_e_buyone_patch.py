from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_e_buyone_patch.py INPUT_POC08D OUTPUT_POC08E')

src = Path(sys.argv[1]).read_text(encoding='utf-8')


def replace_once(label: str, old: str, new: str) -> None:
    global src
    count = src.count(old)
    if count != 1:
        raise SystemExit(f'POC08-E {label} marker count expected=1 actual={count}')
    src = src.replace(old, new, 1)


helper_anchor = 'pub fn login_poc08_economy_audit(\n'
if src.count(helper_anchor) != 1:
    raise SystemExit('POC08-E login anchor missing/ambiguous')

helpers = r'''
#[derive(Debug, Clone)]
struct Poc08EPendingTx {
    target: Poc06AuctionRecord,
    before_mail_ids: Vec<u32>,
}

static POC08_E_PENDING_TX: std::sync::Mutex<Option<Poc08EPendingTx>> = std::sync::Mutex::new(None);

fn poc08_e_journal_path() -> String {
    env::var("WOW112_POC08_E_JOURNAL").unwrap_or_else(|_| "POC08_E_TX_JOURNAL.log".to_string())
}

fn poc08_e_journal_append(status_kv: &str, target: Poc06AuctionRecord) -> Result<(), String> {
    use std::io::Write as _;
    if !matches!(status_kv, "status=PREPARED" | "status=COMMITTED" | "status=ABORTED_SAFE") {
        return Err(format!("POC08-E invalid journal state {status_kv:?}"));
    }
    let path = poc08_e_journal_path();
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| format!("POC08-E journal open failed path={path:?}: {e}"))?;
    writeln!(
        file,
        "{} auction_id={} item_id={} count={} buyout={}",
        status_kv, target.auction_id, target.item_id, target.count, target.buyout
    )
    .map_err(|e| format!("POC08-E journal write failed path={path:?}: {e}"))?;
    file.flush().map_err(|e| format!("POC08-E journal flush failed path={path:?}: {e}"))?;
    Ok(())
}

fn poc08_e_journal_guard_clean() -> Result<(), String> {
    let path = poc08_e_journal_path();
    let Ok(text) = std::fs::read_to_string(&path) else { return Ok(()); };
    let last = text.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("");
    if last.is_empty() || last.starts_with("status=COMMITTED ") || last.starts_with("status=ABORTED_SAFE ") {
        return Ok(());
    }
    Err(format!(
        "POC08_E_DIRTY_JOURNAL_BLOCK mutation refused path={path:?} last={last:?}; reconcile manually before another BUY"
    ))
}

fn poc08_e_pending_snapshot() -> Result<Option<Poc08EPendingTx>, String> {
    POC08_E_PENDING_TX
        .lock()
        .map_err(|_| "POC08-E pending mutex poisoned".to_string())
        .map(|guard| guard.clone())
}

fn poc08_e_pending_set(value: Option<Poc08EPendingTx>) -> Result<(), String> {
    let mut guard = POC08_E_PENDING_TX
        .lock()
        .map_err(|_| "POC08-E pending mutex poisoned".to_string())?;
    *guard = value;
    Ok(())
}

fn poc08_e_exact_new_mail(
    before_ids: &[u32],
    after_mail: &[Poc05MailRecord],
    target: Poc06AuctionRecord,
) -> Option<(u32, u32)> {
    after_mail
        .iter()
        .find(|mail| {
            !before_ids.contains(&mail.id)
                && mail.item == target.item_id
                && mail.stack == target.count
        })
        .map(|mail| (mail.id, mail.stack))
}

fn poc08_e_reconcile_pending_mail(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    mailbox_guid: u64,
    pending: &Poc08EPendingTx,
) -> Result<(), String> {
    for attempt in 1..=4u32 {
        let after_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;
        if let Some((mail_id, stack)) = poc08_e_exact_new_mail(
            &pending.before_mail_ids,
            &after_mail,
            pending.target,
        ) {
            println!(
                "[POC08-E] EXACT MAIL PASS attempt={} mail_id={} item_id={} stack={} auction_id={}",
                attempt, mail_id, pending.target.item_id, stack, pending.target.auction_id
            );
            poc08_e_journal_append("status=COMMITTED", pending.target)?;
            poc08_e_pending_set(None)?;
            return Ok(());
        }
        if attempt < 4 {
            std::thread::sleep(Duration::from_millis(400));
        }
    }
    Err(format!(
        "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: ACK known but exact NEW mail item_id={} stack={} not observed",
        pending.target.auction_id, pending.target.item_id, pending.target.count
    ))
}

fn poc08_e_revalidate_by_exact_name(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    target: Poc06AuctionRecord,
    item_name: &str,
    max_pages: u32,
) -> Result<Option<Poc06AuctionRecord>, String> {
    for page in 0..max_pages {
        let (records, total) = poc07_de_request_named_page(
            stream,
            crypto,
            auctioneer_guid,
            auction_house,
            target.item_id,
            item_name,
            page,
        )?;
        for live in records.iter().copied() {
            if live.auction_id != target.auction_id {
                continue;
            }
            if live.item_id != target.item_id
                || live.count != target.count
                || live.buyout != target.buyout
            {
                return Err(format!(
                    "AH_MUTATION_PRECHECK_BLOCKED auction_id={}: tuple changed live(item={},count={},buyout={}) expected(item={},count={},buyout={})",
                    target.auction_id,
                    live.item_id,
                    live.count,
                    live.buyout,
                    target.item_id,
                    target.count,
                    target.buyout
                ));
            }
            println!(
                "[POC08-E] TARGETED REVALIDATE PASS auction_id={} item_id={} count={} buyout={} page={} name={:?}",
                live.auction_id, live.item_id, live.count, live.buyout, page, item_name
            );
            return Ok(Some(live));
        }
        let next_from = (page + 1).saturating_mul(50);
        if next_from >= total {
            return Ok(None);
        }
    }
    Err(format!(
        "POC08-E targeted revalidation exceeded max_pages={} item_id={} auction_id={} name={:?}",
        max_pages, target.item_id, target.auction_id, item_name
    ))
}

fn poc08_e_execute_buy_one(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    mailbox_guid: u64,
    candidate: &Poc08EconomyCandidate,
    ah_mutation_committed: &mut bool,
) -> Result<(), String> {
    if !matches!(candidate.chosen_exit, Poc08Exit::Disenchant)
        || !candidate.de_risk_pass
        || candidate.disenchant_id == 0
        || candidate.record.count != 1
    {
        return Err("POC08-E internal guard refused non-DE/non-risk-passed candidate".to_string());
    }

    let max_single_buy = poc07_env_u32_default("WOW112_DE_MAX_SINGLE_BUY", 50_000)?;
    if candidate.record.buyout > max_single_buy {
        println!(
            "[POC08-E] PRICE CAP SKIP auction_id={} buyout={} max_single_buy={}",
            candidate.record.auction_id, candidate.record.buyout, max_single_buy
        );
        return Ok(());
    }

    let item_name = poc07_de_query_item_name_v4(stream, crypto, candidate.record.item_id)?
        .ok_or_else(|| format!("POC08-E item name unavailable item_id={}", candidate.record.item_id))?;

    // Baseline MUST be before final fresh AH revalidation.
    let before_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;
    let before_mail_ids = before_mail.iter().map(|mail| mail.id).collect::<Vec<_>>();

    let max_pages = poc07_env_u32_default("WOW112_DE_REVALIDATE_MAX_PAGES", 16)?;
    if max_pages == 0 || max_pages > 64 {
        return Err(format!("WOW112_DE_REVALIDATE_MAX_PAGES must be 1..64, got {max_pages}"));
    }
    let Some(fresh) = poc08_e_revalidate_by_exact_name(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.record,
        &item_name,
        max_pages,
    )? else {
        println!(
            "[POC08-E] STALE SAFE SKIP auction_id={} item_id={} no mutation sent",
            candidate.record.auction_id, candidate.record.item_id
        );
        return Ok(());
    };

    let pending = Poc08EPendingTx { target: fresh, before_mail_ids };
    poc08_e_journal_append("status=PREPARED", fresh)?;
    poc08_e_pending_set(Some(pending.clone()))?;

    let action = Poc06AhAction::GuardedBuy {
        auction_id: fresh.auction_id,
        item_id: fresh.item_id,
        count: fresh.count,
        expected_buyout: fresh.buyout,
        max_price: fresh.buyout,
    };
    let exact_snapshot = [fresh];
    poc06_perform_auction_action(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        mailbox_guid,
        action,
        &exact_snapshot,
        &before_mail,
        ah_mutation_committed,
    )?;

    // POC06 returns only after server ACK. Enforce the stronger invariant here:
    // ACK + exact NEW mail with exact purchased stack.
    poc08_e_reconcile_pending_mail(stream, crypto, mailbox_guid, &pending)?;
    println!(
        "[POC08-E] GUARDED DE BUY-ONE PASS auction_id={} item_id={} count={} buyout={} deid={} safe_ev={} profit={} roi_bps={} ploss_bps={}",
        fresh.auction_id,
        fresh.item_id,
        fresh.count,
        fresh.buyout,
        candidate.disenchant_id,
        candidate.safe_de_ev,
        candidate.de_profit,
        candidate.de_roi_bps,
        candidate.de_ploss_bps
    );
    Ok(())
}

'''
src = src.replace(helper_anchor, helpers + helper_anchor, 1)

replace_once(
    'mutation arg',
    '    _ah_mutation_committed: &mut bool,\n',
    '    ah_mutation_committed: &mut bool,\n',
)

replace_once(
    'read-only mode gate',
    '''    if !matches!(poc07_parse_mode()?, Poc07Mode::ScanOnly) {\n        return Err("POC07-DE-LIVE-V5.3 is hard read-only; BUY is disabled in this build".to_string());\n    }\n    let blacklist = poc07_parse_blacklist()?;\n''',
    '''    let e_action_raw = env::var("WOW112_POC08_E_ACTION").unwrap_or_else(|_| "scan-only".to_string());\n    let e_action = e_action_raw.trim().to_ascii_lowercase();\n    let poc08_e_buy_one = matches!(e_action.as_str(), "buy-one" | "buy" | "1");\n    if !poc08_e_buy_one && !matches!(e_action.as_str(), "" | "scan" | "scan-only" | "readonly" | "read-only" | "0") {\n        return Err(format!("unsupported WOW112_POC08_E_ACTION={e_action_raw:?}"));\n    }\n    if poc08_e_buy_one {\n        if env::var("WOW112_AH_MUTATION_CONFIRM").unwrap_or_default() != "YES"\n            || env::var("WOW112_DE_BUY_CONFIRM").unwrap_or_default() != "YES"\n        {\n            return Err("POC08-E mutation blocked: require WOW112_AH_MUTATION_CONFIRM=YES and WOW112_DE_BUY_CONFIRM=YES".to_string());\n        }\n        poc08_e_journal_guard_clean()?;\n    }\n    let blacklist = poc07_parse_blacklist()?;\n''',
)

replace_once(
    'risk banner',
    '    println!("[POC08-D-RISK] gates min_safe_profit={} ({}) min_safe_roi_bps={} max_ploss_bps={} mutation=DISABLED", min_de_safe_profit, poc06_format_money(min_de_safe_profit), min_de_safe_roi_bps, max_de_ploss_bps);\n',
    '    println!("[POC08-E-RISK] gates min_safe_profit={} ({}) min_safe_roi_bps={} max_ploss_bps={} action={} hard_max_purchases=1", min_de_safe_profit, poc06_format_money(min_de_safe_profit), min_de_safe_roi_bps, max_de_ploss_bps, if poc08_e_buy_one { "BUY_ONE" } else { "SCAN_ONLY" });\n',
)

replace_once(
    'context mailbox capture',
    '    let (auctioneer_candidates, _mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;\n',
    '    let (auctioneer_candidates, mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;\n',
)

hello_anchor = '    let (auctioneer_guid, auction_house) = poc05_send_auction_hello_candidates(stream, &mut crypto, auctioneer_candidates)?;\n\n'
replace_once(
    'pending recovery insertion',
    hello_anchor,
    hello_anchor + '''    if poc08_e_buy_one {\n        if let Some(pending) = poc08_e_pending_snapshot()? {\n            if *ah_mutation_committed {\n                println!("[POC08-E] RECOVERY exact-mail reconcile only auction_id={} item_id={} count={}", pending.target.auction_id, pending.target.item_id, pending.target.count);\n                poc08_e_reconcile_pending_mail(stream, &mut crypto, mailbox_guid, &pending)?;\n                println!("[POC08-E] RECOVERY COMMIT PASS; no new purchase attempted");\n                return Ok(());\n            }\n            return Err(format!(\n                "AH_MUTATION_UNCERTAIN_RECOVERY_REQUIRED auction_id={}: pending tx exists without confirmed ACK; no new BUY allowed",\n                pending.target.auction_id\n            ));\n        }\n    }\n\n''',
)

export_anchor = '    poc08_export_economy_audit(&economy_candidates, &rejected_rows)?;\n'
replace_once(
    'buy-one execution insertion',
    export_anchor,
    export_anchor + '''    if poc08_e_buy_one {\n        let de_candidate = economy_candidates.iter().find(|c| {\n            matches!(c.chosen_exit, Poc08Exit::Disenchant)\n                && c.de_risk_pass\n                && c.disenchant_id > 0\n                && c.record.count == 1\n                && c.record.owner_guid != player_guid\n        });\n        let Some(candidate) = de_candidate else {\n            println!("[POC08-E] NO_DE_CANDIDATE_PASS mutation=NONE status=NORMAL_NOOP");\n            println!("[POC08-E] ENGINE PASS mode=GuardedDEBuyOne no_candidate=YES mutation=NONE");\n            if soak_seconds > 0 { maintain_world_session(stream, &mut crypto, soak_seconds)?; }\n            return Ok(());\n        };\n        println!(\n            "[POC08-E] ARM BEST DE rank-derived auction_id={} item_id={} buyout={} deid={} safe_ev={} profit={} roi_bps={} ploss_bps={}",\n            candidate.record.auction_id,\n            candidate.record.item_id,\n            candidate.record.buyout,\n            candidate.disenchant_id,\n            candidate.safe_de_ev,\n            candidate.de_profit,\n            candidate.de_roi_bps,\n            candidate.de_ploss_bps\n        );\n        poc08_e_execute_buy_one(\n            stream,\n            &mut crypto,\n            auctioneer_guid,\n            auction_house,\n            mailbox_guid,\n            candidate,\n            ah_mutation_committed,\n        )?;\n        if soak_seconds > 0 { maintain_world_session(stream, &mut crypto, soak_seconds)?; }\n        println!("[POC08-E] ENGINE PASS mode=GuardedDEBuyOne mutation=MAX_ONE");\n        return Ok(());\n    }\n''',
)

src = src.replace('[POC08-D] REAL COMBINED RISK SCAN-ONLY PASS', '[POC08-E] REAL COMBINED RISK SCAN-ONLY PASS')
src = src.replace('[POC08-D] ENGINE PASS mode=DiscreteRiskGateAudit', '[POC08-E] ENGINE PASS mode=DiscreteRiskGateAudit')
src = src.replace('[POC08-D-RISK] SUMMARY', '[POC08-E-RISK] SUMMARY')

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-E-PATCH] PASS guarded_buy_one=YES targeted_revalidation=YES exact_mail=YES journal=YES')
