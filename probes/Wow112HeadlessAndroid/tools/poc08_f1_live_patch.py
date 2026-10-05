from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_f1_live_patch.py INPUT_F0 OUTPUT_F1')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

def rep(label: str, old: str, new: str) -> None:
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit(f'POC08-F1 {label} expected=1 actual={n}')
    src = src.replace(old, new, 1)

rep(
    'mutation latch parameter',
    '    _ah_mutation_committed: &mut bool,\n) -> Result<(), String> {',
    '    ah_mutation_committed: &mut bool,\n) -> Result<(), String> {',
)

rep(
    'mailbox guid live reuse',
    '    let (auctioneer_candidates, _mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;',
    '    let (auctioneer_candidates, mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;',
)

marker = 'pub fn login_poc08_economy_audit(\n'
idx = src.index(marker)
helpers = r'''
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Poc08F1Action {
    Audit,
    VendorSmoke,
    DeWhitelist,
}

fn poc08_f1_action() -> Result<Poc08F1Action, String> {
    let raw = env::var("WOW112_F1_ACTION").unwrap_or_else(|_| "audit".to_string());
    match raw.trim().to_ascii_lowercase().as_str() {
        "" | "audit" | "scan" | "read-only" | "readonly" => Ok(Poc08F1Action::Audit),
        "vendor" | "vendor-smoke" => Ok(Poc08F1Action::VendorSmoke),
        "de" | "de-whitelist" => Ok(Poc08F1Action::DeWhitelist),
        _ => Err(format!("unsupported WOW112_F1_ACTION={raw:?}")),
    }
}

fn poc08_f1_live_confirm() -> Result<(), String> {
    if env::var("WOW112_F1_LIVE_CONFIRM").unwrap_or_default() != "BUY_ONE_NOW" {
        return Err("POC08-F1 live blocked: WOW112_F1_LIVE_CONFIRM must equal BUY_ONE_NOW".to_string());
    }
    if env::var("WOW112_AUTOBUY_CONFIRM").unwrap_or_default() != "YES" {
        return Err("POC08-F1 live blocked: WOW112_AUTOBUY_CONFIRM must equal YES".to_string());
    }
    let max_purchases = poc07_env_u32_default("WOW112_AUTOBUY_MAX_PURCHASES", 1)?;
    if max_purchases != 1 {
        return Err(format!("POC08-F1 hard guard requires WOW112_AUTOBUY_MAX_PURCHASES=1, got {max_purchases}"));
    }
    Ok(())
}

fn poc08_f1_item_whitelist() -> Result<std::collections::HashSet<u32>, String> {
    let raw = env::var("WOW112_F1_DE_WHITELIST").unwrap_or_default();
    let mut out = std::collections::HashSet::new();
    for token in raw.split(|c| c == ',' || c == ';' || c == ' ') {
        let token = token.trim();
        if token.is_empty() { continue; }
        let item_id = token.parse::<u32>()
            .map_err(|e| format!("invalid WOW112_F1_DE_WHITELIST item={token:?}: {e}"))?;
        if item_id != 0 { out.insert(item_id); }
    }
    Ok(out)
}

fn poc08_f1_as_poc07(c: &Poc08EconomyCandidate) -> Poc07Candidate {
    let (strategy, unit_value, expected_profit) = match c.chosen_exit {
        Poc08Exit::Vendor => (Poc07Strategy::Vendor, c.vendor_unit, c.vendor_profit),
        Poc08Exit::Disenchant => (Poc07Strategy::Disenchant, c.safe_de_ev, c.de_profit),
    };
    Poc07Candidate {
        page: c.page,
        record: c.record,
        strategy,
        unit_value,
        gross_value: u64::from(unit_value).saturating_mul(u64::from(c.record.count)),
        expected_profit,
    }
}
'''
src = src[:idx] + helpers + src[idx:]

