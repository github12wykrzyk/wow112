from pathlib import Path
import sys
if len(sys.argv)!=3: raise SystemExit('usage: INPUT OUTPUT')
src=Path(sys.argv[1]).read_text(encoding='utf-8')
def rep(label,a,b):
 global src
 n=src.count(a)
 if n!=1: raise SystemExit(f'{label} expected1 got{n}')
 src=src.replace(a,b,1)
rep('material confidence','    let (mat_prices, safe_mat_prices, _material_confidence) = poc08_collect_material_pricebook(\n','    let (mat_prices, safe_mat_prices, material_confidence) = poc08_collect_material_pricebook(\n')
marker='pub fn login_poc08_economy_audit(\n'
idx=src.index(marker)
helpers=r'''
fn poc08_f0_model_agreement_bps(heuristic: u32, reference: u32) -> u32 {
    if heuristic == 0 || reference == 0 { return 10_000; }
    let hi = u64::from(heuristic.max(reference));
    let lo = u64::from(heuristic.min(reference));
    (((hi - lo).saturating_mul(10_000)) / hi).min(10_000) as u32
}
fn poc08_f0_all_materials_medium(disenchant_id: u32, material_confidence: &std::collections::HashMap<u32, u8>) -> bool {
    let Some(outcomes) = poc08_reference_de_outcomes(disenchant_id) else { return false; };
    !outcomes.is_empty() && outcomes.iter().all(|o| material_confidence.get(&o.material_id).copied().unwrap_or(0) >= 2)
}
'''
src=src[:idx]+helpers+src[idx:]
needle='    let max_de_ploss_bps = poc07_env_u32_default("WOW112_DE_MAX_PLOSS_BPS", 4_000)?;\n'
insert=needle+r'''    let f0_min_safe_profit = poc07_env_u32_default("WOW112_F0_MIN_SAFE_PROFIT", 5_000)?;
    let f0_min_safe_roi_bps = poc07_env_u32_default("WOW112_F0_MIN_SAFE_ROI_BPS", 5_000)?;
    let f0_max_ploss_bps = poc07_env_u32_default("WOW112_F0_MAX_PLOSS_BPS", 2_000)?;
    let f0_max_model_disagreement_bps = poc07_env_u32_default("WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS", 2_500)?;
    let f0_min_edge_vs_vendor = poc07_env_u32_default("WOW112_F0_MIN_EDGE_VS_VENDOR", 2_000)?;
    let f0_hard_max_buyout = poc07_env_u32_default("WOW112_F0_HARD_MAX_SINGLE_BUYOUT", 50_000)?;
'''
rep('thresholds',needle,insert)
old='''    poc08_audit_candidate_provenance(&economy_candidates);
    println!("[POC08-E] ENGINE PASS mode=ProvenanceAudit mutation=DISABLED zero_candidates_is_pass=YES authoritative_deid_required_for_future_buy=YES distribution_octowow_verified=NO");
    Ok(())
'''
new=r'''    poc08_audit_candidate_provenance(&economy_candidates);
    let mut f0 = economy_candidates.iter().filter(|c| {
        if !matches!(c.chosen_exit, Poc08Exit::Disenchant) { return false; }
        if c.record.count != 1 || c.record.buyout == 0 || c.record.buyout > f0_hard_max_buyout { return false; }
        if c.disenchant_id == 0 || c.safe_de_ev == 0 { return false; }
        if c.de_profit < i64::from(f0_min_safe_profit) || c.de_roi_bps < f0_min_safe_roi_bps || c.de_ploss_bps > f0_max_ploss_bps { return false; }
        if poc08_de_source_confidence(c.record.item_id) == 0 { return false; }
        if !poc08_f0_all_materials_medium(c.disenchant_id, &material_confidence) { return false; }
        if poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) > f0_max_model_disagreement_bps { return false; }
        c.de_profit.saturating_sub(c.vendor_profit) >= i64::from(f0_min_edge_vs_vendor)
    }).collect::<Vec<_>>();
    f0.sort_by(|a,b| b.de_profit.cmp(&a.de_profit).then_with(|| a.record.buyout.cmp(&b.record.buyout)));
    let export = env::var("WOW112_F0_ELIGIBLE_EXPORT").unwrap_or_else(|_| "POC08_F0_ELIGIBLE.csv".to_string());
    let mut csv = String::from("rank,auction_id,item_id,buyout,safe_de_ev,de_profit,de_roi_bps,de_ploss_bps,heuristic_ev,reference_ev,agreement_bps,source,vendor_profit,disenchant_id\\n");
    for (rank,c) in f0.iter().enumerate() {
        csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n", rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,c.heuristic_de_ev,c.reference_de_ev,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),c.vendor_profit,c.disenchant_id));
    }
    std::fs::write(&export, csv.as_bytes()).map_err(|e| format!("POC08-F0 export failed: {e}"))?;
    println!("[POC08-F0] ELIGIBILITY PASS eligible={} thresholds=profit:{} roi_bps:{} ploss_bps:{} model_disagree_bps:{} edge_vendor:{} hard_max_buyout:{} mutation=DISABLED export={:?}", f0.len(), f0_min_safe_profit,f0_min_safe_roi_bps,f0_max_ploss_bps,f0_max_model_disagreement_bps,f0_min_edge_vs_vendor,f0_hard_max_buyout,export);
    for (rank,c) in f0.iter().take(20).enumerate() {
        println!("[POC08-F0-ELIGIBLE] rank={} auction_id={} item_id={} buyout={} safe_ev={} profit={} roi_bps={} ploss_bps={} agreement_bps={} source={} vendor_profit={} deid={}",rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),c.vendor_profit,c.disenchant_id);
    }
    println!("[POC08-F0] ENGINE PASS mode=BUY_ELIGIBILITY_AUDIT mutation=DISABLED zero_candidates_is_pass=YES distribution_octowow_verified=NO");
    Ok(())
'''
rep('tail',old,new)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
print('[POC08-F0-PATCH] PASS')
