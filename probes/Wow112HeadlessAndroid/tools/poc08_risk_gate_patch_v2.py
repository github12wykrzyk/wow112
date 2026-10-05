from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_risk_gate_patch_v2.py INPUT_POC08C OUTPUT_POC08D')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = '#[derive(Debug, Clone, Copy, PartialEq, Eq)]\nenum Poc08Exit {'
idx = src.index(marker)
helpers = r'''
#[derive(Debug, Clone, Copy)]
struct Poc08DeRiskMetrics {
    safe_ev: u32,
    safe_profit: i64,
    safe_roi_bps: i64,
    loss_probability_bps: u32,
}

fn poc08_de_risk_metrics(
    outcomes: &[Poc07DeOutcome],
    safe_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
    buyout: u32,
) -> Poc08DeRiskMetrics {
    let safe_ev = poc08_safe_ev_from_outcomes(outcomes, safe_prices, net_bps);
    let safe_profit = i64::from(safe_ev) - i64::from(buyout);
    let safe_roi_bps = if buyout == 0 { i64::MAX } else { safe_profit.saturating_mul(10_000) / i64::from(buyout) };
    let mut loss_bps: u64 = 0;
    let mut explicit_bps: u64 = 0;
    for outcome in outcomes {
        explicit_bps = explicit_bps.saturating_add(u64::from(outcome.probability_bps));
        let unit = safe_prices.get(&outcome.material_id).copied().unwrap_or(0);
        let qty_floor = (outcome.avg_qty_x100 / 100).max(1);
        let gross = u64::from(unit).saturating_mul(u64::from(qty_floor));
        let net = gross.saturating_mul(u64::from(net_bps)) / 10_000;
        if net < u64::from(buyout) {
            loss_bps = loss_bps.saturating_add(u64::from(outcome.probability_bps));
        }
    }
    if explicit_bps < 10_000 { loss_bps = loss_bps.saturating_add(10_000 - explicit_bps); }
    Poc08DeRiskMetrics {
        safe_ev,
        safe_profit,
        safe_roi_bps,
        loss_probability_bps: loss_bps.min(10_000) as u32,
    }
}

fn poc08_env_i64_default(name: &str, default: i64) -> Result<i64, String> {
    match env::var(name) {
        Ok(v) => v.parse::<i64>().map_err(|e| format!("{name} invalid integer {v:?}: {e}")),
        Err(_) => Ok(default),
    }
}

'''
src = src[:idx] + helpers + src[idx:]

src = src.replace('    safe_de_ev: u32,\n    de_profit: i64,\n', '    safe_de_ev: u32,\n    de_profit: i64,\n    de_safe_roi_bps: i64,\n    de_loss_probability_bps: u32,\n    de_risk_gate_pass: bool,\n', 1)
src = src.replace('    min_profit: i64,\n) -> (Vec<Poc08Candidate>, Vec<Poc08Rejected>) {', '    min_profit: i64,\n    min_de_profit: i64,\n    min_de_roi_bps: i64,\n    max_de_loss_bps: u32,\n) -> (Vec<Poc08Candidate>, Vec<Poc08Rejected>) {', 1)
old = '''        let de_gross = u64::from(safe_de_ev).saturating_mul(u64::from(record.count));\n        let de_profit = poc08_profit(de_gross, record.buyout);'''
new = '''        let risk = match exact_de.and_then(poc08_reference_de_outcomes) {\n            Some(outcomes) if record.count == 1 => poc08_de_risk_metrics(&outcomes, safe_mat_prices, net_bps, record.buyout),\n            _ => Poc08DeRiskMetrics {\n                safe_ev: safe_de_ev,\n                safe_profit: i64::from(safe_de_ev) - i64::from(record.buyout),\n                safe_roi_bps: if record.buyout == 0 { i64::MAX } else { (i64::from(safe_de_ev) - i64::from(record.buyout)).saturating_mul(10_000) / i64::from(record.buyout) },\n                loss_probability_bps: 10_000,\n            },\n        };\n        let de_gross = u64::from(safe_de_ev).saturating_mul(u64::from(record.count));\n        let de_profit = poc08_profit(de_gross, record.buyout);\n        let de_risk_gate_pass = record.count == 1\n            && de_profit >= min_de_profit\n            && risk.safe_roi_bps >= min_de_roi_bps\n            && risk.loss_probability_bps <= max_de_loss_bps;'''
if old not in src: raise SystemExit('POC08-D decision marker not found')
src = src.replace(old, new, 1)
src = src.replace('        let de_ok = safe_de_ev > 0 && de_profit >= min_profit;', '        let de_ok = safe_de_ev > 0 && de_profit >= min_profit && de_risk_gate_pass;', 1)
src = src.replace('                safe_de_ev,\n                de_profit,', '                safe_de_ev,\n                de_profit,\n                de_safe_roi_bps: risk.safe_roi_bps,\n                de_loss_probability_bps: risk.loss_probability_bps,\n                de_risk_gate_pass,', 1)

