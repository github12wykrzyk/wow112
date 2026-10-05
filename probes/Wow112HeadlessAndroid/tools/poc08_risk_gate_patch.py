from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_risk_gate_patch.py INPUT_POC08C OUTPUT_POC08D')

src = Path(sys.argv[1]).read_text(encoding='utf-8')


def replace_once(label: str, old: str, new: str) -> None:
    global src
    count = src.count(old)
    if count != 1:
        raise SystemExit(f'POC08-D {label} marker count expected=1 actual={count}')
    src = src.replace(old, new, 1)


marker = '#[derive(Debug, Clone, Copy, PartialEq, Eq)]\nenum Poc08Exit {'
idx = src.index(marker)

helpers = r'''
#[derive(Debug, Clone, Copy)]
struct Poc08DiscreteDeOutcome {
    material_id: u32,
    probability_bps: u32,
    min_count: u32,
    max_count: u32,
}

fn poc08_discrete_de_outcomes(disenchant_id: u32) -> Option<Vec<Poc08DiscreteDeOutcome>> {
    let o = |material_id: u32, probability_bps: u32, min_count: u32, max_count: u32| {
        Poc08DiscreteDeOutcome { material_id, probability_bps, min_count, max_count }
    };
    Some(match disenchant_id {
        1 => vec![o(10938, 2000, 1, 2), o(10940, 8000, 1, 2)],
        2 => vec![o(10939, 2000, 1, 2), o(10940, 7500, 2, 3), o(10978, 500, 1, 1)],
        3 => vec![o(10940, 7500, 4, 6), o(10998, 1500, 1, 2), o(10978, 1000, 1, 1)],
        4 => vec![o(11082, 2000, 1, 2), o(11083, 7500, 1, 2), o(11084, 500, 1, 1)],
        5 => vec![o(11083, 7500, 2, 5), o(11134, 2000, 1, 2), o(11138, 500, 1, 1)],
        6 => vec![o(11135, 2000, 1, 2), o(11137, 7500, 1, 2), o(11139, 500, 1, 1)],
        7 => vec![o(11137, 7500, 2, 5), o(11174, 2000, 1, 2), o(11177, 500, 1, 1)],
        8 => vec![o(11175, 2000, 1, 2), o(11176, 7500, 1, 2), o(11178, 500, 1, 1)],
        9 => vec![o(11176, 7500, 2, 5), o(16202, 2000, 1, 2), o(14343, 500, 1, 1)],
        10 => vec![o(16203, 2000, 1, 2), o(16204, 7500, 1, 2), o(14344, 500, 1, 1)],
        11 => vec![o(16203, 2000, 2, 3), o(16204, 7500, 2, 5), o(14344, 500, 1, 1)],
        21 => vec![o(10938, 8000, 1, 2), o(10940, 2000, 1, 2)],
        22 => vec![o(10939, 7500, 1, 2), o(10940, 2000, 2, 3), o(10978, 500, 1, 1)],
        23 => vec![o(10998, 7500, 1, 2), o(10940, 1500, 4, 6), o(10978, 1000, 1, 1)],
        24 => vec![o(11082, 7500, 1, 2), o(11083, 2000, 1, 2), o(11084, 500, 1, 1)],
        25 => vec![o(11134, 7500, 1, 2), o(11083, 2000, 2, 5), o(11138, 500, 1, 1)],
        26 => vec![o(11135, 7500, 1, 2), o(11137, 2000, 1, 2), o(11139, 500, 1, 1)],
        27 => vec![o(11174, 7500, 1, 2), o(11137, 2000, 2, 5), o(11177, 500, 1, 1)],
        28 => vec![o(11175, 7500, 1, 2), o(11176, 2000, 1, 2), o(11178, 500, 1, 1)],
        29 => vec![o(16202, 7500, 1, 2), o(11176, 2200, 2, 5), o(14343, 300, 1, 1)],
        30 => vec![o(16203, 7500, 1, 2), o(16204, 2200, 1, 2), o(14344, 300, 1, 1)],
        31 => vec![o(16203, 7500, 2, 3), o(16204, 2200, 2, 5), o(14344, 300, 1, 1)],
        41 => vec![o(10978, 10_000, 1, 1)],
        42 => vec![o(11084, 10_000, 1, 1)],
        43 => vec![o(11138, 10_000, 1, 1)],
        44 => vec![o(11139, 10_000, 1, 1)],
        45 => vec![o(11177, 10_000, 1, 1)],
        46 => vec![o(11178, 10_000, 1, 1)],
        47 => vec![o(14343, 10_000, 1, 1)],
        48 | 49 => vec![o(14344, 9950, 1, 1), o(20725, 50, 1, 1)],
        61 => vec![o(11177, 10_000, 2, 4)],
        62 => vec![o(11178, 10_000, 2, 4)],
        63 => vec![o(14343, 10_000, 2, 4)],
        64 => vec![o(20725, 10_000, 1, 1)],
        _ => return None,
    })
}

fn poc08_de_loss_probability_bps(
    disenchant_id: u32,
    safe_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
    buyout: u32,
) -> Option<u32> {
    let outcomes = poc08_discrete_de_outcomes(disenchant_id)?;
    let mut total_probability = 0u64;
    let mut loss_probability = 0u64;
    for outcome in outcomes {
        if outcome.max_count < outcome.min_count || outcome.min_count == 0 { return None; }
        total_probability = total_probability.saturating_add(u64::from(outcome.probability_bps));
        let span = u64::from(outcome.max_count - outcome.min_count + 1);
        let price = u64::from(safe_prices.get(&outcome.material_id).copied().unwrap_or(0));
        let mut losing = 0u64;
        for count in outcome.min_count..=outcome.max_count {
            let gross = price.saturating_mul(u64::from(count));
            let net = gross.saturating_mul(u64::from(net_bps)) / 10_000;
            if net < u64::from(buyout) { losing = losing.saturating_add(1); }
        }
        let weighted = (u64::from(outcome.probability_bps)
            .saturating_mul(losing).saturating_add(span - 1)) / span;
        loss_probability = loss_probability.saturating_add(weighted);
    }
    if total_probability < 9_900 || total_probability > 10_100 { return None; }
    Some(loss_probability.min(10_000) as u32)
}

fn poc08_roi_bps(value: u64, cost: u32) -> u32 {
    if cost == 0 || value <= u64::from(cost) { return 0; }
    let profit = value - u64::from(cost);
    let bps = profit.saturating_mul(10_000) / u64::from(cost);
    bps.min(u64::from(u32::MAX)) as u32
}

'''
src = src[:idx] + helpers + src[idx:]

