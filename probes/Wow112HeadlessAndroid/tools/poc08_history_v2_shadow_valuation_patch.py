from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: UNIFIED_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

def replace_once(label, old, new):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{label}: expected 1 got {n}')
    s = s.replace(old, new, 1)

loader_anchor = '''fn poc08_exposure_factor_bps(self_units:u64,external_units:u64,floor_bps:u32)->(u32,u32){
    if self_units==0{return(0,10_000);}
    let total=self_units.saturating_add(external_units).max(1);
    let share=(self_units.saturating_mul(10_000)/total).min(10_000) as u32;
    let factor=10_000u32.saturating_sub(share/2).max(floor_bps.min(10_000));
    (share,factor)
}

'''
loader_insert = loader_anchor + '''#[derive(Clone, Copy, Debug)]
struct Poc08HistoryV2ShadowPoint {
    unit_price: u32,
    confidence_bps: u32,
    sample_scans: u32,
    freshness_bps: u32,
    coverage_bps: u32,
}

fn poc08_load_history_v2_shadow_pricebook() -> std::collections::HashMap<u32, Poc08HistoryV2ShadowPoint> {
    let path=env::var("WOW112_HISTORY_V2_PRICEBOOK_PATH").unwrap_or_else(|_|"HISTORY_V2_PRICEBOOK.csv".to_string());
    let min_conf=poc07_env_u32_default("WOW112_HISTORY_V2_MIN_CONFIDENCE_BPS",5_000).unwrap_or(5_000).min(10_000);
    let min_scans=poc07_env_u32_default("WOW112_HISTORY_V2_MIN_SAMPLE_SCANS",2).unwrap_or(2).max(1);
    let Ok(text)=std::fs::read_to_string(&path) else {
        println!("[POC08-HISTORY-V2-SHADOW] pricebook_missing path={:?} action=FAIL_OPEN_AUDIT_ONLY buy_decision_influence=NO",path);
        return std::collections::HashMap::new();
    };
    let mut out=std::collections::HashMap::<u32,Poc08HistoryV2ShadowPoint>::new();
    let mut rejected=0usize;
    for line in text.lines().skip(1){
        let c=line.split(',').collect::<Vec<_>>();
        if c.len()<6{rejected+=1;continue;}
        let Ok(item_id)=c[0].trim().parse::<u32>() else {rejected+=1;continue;};
        let Ok(unit_price)=c[1].trim().parse::<u32>() else {rejected+=1;continue;};
        let Ok(confidence_bps)=c[2].trim().parse::<u32>() else {rejected+=1;continue;};
        let Ok(sample_scans)=c[3].trim().parse::<u32>() else {rejected+=1;continue;};
        let Ok(freshness_bps)=c[4].trim().parse::<u32>() else {rejected+=1;continue;};
        let Ok(coverage_bps)=c[5].trim().parse::<u32>() else {rejected+=1;continue;};
        if item_id==0||unit_price==0||confidence_bps<min_conf||sample_scans<min_scans{rejected+=1;continue;}
        out.insert(item_id,Poc08HistoryV2ShadowPoint{unit_price,confidence_bps,sample_scans,freshness_bps,coverage_bps});
    }
    println!("[POC08-HISTORY-V2-SHADOW] pricebook_loaded path={:?} accepted={} rejected={} min_confidence_bps={} min_sample_scans={} buy_decision_influence=NO",
        path,out.len(),rejected,min_conf,min_scans);
    out
}

'''
replace_once('history v2 loader anchor', loader_anchor, loader_insert)

