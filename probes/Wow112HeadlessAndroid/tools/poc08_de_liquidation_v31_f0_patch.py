from pathlib import Path
import sys
if len(sys.argv)!=2:
    raise SystemExit('usage: UNIFIED_RS')
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

def rep(label, old, new):
    global s
    n=s.count(old)
    if n!=1:
        raise SystemExit(f'{label}: expected 1 got {n}')
    s=s.replace(old,new,1)

old_helpers='''fn poc08_f0_model_agreement_bps(heuristic: u32, reference: u32) -> u32 {
    if heuristic == 0 || reference == 0 { return 10_000; }
    let hi = u64::from(heuristic.max(reference));
    let lo = u64::from(heuristic.min(reference));
    (((hi - lo).saturating_mul(10_000)) / hi).min(10_000) as u32
}
fn poc08_f0_all_materials_medium(disenchant_id: u32, material_confidence: &std::collections::HashMap<u32, u8>) -> bool {
'''
new_helpers='''fn poc08_f0_model_agreement_bps(heuristic: u32, reference: u32) -> u32 {
    if heuristic == 0 || reference == 0 { return 10_000; }
    let hi = u64::from(heuristic.max(reference));
    let lo = u64::from(heuristic.min(reference));
    (((hi - lo).saturating_mul(10_000)) / hi).min(10_000) as u32
}
// V3.1: old heuristic-vs-reference disagreement is no longer a binary kill switch.
// safe_de_ev is already material-price/liquidity/exposure hardened; disagreement only
// contributes a bounded confidence haircut so the final decision remains liquidation-aware.
fn poc08_f0_model_confidence_factor_bps(heuristic: u32, reference: u32) -> u32 {
    let disagreement = poc08_f0_model_agreement_bps(heuristic, reference);
    10_000u32.saturating_sub(disagreement / 10).max(8_500)
}
fn poc08_f0_liquidation_decision(c: &Poc08EconomyCandidate) -> (u32, i64, u32, u32) {
    let factor_bps = poc08_f0_model_confidence_factor_bps(c.heuristic_de_ev, c.reference_de_ev);
    let decision_ev = ((u64::from(c.safe_de_ev) * u64::from(factor_bps)) / 10_000).min(u64::from(u32::MAX)) as u32;
    let decision_profit = i64::from(decision_ev) - i64::from(c.record.buyout);
    let decision_roi_bps = if c.record.buyout == 0 || decision_profit <= 0 { 0 } else {
        ((u64::try_from(decision_profit).unwrap_or(0).saturating_mul(10_000)) / u64::from(c.record.buyout)).min(u64::from(u32::MAX)) as u32
    };
    (decision_ev, decision_profit, decision_roi_bps, factor_bps)
}
fn poc08_f0_all_materials_medium(disenchant_id: u32, material_confidence: &std::collections::HashMap<u32, u8>) -> bool {
'''
rep('helpers', old_helpers, new_helpers)

old_thresholds='''    let f0_min_safe_profit = poc07_env_u32_default("WOW112_F0_MIN_SAFE_PROFIT", 5_000)?;
    let f0_min_safe_roi_bps = poc07_env_u32_default("WOW112_F0_MIN_SAFE_ROI_BPS", 5_000)?;
    let f0_max_ploss_bps = poc07_env_u32_default("WOW112_F0_MAX_PLOSS_BPS", 2_000)?;
    let f0_max_model_disagreement_bps = poc07_env_u32_default("WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS", 2_500)?;
    let f0_min_edge_vs_vendor = poc07_env_u32_default("WOW112_F0_MIN_EDGE_VS_VENDOR", 2_000)?;
    let f0_hard_max_buyout = poc07_env_u32_default("WOW112_F0_HARD_MAX_SINGLE_BUYOUT", 50_000)?;
'''
new_thresholds='''    // V3.1 F0 evaluates final liquidation-adjusted value rather than raw reference/heuristic agreement.
    let f0_min_safe_profit = poc07_env_u32_default("WOW112_F0_MIN_SAFE_PROFIT", 2_500)?;
    let f0_min_safe_roi_bps = poc07_env_u32_default("WOW112_F0_MIN_SAFE_ROI_BPS", 2_500)?;
    let f0_max_ploss_bps = poc07_env_u32_default("WOW112_F0_MAX_PLOSS_BPS", 2_500)?;
    let f0_min_edge_vs_vendor = poc07_env_u32_default("WOW112_F0_MIN_EDGE_VS_VENDOR", 2_000)?;
    let f0_hard_max_buyout = poc07_env_u32_default("WOW112_F0_HARD_MAX_SINGLE_BUYOUT", 50_000)?;
'''
rep('thresholds', old_thresholds, new_thresholds)