old = '''    println!("[POC08-F0] ENGINE PASS mode=BUY_ELIGIBILITY_AUDIT mutation=DISABLED zero_candidates_is_pass=YES distribution_octowow_verified=NO");
    Ok(())
'''
new = r'''    println!("[POC08-F0] ENGINE PASS mode=BUY_ELIGIBILITY_AUDIT mutation=DISABLED zero_candidates_is_pass=YES distribution_octowow_verified=NO");

    let f1_action = poc08_f1_action()?;
    if matches!(f1_action, Poc08F1Action::Audit) {
        println!("[POC08-F1] AUDIT PASS action=AUDIT mutation=DISABLED hard_max_purchases=1");
        return Ok(());
    }

    poc08_f1_live_confirm()?;
    let f1_hard_max_buyout = poc07_env_u32_default("WOW112_F1_HARD_MAX_SINGLE_BUYOUT", 10_000)?;
    let f1_min_vendor_profit = i64::from(poc07_env_u32_default("WOW112_F1_MIN_VENDOR_PROFIT", 1)?);
    let f1_de_max_disagreement_bps = poc07_env_u32_default("WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS", 0)?;

    let selected = match f1_action {
        Poc08F1Action::Audit => unreachable!(),
        Poc08F1Action::VendorSmoke => {
            let mut v = economy_candidates.iter().filter(|c| {
                matches!(c.chosen_exit, Poc08Exit::Vendor)
                    && c.record.count == 1
                    && c.record.buyout > 0
                    && c.record.buyout <= f1_hard_max_buyout
                    && c.vendor_unit > 0
                    && c.vendor_profit >= f1_min_vendor_profit
            }).collect::<Vec<_>>();
            v.sort_by(|a,b| b.vendor_profit.cmp(&a.vendor_profit)
                .then_with(|| a.record.buyout.cmp(&b.record.buyout))
                .then_with(|| a.record.auction_id.cmp(&b.record.auction_id)));
            let c = *v.first().ok_or_else(|| "POC08_F1_NO_VENDOR_SMOKE_CANDIDATE no purchase sent".to_string())?;
            println!("[POC08-F1] SELECT action=VENDOR_SMOKE auction_id={} item_id={} count={} buyout={} vendor_unit={} vendor_profit={} hard_max_buyout={} hard_max_purchases=1", c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,c.vendor_unit,c.vendor_profit,f1_hard_max_buyout);
            c
        }
        Poc08F1Action::DeWhitelist => {
            let whitelist = poc08_f1_item_whitelist()?;
            if whitelist.is_empty() {
                return Err("POC08-F1 DE live blocked: WOW112_F1_DE_WHITELIST is empty".to_string());
            }
            let mut d = f0.iter().copied().filter(|c| {
                whitelist.contains(&c.record.item_id)
                    && c.record.count == 1
                    && c.record.buyout > 0
                    && c.record.buyout <= f1_hard_max_buyout
                    && c.de_risk_pass
                    && c.safe_de_ev > 0
                    && poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) <= f1_de_max_disagreement_bps
            }).collect::<Vec<_>>();
            d.sort_by(|a,b| b.de_profit.cmp(&a.de_profit)
                .then_with(|| a.record.buyout.cmp(&b.record.buyout))
                .then_with(|| a.record.auction_id.cmp(&b.record.auction_id)));
            let c = *d.first().ok_or_else(|| "POC08_F1_NO_WHITELISTED_DE_CANDIDATE no purchase sent".to_string())?;
            println!("[POC08-F1] SELECT action=DE_WHITELIST auction_id={} item_id={} count={} buyout={} safe_ev={} de_profit={} roi_bps={} ploss_bps={} agreement_bps={} source={} whitelist_size={} hard_max_buyout={} hard_max_purchases=1", c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),whitelist.len(),f1_hard_max_buyout);
            c
        }
    };

    let buy_candidate = poc08_f1_as_poc07(selected);
    println!("[POC08-F1] PRE-BUY guard=fresh-page+exact-auction-id+exact-item-id+exact-count+exact-buyout no_auto_retry_after_send=YES");
    poc07_buy_exact_one(
        stream,
        &mut crypto,
        auctioneer_guid,
        auction_house,
        mailbox_guid,
        buy_candidate,
        ah_mutation_committed,
    )?;
    println!("[POC08-F1] LIVE BUY-ONE PASS purchases=1 action={:?}", f1_action);
    Ok(())
'''
rep('F0 engine tail', old, new)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-F1-PATCH] PASS guarded live buy-one generated')