audit_anchor = 'fn poc08_build_combined_decisions(\n'
audit_fn = '''fn poc08_history_v2_shadow_audit(
    scanned: &[(u32, Poc06AuctionRecord)],
    vendor_values: &std::collections::HashMap<u32, u32>,
    current_safe_de_values: &std::collections::HashMap<u32, u32>,
    current_safe_mat_prices: &std::collections::HashMap<u32, u32>,
    history_de_values: &std::collections::HashMap<u32, u32>,
    history_mat_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
    min_de_safe_profit: u32,
    min_de_safe_roi_bps: u32,
    max_de_ploss_bps: u32,
    max_buyout: u32,
    min_profit: i64,
    blacklist: &HashSet<u32>,
) -> Result<(), String> {
    if history_mat_prices.is_empty() {
        println!("[POC08-HISTORY-V2-SHADOW] audit_skipped reason=EMPTY_OR_UNAVAILABLE_PRICEBOOK buy_decision_influence=NO");
        return Ok(());
    }
    use std::io::Write as _;
    let path=env::var("WOW112_HISTORY_V2_SHADOW_EXPORT").unwrap_or_else(|_|"POC08_HISTORY_V2_SHADOW_VALUATIONS.csv".to_string());
    let mut file=std::fs::File::create(&path).map_err(|e|format!("history v2 shadow export create failed path={path:?}: {e}"))?;
    writeln!(file,"auction_id,item_id,count,buyout,page,vendor_profit,current_de_ev,current_de_profit,current_de_ploss_bps,current_route,history_de_ev,history_de_profit,history_de_ploss_bps,shadow_route,shadow_would_change_route,history_material_coverage,history_buy_decision_changed")
        .map_err(|e|format!("history v2 shadow export header failed: {e}"))?;
    let mut rows=0usize;let mut would_change=0usize;let mut history_de_available=0usize;
    for(page,record)in scanned.iter().copied(){
        if record.buyout==0||record.buyout>max_buyout||record.count==0||blacklist.contains(&record.item_id){continue;}
        let vendor_unit=vendor_values.get(&record.item_id).copied().unwrap_or(0);
        let vendor_gross=u64::from(vendor_unit).saturating_mul(u64::from(record.count));
        let vendor_profit=poc08_profit(vendor_gross,record.buyout);
        let exact_de=poc08_exact_disenchant_id(record.item_id);
        let current_de_ev=if matches!(exact_de,Some(id)if id>0){current_safe_de_values.get(&record.item_id).copied().unwrap_or(0)}else{0};
        let current_de_gross=u64::from(current_de_ev).saturating_mul(u64::from(record.count));
        let current_de_profit=poc08_profit(current_de_gross,record.buyout);
        let current_de_roi=poc08_roi_bps(current_de_gross,record.buyout);
        let current_de_ploss=if record.count==1{
            exact_de.and_then(|id|if id>0{poc08_de_loss_probability_bps(id,current_safe_mat_prices,net_bps,record.buyout)}else{None}).unwrap_or(10_000)
        }else{10_000};
        let current_de_ok=current_de_ev>0&&record.count==1&&current_de_profit>=i64::from(min_de_safe_profit)&&current_de_roi>=min_de_safe_roi_bps&&current_de_ploss<=max_de_ploss_bps;
        let vendor_ok=vendor_unit>0&&vendor_profit>=min_profit;
        let current_route=match(vendor_ok,current_de_ok){
            (true,true)if current_de_profit>vendor_profit=>"DE",
            (true,_)=>"VENDOR",
            (false,true)=>"DE",
            _=>"NONE",
        };

        let history_de_ev=if matches!(exact_de,Some(id)if id>0){history_de_values.get(&record.item_id).copied().unwrap_or(0)}else{0};
        if history_de_ev>0{history_de_available+=1;}
        let history_de_gross=u64::from(history_de_ev).saturating_mul(u64::from(record.count));
        let history_de_profit=poc08_profit(history_de_gross,record.buyout);
        let history_de_roi=poc08_roi_bps(history_de_gross,record.buyout);
        let history_de_ploss=if record.count==1{
            exact_de.and_then(|id|if id>0{poc08_de_loss_probability_bps(id,history_mat_prices,net_bps,record.buyout)}else{None}).unwrap_or(10_000)
        }else{10_000};
        let history_de_ok=history_de_ev>0&&record.count==1&&history_de_profit>=i64::from(min_de_safe_profit)&&history_de_roi>=min_de_safe_roi_bps&&history_de_ploss<=max_de_ploss_bps;
        let shadow_route=match(vendor_ok,history_de_ok){
            (true,true)if history_de_profit>vendor_profit=>"DE",
            (true,_)=>"VENDOR",
            (false,true)=>"DE",
            _=>"NONE",
        };
        let changed=current_route!=shadow_route;
        if changed{would_change+=1;}
        let material_coverage=exact_de.and_then(|id|poc08_reference_de_outcomes(id)).map(|o|{
            let total=o.len();
            let have=o.iter().filter(|x|history_mat_prices.contains_key(&x.material_id)).count();
            format!("{}/{}",have,total)
        }).unwrap_or_else(||"0/0".to_string());
        writeln!(file,"{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},0",
            record.auction_id,record.item_id,record.count,record.buyout,page,vendor_profit,
            current_de_ev,current_de_profit,current_de_ploss,current_route,
            history_de_ev,history_de_profit,history_de_ploss,shadow_route,
            if changed{1}else{0},material_coverage)
            .map_err(|e|format!("history v2 shadow export row failed: {e}"))?;
        rows+=1;
    }
    println!("[POC08-HISTORY-V2-SHADOW] PASS rows={} history_de_available={} shadow_would_change_route={} export={:?} stage=COMBINED_DECISION_AUDIT history_buy_decision_changed=0 buy_decision_influence=NO",
        rows,history_de_available,would_change,path);
    Ok(())
}

''' + audit_anchor
replace_once('shadow audit anchor', audit_anchor, audit_fn)