needle = '    let max_buyout = poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?;\n'
if needle not in src: raise SystemExit('POC08-D max-buyout marker not found')
insert = needle + r'''    let min_de_safe_profit = poc07_env_u32_default("WOW112_DE_MIN_SAFE_PROFIT", 2_000)?;
    let min_de_safe_roi_bps = poc07_env_u32_default("WOW112_DE_MIN_SAFE_ROI_BPS", 2_000)?;
    let max_de_ploss_bps = poc07_env_u32_default("WOW112_DE_MAX_PLOSS_BPS", 4_000)?;
    if min_de_safe_roi_bps > 100_000 { return Err("WOW112_DE_MIN_SAFE_ROI_BPS too large".to_string()); }
    if max_de_ploss_bps > 10_000 { return Err("WOW112_DE_MAX_PLOSS_BPS must be <=10000".to_string()); }
    println!("[POC08-D-RISK] gates min_safe_profit={} ({}) min_safe_roi_bps={} max_ploss_bps={} mutation=DISABLED", min_de_safe_profit, poc06_format_money(min_de_safe_profit), min_de_safe_roi_bps, max_de_ploss_bps);
'''
src = src.replace(needle, insert, 1)

replace_once('candidate risk fields', '    safe_de_ev: u32,\n    de_profit: i64,\n', '    safe_de_ev: u32,\n    de_profit: i64,\n    de_roi_bps: u32,\n    de_ploss_bps: u32,\n    de_risk_pass: bool,\n')
replace_once('decision signature', '    safe_de_values: &std::collections::HashMap<u32, u32>,\n    max_buyout: u32,', '    safe_de_values: &std::collections::HashMap<u32, u32>,\n    safe_mat_prices: &std::collections::HashMap<u32, u32>,\n    net_bps: u32,\n    min_de_safe_profit: u32,\n    min_de_safe_roi_bps: u32,\n    max_de_ploss_bps: u32,\n    max_buyout: u32,')
replace_once('risk metric insertion', '        let de_profit = poc08_profit(de_gross, record.buyout);\n', '''        let de_profit = poc08_profit(de_gross, record.buyout);\n        let de_roi_bps = poc08_roi_bps(de_gross, record.buyout);\n        let de_ploss_bps = if record.count == 1 {\n            exact_de.and_then(|id| if id > 0 { poc08_de_loss_probability_bps(id, safe_mat_prices, net_bps, record.buyout) } else { None }).unwrap_or(10_000)\n        } else { 10_000 };\n        let de_risk_pass = safe_de_ev > 0\n            && record.count == 1\n            && de_profit >= i64::from(min_de_safe_profit)\n            && de_roi_bps >= min_de_safe_roi_bps\n            && de_ploss_bps <= max_de_ploss_bps;\n''')
replace_once('DE gate replacement', '        let de_ok = safe_de_ev > 0 && de_profit >= min_profit;\n', '        let de_ok = de_risk_pass;\n')
replace_once('candidate risk values', '                safe_de_ev,\n                de_profit,', '                safe_de_ev,\n                de_profit,\n                de_roi_bps,\n                de_ploss_bps,\n                de_risk_pass,')
replace_once('decision call risk inputs', '        &safe_de_values,\n        max_buyout,', '        &safe_de_values,\n        &safe_mat_prices,\n        net_bps,\n        min_de_safe_profit,\n        min_de_safe_roi_bps,\n        max_de_ploss_bps,\n        max_buyout,')