old_f0='''    let mut f0 = economy_candidates.iter().filter(|c| {
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
    let mut csv = String::from("rank,auction_id,item_id,buyout,page,safe_de_ev,de_profit,de_roi_bps,de_ploss_bps,heuristic_ev,reference_ev,agreement_bps,source,vendor_profit,disenchant_id\\n");
    for (rank,c) in f0.iter().enumerate() {
        csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n", rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.page,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,c.heuristic_de_ev,c.reference_de_ev,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),c.vendor_profit,c.disenchant_id));
    }
    std::fs::write(&export, csv.as_bytes()).map_err(|e| format!("POC08-F0 export failed: {e}"))?;
    println!("[POC08-F0] ELIGIBILITY PASS eligible={} thresholds=profit:{} roi_bps:{} ploss_bps:{} model_disagree_bps:{} edge_vendor:{} hard_max_buyout:{} mutation=DISABLED export={:?}", f0.len(), f0_min_safe_profit,f0_min_safe_roi_bps,f0_max_ploss_bps,f0_max_model_disagreement_bps,f0_min_edge_vs_vendor,f0_hard_max_buyout,export);
    for (rank,c) in f0.iter().take(20).enumerate() {
        println!("[POC08-F0-ELIGIBLE] rank={} auction_id={} item_id={} buyout={} safe_ev={} profit={} roi_bps={} ploss_bps={} agreement_bps={} source={} vendor_profit={} deid={}",rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),c.vendor_profit,c.disenchant_id);
    }
'''
new_f0='''    let mut f0 = economy_candidates.iter().filter(|c| {
        if !matches!(c.chosen_exit, Poc08Exit::Disenchant) || !c.de_risk_pass { return false; }
        if c.record.count != 1 || c.record.buyout == 0 || c.record.buyout > f0_hard_max_buyout { return false; }
        if c.disenchant_id == 0 || c.safe_de_ev == 0 { return false; }
        if poc08_de_source_confidence(c.record.item_id) == 0 { return false; }
        if !poc08_f0_all_materials_medium(c.disenchant_id, &material_confidence) { return false; }
        let (_decision_ev, decision_profit, decision_roi_bps, _factor_bps) = poc08_f0_liquidation_decision(c);
        if decision_profit < i64::from(f0_min_safe_profit) || decision_roi_bps < f0_min_safe_roi_bps || c.de_ploss_bps > f0_max_ploss_bps { return false; }
        decision_profit.saturating_sub(c.vendor_profit) >= i64::from(f0_min_edge_vs_vendor)
    }).collect::<Vec<_>>();
    f0.sort_by(|a,b| {
        let ap = poc08_f0_liquidation_decision(a).1;
        let bp = poc08_f0_liquidation_decision(b).1;
        bp.cmp(&ap).then_with(|| a.record.buyout.cmp(&b.record.buyout))
    });
    let export = env::var("WOW112_F0_ELIGIBLE_EXPORT").unwrap_or_else(|_| "POC08_F0_ELIGIBLE.csv".to_string());
    let mut csv = String::from("rank,auction_id,item_id,buyout,page,safe_de_ev,model_disagreement_bps,model_confidence_factor_bps,decision_ev,decision_profit,decision_roi_bps,de_ploss_bps,heuristic_ev,reference_ev,source,source_confidence,vendor_profit,disenchant_id\\n");
    for (rank,c) in f0.iter().enumerate() {
        let (decision_ev,decision_profit,decision_roi_bps,factor_bps)=poc08_f0_liquidation_decision(c);
        csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n", rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.page,c.safe_de_ev,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),factor_bps,decision_ev,decision_profit,decision_roi_bps,c.de_ploss_bps,c.heuristic_de_ev,c.reference_de_ev,poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),poc08_de_source_confidence(c.record.item_id),c.vendor_profit,c.disenchant_id));
    }
    std::fs::write(&export, csv.as_bytes()).map_err(|e| format!("POC08-F0 export failed: {e}"))?;
    println!("[POC08-F0-V31] ELIGIBILITY PASS eligible={} thresholds=liquidation_profit:{} liquidation_roi_bps:{} ploss_bps:{} edge_vendor:{} hard_max_buyout:{} model_disagreement=CONFIDENCE_HAIRCUT_NOT_KILL_SWITCH confidence_factor_floor_bps=8500 mutation=DISABLED export={:?}", f0.len(), f0_min_safe_profit,f0_min_safe_roi_bps,f0_max_ploss_bps,f0_min_edge_vs_vendor,f0_hard_max_buyout,export);
    for (rank,c) in f0.iter().take(20).enumerate() {
        let (decision_ev,decision_profit,decision_roi_bps,factor_bps)=poc08_f0_liquidation_decision(c);
        println!("[POC08-F0-V31-ELIGIBLE] rank={} auction_id={} item_id={} buyout={} safe_ev={} disagreement_bps={} confidence_factor_bps={} decision_ev={} decision_profit={} decision_roi_bps={} ploss_bps={} source={} source_confidence={} vendor_profit={} deid={}",rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.safe_de_ev,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),factor_bps,decision_ev,decision_profit,decision_roi_bps,c.de_ploss_bps,poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),poc08_de_source_confidence(c.record.item_id),c.vendor_profit,c.disenchant_id);
    }
'''
rep('f0 block', old_f0, new_f0)