safe_anchor = '''    println!(
        "[POC08-C-SAFEEV] PASS model_covered={} positive_safe_ev={} raw_reference_ev={} rule=LOW_OR_MISSING_MATERIAL_CONTRIBUTES_ZERO",
        safe_model_covered, safe_de_values.len(), reference_de_values.len()
    );

'''
safe_insert = safe_anchor + '''    let history_v2_points=poc08_load_history_v2_shadow_pricebook();
    let history_v2_mat_prices=history_v2_points.iter().map(|(item_id,p)|(*item_id,p.unit_price)).collect::<std::collections::HashMap<u32,u32>>();
    let mut history_v2_de_values=std::collections::HashMap::<u32,u32>::new();
    for item_id in item_ids.iter().copied(){
        let Some(deid)=poc08_exact_disenchant_id(item_id)else{continue;};
        if deid==0{continue;}
        let Some(outcomes)=poc08_reference_de_outcomes(deid)else{continue;};
        let ev=poc08_safe_ev_from_outcomes(&outcomes,&history_v2_mat_prices,net_bps);
        if ev>0{history_v2_de_values.insert(item_id,ev);}
    }
    let history_conf_min=history_v2_points.values().map(|p|p.confidence_bps).min().unwrap_or(0);
    let history_scans_min=history_v2_points.values().map(|p|p.sample_scans).min().unwrap_or(0);
    let history_fresh_min=history_v2_points.values().map(|p|p.freshness_bps).min().unwrap_or(0);
    let history_cov_min=history_v2_points.values().map(|p|p.coverage_bps).min().unwrap_or(0);
    println!("[POC08-HISTORY-V2-SHADOW] DE model material_prices={} item_ev={} min_confidence_bps={} min_sample_scans={} min_freshness_bps={} min_coverage_bps={} history_buy_decision_changed=0",
        history_v2_mat_prices.len(),history_v2_de_values.len(),history_conf_min,history_scans_min,history_fresh_min,history_cov_min);

'''
replace_once('shadow DE values anchor', safe_anchor, safe_insert)

call_anchor = '''    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        decision_scanned,
        &vendor_values,
        &de_values,
        &reference_de_values,
        &safe_de_values,
        &safe_mat_prices,
        net_bps,
        min_de_safe_profit,
        min_de_safe_roi_bps,
        max_de_ploss_bps,
        max_buyout,
        min_profit,
        &blacklist,
    );
'''
call_insert = call_anchor + '''    if let Err(error)=poc08_history_v2_shadow_audit(
        decision_scanned,
        &vendor_values,
        &safe_de_values,
        &safe_mat_prices,
        &history_v2_de_values,
        &history_v2_mat_prices,
        net_bps,
        min_de_safe_profit,
        min_de_safe_roi_bps,
        max_de_ploss_bps,
        max_buyout,
        min_profit,
        &blacklist,
    ){
        println!("[POC08-HISTORY-V2-SHADOW] fail_open error={:?} history_buy_decision_changed=0 buy_decision_influence=NO",error);
    }
'''
replace_once('shadow audit call anchor', call_anchor, call_insert)

for marker in [
    'POC08-HISTORY-V2-SHADOW',
    'WOW112_HISTORY_V2_PRICEBOOK_PATH',
    'WOW112_HISTORY_V2_SHADOW_EXPORT',
    'history_buy_decision_changed=0',
    'buy_decision_influence=NO',
    'shadow_would_change_route',
]:
    if marker not in s:
        raise SystemExit('missing marker '+marker)

p.write_text(s, encoding='utf-8')
print('[POC08-HISTORY-V2-SHADOW-PATCH] PASS')
