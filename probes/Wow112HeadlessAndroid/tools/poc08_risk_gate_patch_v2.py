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
    let safe_roi_bps = if buyout == 0 {
        i64::MAX
    } else {
        safe_profit.saturating_mul(10_000) / i64::from(buyout)
    };

    let mut loss_bps: u64 = 0;
    let mut explicit_bps: u64 = 0;
    for outcome in outcomes {
        explicit_bps = explicit_bps.saturating_add(u64::from(outcome.probability_bps));
        let unit = safe_prices.get(&outcome.material_id).copied().unwrap_or(0);
        // P(loss) intentionally uses floor(avg quantity), so this is a
        // conservative audit metric until exact min/max is retained directly.
        let qty_floor = (outcome.avg_qty_x100 / 100).max(1);
        let gross = u64::from(unit).saturating_mul(u64::from(qty_floor));
        let net = gross.saturating_mul(u64::from(net_bps)) / 10_000;
        if net < u64::from(buyout) {
            loss_bps = loss_bps.saturating_add(u64::from(outcome.probability_bps));
        }
    }
    if explicit_bps < 10_000 {
        loss_bps = loss_bps.saturating_add(10_000 - explicit_bps);
    }

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

fn poc08_export_risk_audit(
    candidates: &[Poc08EconomyCandidate],
    safe_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
    min_de_profit: i64,
    min_de_roi_bps: i64,
    max_de_loss_bps: u32,
) -> Result<(), String> {
    let path = env::var("WOW112_DE_RISK_EXPORT")
        .unwrap_or_else(|_| "POC08_D_RISK_AUDIT.csv".to_string());
    let mut csv = String::from(
        "auction_id,item_id,count,buyout,chosen_exit,disenchant_id,safe_ev,safe_profit,safe_roi_bps,loss_probability_bps,risk_gate_pass,reason\n"
    );
    let mut evaluated = 0usize;
    let mut passed = 0usize;
    let mut skipped_non_de = 0usize;
    let mut skipped_stack = 0usize;
    let mut model_missing = 0usize;

    for c in candidates {
        if c.disenchant_id == 0 {
            skipped_non_de += 1;
            continue;
        }
        if c.record.count != 1 {
            skipped_stack += 1;
            continue;
        }
        let Some(outcomes) = poc08_reference_de_outcomes(c.disenchant_id) else {
            model_missing += 1;
            continue;
        };
        evaluated += 1;
        let risk = poc08_de_risk_metrics(&outcomes, safe_prices, net_bps, c.record.buyout);
        let pass_profit = risk.safe_profit >= min_de_profit;
        let pass_roi = risk.safe_roi_bps >= min_de_roi_bps;
        let pass_loss = risk.loss_probability_bps <= max_de_loss_bps;
        let gate = pass_profit && pass_roi && pass_loss;
        if gate { passed += 1; }
        let reason = if gate {
            "PASS"
        } else if !pass_profit {
            "SAFE_PROFIT_TOO_LOW"
        } else if !pass_roi {
            "SAFE_ROI_TOO_LOW"
        } else {
            "PLOSS_TOO_HIGH"
        };
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{},{},{},{},{}\n",
            c.record.auction_id,
            c.record.item_id,
            c.record.count,
            c.record.buyout,
            c.chosen_exit.as_str(),
            c.disenchant_id,
            risk.safe_ev,
            risk.safe_profit,
            risk.safe_roi_bps,
            risk.loss_probability_bps,
            gate,
            reason,
        ));
        println!(
            "[POC08-D-RISK-ROW] auction_id={} item_id={} buyout={} deid={} safe_ev={} safe_profit={} roi_bps={} ploss_bps={} gate={} reason={}",
            c.record.auction_id, c.record.item_id, c.record.buyout, c.disenchant_id,
            risk.safe_ev, risk.safe_profit, risk.safe_roi_bps,
            risk.loss_probability_bps, gate, reason
        );
    }

    std::fs::write(&path, csv.as_bytes())
        .map_err(|e| format!("POC08-D risk export failed path={path:?}: {e}"))?;
    println!(
        "[POC08-D-RISK] SUMMARY evaluated={} passed={} skipped_non_de={} skipped_stack={} model_missing={} min_safe_profit={} min_safe_roi_bps={} max_loss_bps={} export={:?} status=AUDIT_ONLY",
        evaluated, passed, skipped_non_de, skipped_stack, model_missing,
        min_de_profit, min_de_roi_bps, max_de_loss_bps, path
    );
    Ok(())
}

'''
src = src[:idx] + helpers + src[idx:]

needle = '''    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        &scanned,
        &vendor_values,
        &de_values,
        &reference_de_values,
        &safe_de_values,
        max_buyout,
        min_profit,
        &blacklist,
    );
    poc08_export_economy_audit(&economy_candidates, &rejected_rows)?;'''
if needle not in src:
    raise SystemExit('POC08-D combined decision marker missing')
replacement = needle.replace(
    '    poc08_export_economy_audit(&economy_candidates, &rejected_rows)?;',
    '''    let min_de_profit = poc08_env_i64_default("WOW112_DE_MIN_SAFE_PROFIT", 2000)?;
    let min_de_roi_bps = poc08_env_i64_default("WOW112_DE_MIN_SAFE_ROI_BPS", 2000)?;
    let max_de_loss_bps = poc07_env_u32_default("WOW112_DE_MAX_LOSS_BPS", 4000)?;
    if min_de_profit < 0 || min_de_roi_bps < 0 || max_de_loss_bps > 10_000 {
        return Err(format!("invalid DE risk gates profit={} roi_bps={} max_loss_bps={}", min_de_profit, min_de_roi_bps, max_de_loss_bps));
    }
    println!(
        "[POC08-D-RISK] gates min_safe_profit={} min_safe_roi_bps={} max_loss_bps={} mutation=DISABLED",
        min_de_profit, min_de_roi_bps, max_de_loss_bps
    );
    poc08_export_risk_audit(
        &economy_candidates,
        &safe_mat_prices,
        net_bps,
        min_de_profit,
        min_de_roi_bps,
        max_de_loss_bps,
    )?;
    poc08_export_economy_audit(&economy_candidates, &rejected_rows)?;'''
)
src = src.replace(needle, replacement, 1)

src = src.replace(
    '[POC08-C] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=REFERENCE_CLASSIC_COMPARE mutation=DISABLED',
    '[POC08-D] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=REFERENCE_CLASSIC_COMPARE risk_overlay=PLOSS_ROI_PROFIT mutation=DISABLED',
    1,
)
src = src.replace('[POC08-C] REAL COMBINED SCAN-ONLY PASS no_mutation=YES', '[POC08-D] REAL COMBINED SCAN-ONLY PASS no_mutation=YES', 1)
src = src.replace('[POC08-C] ENGINE PASS mode=RiskPricebookAudit mutation=DISABLED zero_candidates_is_pass=YES', '[POC08-D] ENGINE PASS mode=RiskGateAudit mutation=DISABLED zero_candidates_is_pass=YES', 1)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-D-PATCH] PASS risk overlay audit generated')