old_live='''    let max_buy=poc07_env_u32_default("WOW112_F1_HARD_MAX_SINGLE_BUYOUT",150_000)?;
    let min_vendor=i64::from(poc07_env_u32_default("WOW112_F1_MIN_VENDOR_PROFIT",1)?);
    let max_disagree=poc07_env_u32_default("WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS",0)?;
    let de_limit=poc07_env_u32_default("WOW112_UNIFIED_DE_MAX_PURCHASES",5)?;
'''
new_live='''    let max_buy=poc07_env_u32_default("WOW112_F1_HARD_MAX_SINGLE_BUYOUT",150_000)?;
    let min_vendor=i64::from(poc07_env_u32_default("WOW112_F1_MIN_VENDOR_PROFIT",1)?);
    let min_live_de_liquidation_profit=i64::from(poc07_env_u32_default("WOW112_F1_DE_MIN_LIQUIDATION_PROFIT",2_500)?);
    let de_limit=poc07_env_u32_default("WOW112_UNIFIED_DE_MAX_PURCHASES",5)?;
'''
rep('live env', old_live, new_live)

old_de_ok='''    let de_ok=|c:&Poc08EconomyCandidate|c.record.count==1&&c.record.buyout>0&&c.record.buyout<=max_buy&&c.disenchant_id>0&&c.de_risk_pass&&c.safe_de_ev>0&&in_f0(c)&&(poc08_de_source_confidence(c.record.item_id)>=2||(poc08_de_source(c.record.item_id)==Some("CapyDB")&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)==0))&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)<=max_disagree;
'''
new_de_ok='''    let de_ok=|c:&Poc08EconomyCandidate|c.record.count==1&&c.record.buyout>0&&c.record.buyout<=max_buy&&c.disenchant_id>0&&c.de_risk_pass&&c.safe_de_ev>0&&in_f0(c)&&poc08_de_source_confidence(c.record.item_id)>0&&poc08_f0_liquidation_decision(c).1>=min_live_de_liquidation_profit;
'''
rep('de_ok', old_de_ok, new_de_ok)

old_queue='''    for c in economy_candidates.iter(){
        let vok=!matches!(f1_action,Poc08F1Action::DeBest)&&vendor_ok(c); let dok=!matches!(f1_action,Poc08F1Action::VendorBest)&&de_ok(c);
        let chosen=match(vok,dok){(true,true)=>if c.vendor_profit>=c.de_profit{Some((Poc08Exit::Vendor,c.vendor_profit))}else{Some((Poc08Exit::Disenchant,c.de_profit))},(true,false)=>Some((Poc08Exit::Vendor,c.vendor_profit)),(false,true)=>Some((Poc08Exit::Disenchant,c.de_profit)),_=>None};
        if let Some((route,profit))=chosen{queue.push((route,c,profit));}
    }
'''
new_queue='''    for c in economy_candidates.iter(){
        let de_liquidation_profit=poc08_f0_liquidation_decision(c).1;
        let vok=!matches!(f1_action,Poc08F1Action::DeBest)&&vendor_ok(c); let dok=!matches!(f1_action,Poc08F1Action::VendorBest)&&de_ok(c);
        let chosen=match(vok,dok){(true,true)=>if c.vendor_profit>=de_liquidation_profit{Some((Poc08Exit::Vendor,c.vendor_profit))}else{Some((Poc08Exit::Disenchant,de_liquidation_profit))},(true,false)=>Some((Poc08Exit::Vendor,c.vendor_profit)),(false,true)=>Some((Poc08Exit::Disenchant,de_liquidation_profit)),_=>None};
        if let Some((route,profit))=chosen{queue.push((route,c,profit));}
    }
'''
rep('queue decision profit', old_queue, new_queue)

s=s.replace('de_profit={}",rank,reason,c.record.auction_id,c.record.item_id,c.disenchant_id,c.vendor_profit,c.de_profit);','de_liquidation_profit={}",rank,reason,c.record.auction_id,c.record.item_id,c.disenchant_id,c.vendor_profit,poc08_f0_liquidation_decision(c).1);')

p.write_text(s,encoding='utf-8')
print('[POC08-DE-LIQUIDATION-V31-F0-PATCH] PASS')