src = src.replace('reference_de_ev,safe_de_ev,de_profit,chosen_exit,chosen_profit,de_model_confidence', 'reference_de_ev,safe_de_ev,de_profit,de_safe_roi_bps,de_loss_probability_bps,de_risk_gate_pass,chosen_exit,chosen_profit,de_model_confidence', 1)
src = src.replace('            c.safe_de_ev,\n            c.de_profit,\n            c.chosen_exit.as_str(),', '            c.safe_de_ev,\n            c.de_profit,\n            c.de_safe_roi_bps,\n            c.de_loss_probability_bps,\n            c.de_risk_gate_pass,\n            c.chosen_exit.as_str(),', 1)
src = src.replace('reference_ev={} safe_ev={} de_profit={} chosen_profit={} page={}",', 'reference_ev={} safe_ev={} de_profit={} roi_bps={} ploss_bps={} risk_gate={} chosen_profit={} page={}",', 1)
src = src.replace('            c.reference_de_ev,\n            c.safe_de_ev,\n            c.de_profit,\n            c.chosen_profit,', '            c.reference_de_ev,\n            c.safe_de_ev,\n            c.de_profit,\n            c.de_safe_roi_bps,\n            c.de_loss_probability_bps,\n            c.de_risk_gate_pass,\n            c.chosen_profit,', 1)

needle = '    let (mut candidates, rejected) = poc08_build_candidates('
if needle not in src: raise SystemExit('POC08-D candidate call marker missing')
insert = '''    let min_de_profit = poc08_env_i64_default("WOW112_DE_MIN_SAFE_PROFIT", 2000)?;\n    let min_de_roi_bps = poc08_env_i64_default("WOW112_DE_MIN_SAFE_ROI_BPS", 2000)?;\n    let max_de_loss_bps = poc07_env_u32_default("WOW112_DE_MAX_LOSS_BPS", 4000)?;\n    if min_de_profit < 0 || min_de_roi_bps < 0 || max_de_loss_bps > 10_000 {\n        return Err(format!("invalid DE risk gates profit={} roi_bps={} max_loss_bps={}", min_de_profit, min_de_roi_bps, max_de_loss_bps));\n    }\n    println!("[POC08-D-RISK] gates min_safe_profit={} min_safe_roi_bps={} max_loss_bps={} mutation=DISABLED", min_de_profit, min_de_roi_bps, max_de_loss_bps);\n\n'''
src = src.replace(needle, insert + needle, 1)
src = src.replace('        min_profit,\n    );', '        min_profit,\n        min_de_profit,\n        min_de_roi_bps,\n        max_de_loss_bps,\n    );', 1)
summary_marker = '    if candidates.is_empty() {'
idx2 = src.index(summary_marker)
risk_summary = r'''
    let de_risk_pass = candidates.iter().filter(|c| c.de_risk_gate_pass).count();
    let de_route = candidates.iter().filter(|c| matches!(c.chosen_exit, Poc08Exit::Disenchant)).count();
    println!(
        "[POC08-D-RISK] SUMMARY candidates={} risk_gate_pass={} chosen_de={} thresholds_profit={} thresholds_roi_bps={} thresholds_max_loss_bps={} status=AUDIT_ONLY",
        candidates.len(), de_risk_pass, de_route, min_de_profit, min_de_roi_bps, max_de_loss_bps
    );

'''
src = src[:idx2] + risk_summary + src[idx2:]
src = src.replace('[POC08-C] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=REFERENCE_CLASSIC_COMPARE material_pricing=SAFE_DEPTH_HISTORY mutation=DISABLED', '[POC08-D] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=REFERENCE_CLASSIC_COMPARE material_pricing=SAFE_DEPTH_HISTORY risk_gate=PLOSS_ROI_PROFIT mutation=DISABLED', 1)
Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-D-PATCH] PASS risk-gate audit generated')