old_reason = '''            let reason = if exact_de.is_none() && vendor_unit == 0 {
                "DE_ID_UNKNOWN_AND_NO_VENDOR"
            } else if exact_de == Some(0) && vendor_unit == 0 {
                "DE_ID_ZERO_AND_NO_VENDOR"
            } else if matches!(exact_de, Some(id) if id > 0) && reference_de_ev == 0 && vendor_unit == 0 {
                "DE_MODEL_OR_MATERIAL_PRICE_UNAVAILABLE"
            } else {
                "NO_EXIT_MEETS_MIN_PROFIT"
            };'''
new_reason = '''            let reason = if exact_de.is_none() && vendor_unit == 0 {
                "DE_ID_UNKNOWN_AND_NO_VENDOR"
            } else if exact_de == Some(0) && vendor_unit == 0 {
                "DE_ID_ZERO_AND_NO_VENDOR"
            } else if matches!(exact_de, Some(id) if id > 0) && reference_de_ev == 0 && vendor_unit == 0 {
                "DE_MODEL_OR_MATERIAL_PRICE_UNAVAILABLE"
            } else if matches!(exact_de, Some(id) if id > 0) && record.count != 1 {
                "DE_STACK_UNSUPPORTED"
            } else if matches!(exact_de, Some(id) if id > 0) && safe_de_ev == 0 {
                "DE_SAFE_EV_UNAVAILABLE"
            } else if matches!(exact_de, Some(id) if id > 0) && de_profit < i64::from(min_de_safe_profit) {
                "DE_SAFE_PROFIT_BELOW_GATE"
            } else if matches!(exact_de, Some(id) if id > 0) && de_roi_bps < min_de_safe_roi_bps {
                "DE_SAFE_ROI_BELOW_GATE"
            } else if matches!(exact_de, Some(id) if id > 0) && de_ploss_bps > max_de_ploss_bps {
                "DE_PLOSS_ABOVE_GATE"
            } else {
                "NO_EXIT_MEETS_MIN_PROFIT"
            };'''
replace_once('risk rejection reasons', old_reason, new_reason)

replace_once('candidate csv header', 'safe_de_ev,de_profit,chosen_exit', 'safe_de_ev,de_profit,de_roi_bps,de_ploss_bps,de_risk_pass,chosen_exit')
replace_once('candidate csv values', '            c.safe_de_ev,\n            c.de_profit,\n            c.chosen_exit', '            c.safe_de_ev,\n            c.de_profit,\n            c.de_roi_bps,\n            c.de_ploss_bps,\n            c.de_risk_pass,\n            c.chosen_exit')
replace_once('candidate csv formatter slots', '"{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",', '"{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",')
replace_once('console risk header', 'safe_ev={} de_profit={} chosen_profit={} page={}",', 'safe_ev={} de_profit={} de_roi_bps={} de_ploss_bps={} de_risk_pass={} chosen_profit={} page={}",')
replace_once('console risk values', '            c.safe_de_ev,\n            c.de_profit,\n            c.chosen_profit,', '            c.safe_de_ev,\n            c.de_profit,\n            c.de_roi_bps,\n            c.de_ploss_bps,\n            c.de_risk_pass,\n            c.chosen_profit,')

engine_marker = 'println!("[POC08-C] ENGINE PASS mode=RiskPricebookAudit mutation=DISABLED zero_candidates_is_pass=YES");'
if src.count(engine_marker) != 1:
    raise SystemExit(f'POC08-D engine marker count expected=1 actual={src.count(engine_marker)}')
summary = r'''let de_candidates = economy_candidates.iter().filter(|c| matches!(c.chosen_exit, Poc08Exit::Disenchant)).count();
    let risk_passed = economy_candidates.iter().filter(|c| c.de_risk_pass).count();
    println!("[POC08-D-RISK] SUMMARY candidates={} de_chosen={} de_risk_passed={} thresholds=profit:{} roi_bps:{} ploss_bps:{}", economy_candidates.len(), de_candidates, risk_passed, min_de_safe_profit, min_de_safe_roi_bps, max_de_ploss_bps);
    println!("[POC08-D] ENGINE PASS mode=DiscreteRiskGateAudit mutation=DISABLED zero_candidates_is_pass=YES");'''
src = src.replace(engine_marker, summary, 1)

src = src.replace('[POC08-C] COMBINED AUDIT', '[POC08-D] COMBINED AUDIT', 1)
src = src.replace('[POC08-C] NO_CANDIDATE_PASS', '[POC08-D] NO_CANDIDATE_PASS', 1)
src = src.replace('[POC08-C] CANDIDATE AUDIT PASS', '[POC08-D] CANDIDATE AUDIT PASS', 1)
src = src.replace('[POC08-C] REAL COMBINED SCAN-ONLY PASS', '[POC08-D] REAL COMBINED RISK SCAN-ONLY PASS', 1)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-D-PATCH] PASS discrete P(loss)+ROI+safe-profit risk gate generated')
