from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: UNIFIED_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

def rep(label: str, old: str, new: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{label}: expected 1 got {n}')
    s = s.replace(old, new, 1)

old_scope = '''    poc08_export_de_provenance(&item_ids)?;
    let vendor_values = poc08_query_vendor_values_turbo(
        stream,
        &mut crypto,
        &item_ids,
        item_query_window,
    )?;
    let fast_item_set=item_ids.iter().copied().collect::<HashSet<u32>>();
    let fast_scanned = if de_fast_prefilter {
        scanned.iter().copied().filter(|(_,r)| r.count==1 && r.buyout>0 && r.buyout<=max_buyout && fast_item_set.contains(&r.item_id) && !blacklist.contains(&r.item_id)).collect::<Vec<_>>()
    } else { Vec::new() };
    let decision_scanned: &[(u32,Poc06AuctionRecord)] = if de_fast_prefilter { fast_scanned.as_slice() } else { scanned.as_slice() };
    println!("[POC08-DE-FAST-PREFILTER] stage=DECISION_ROWS enabled={} full_snapshot_records={} decision_records={} skipped_records={} material_book_source=FULL_SNAPSHOT",
        de_fast_prefilter, scanned.len(), decision_scanned.len(), scanned.len().saturating_sub(decision_scanned.len()));
    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        decision_scanned,
        &vendor_values,
'''
new_scope = '''    poc08_export_de_provenance(&item_ids)?;
    // V4 unified mode: DE keeps the fast/model-supported item scope, while Vendor can
    // independently value every affordable item from the SAME full AH snapshot.
    let vendor_full_scope = env::var("WOW112_VENDOR_FULL_SCOPE")
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1"|"true"|"yes"|"on"))
        .unwrap_or(false);
    let vendor_item_ids: &[u32] = if vendor_full_scope { affordable_item_ids.as_slice() } else { item_ids.as_slice() };
    println!("[POC08-UNIFIED-V4] one_snapshot=YES vendor_scope={} vendor_query_unique={} de_query_unique={} de_fast_prefilter={} de_scope=MODEL_SUPPORTED",
        if vendor_full_scope { "FULL_AFFORDABLE" } else { "DE_SCOPED" }, vendor_item_ids.len(), item_ids.len(), de_fast_prefilter);
    let vendor_values = poc08_query_vendor_values_turbo(
        stream,
        &mut crypto,
        vendor_item_ids,
        item_query_window,
    )?;
    let fast_item_set=item_ids.iter().copied().collect::<HashSet<u32>>();
    let fast_scanned = if de_fast_prefilter {
        scanned.iter().copied().filter(|(_,r)| r.count==1 && r.buyout>0 && r.buyout<=max_buyout && fast_item_set.contains(&r.item_id) && !blacklist.contains(&r.item_id)).collect::<Vec<_>>()
    } else { Vec::new() };
    let decision_scanned: &[(u32,Poc06AuctionRecord)] = if vendor_full_scope { scanned.as_slice() } else if de_fast_prefilter { fast_scanned.as_slice() } else { scanned.as_slice() };
    println!("[POC08-UNIFIED-V4] stage=DECISION_ROWS vendor_full_scope={} full_snapshot_records={} decision_records={} skipped_records={} material_book_source=FULL_SNAPSHOT",
        vendor_full_scope, scanned.len(), decision_scanned.len(), scanned.len().saturating_sub(decision_scanned.len()));
    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        decision_scanned,
        &vendor_values,
'''
rep('split vendor/de scope', old_scope, new_scope)

old_limits = '''    let min_live_de_liquidation_profit=i64::from(poc07_env_u32_default("WOW112_F1_DE_MIN_LIQUIDATION_PROFIT",2_500)?);
    let de_limit=poc07_env_u32_default("WOW112_UNIFIED_DE_MAX_PURCHASES",5)?;
    let in_f0='''
new_limits = '''    let min_live_de_liquidation_profit=i64::from(poc07_env_u32_default("WOW112_F1_DE_MIN_LIQUIDATION_PROFIT",2_500)?);
    let de_limit=poc07_env_u32_default("WOW112_UNIFIED_DE_MAX_PURCHASES",5)?;
    let vendor_limit=poc07_env_u32_default("WOW112_UNIFIED_VENDOR_MAX_PURCHASES",25)?;
    let total_limit=poc07_env_u32_default("WOW112_UNIFIED_MAX_PURCHASES",25)?;
    let spend_limit=poc07_env_u32_default("WOW112_UNIFIED_MAX_SPEND",100_000)?;
    let in_f0='''
rep('unified hard limits', old_limits, new_limits)

old_queue_log = '''    println!("[POC08-UNIFIED-MULTI] QUEUE action={:?} eligible={} vendor={} de={} de_limit={} vendor_limit=UNLIMITED order=PROFIT_DESC_VENDOR_TIE",f1_action,queue.len(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Vendor)).count(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Disenchant)).count(),de_limit);'''
new_queue_log = '''    println!("[POC08-UNIFIED-V4] QUEUE action={:?} eligible={} vendor={} de={} limits_total={} limits_vendor={} limits_de={} max_spend={} order=RISK_ADJUSTED_PROFIT_DESC_VENDOR_TIE",f1_action,queue.len(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Vendor)).count(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Disenchant)).count(),total_limit,vendor_limit,de_limit,spend_limit);'''
rep('queue limits log', old_queue_log, new_queue_log)

old_loop = '''    let(mut bought_total,mut bought_vendor,mut bought_de,mut stale_skipped,mut de_limit_skipped)=(0u32,0u32,0u32,0u32,0u32);
    for(rank,(route,c,profit))in queue.iter().enumerate(){
        if matches!(route,Poc08Exit::Disenchant)&&bought_de>=de_limit{de_limit_skipped+=1;continue;}
        println!("[POC08-UNIFIED-MULTI] TRY rank={} route={} auction_id={} item_id={} count={} buyout={} profit={}",rank,route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,profit);
'''
new_loop = '''    let(mut bought_total,mut bought_vendor,mut bought_de,mut bought_spend,mut stale_skipped,mut de_limit_skipped,mut vendor_limit_skipped,mut spend_limit_skipped)=(0u32,0u32,0u32,0u32,0u32,0u32,0u32,0u32);
    for(rank,(route,c,profit))in queue.iter().enumerate(){
        if bought_total>=total_limit { break; }
        if matches!(route,Poc08Exit::Disenchant)&&bought_de>=de_limit{de_limit_skipped+=1;continue;}
        if matches!(route,Poc08Exit::Vendor)&&bought_vendor>=vendor_limit{vendor_limit_skipped+=1;continue;}
        if bought_spend.saturating_add(c.record.buyout)>spend_limit{spend_limit_skipped+=1;continue;}
        println!("[POC08-UNIFIED-V4] TRY rank={} route={} auction_id={} item_id={} count={} buyout={} profit={} spend_before={} spend_cap={}",rank,route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,profit,bought_spend,spend_limit);
'''
rep('bounded unified loop', old_loop, new_loop)

old_confirm = '''            Ok(())=>{bought_total+=1;if matches!(route,Poc08Exit::Vendor){bought_vendor+=1}else{bought_de+=1};*ah_mutation_committed=false;println!("[POC08-UNIFIED-MULTI] CONFIRMED auction_id={} purchases={} vendor={} de={} next_buy_armed=YES",c.record.auction_id,bought_total,bought_vendor,bought_de);},'''
new_confirm = '''            Ok(())=>{bought_total+=1;bought_spend=bought_spend.saturating_add(c.record.buyout);if matches!(route,Poc08Exit::Vendor){bought_vendor+=1}else{bought_de+=1};*ah_mutation_committed=false;println!("[POC08-UNIFIED-V4] CONFIRMED auction_id={} purchases={} vendor={} de={} spend={} next_buy_armed=YES",c.record.auction_id,bought_total,bought_vendor,bought_de,bought_spend);},'''
rep('spend accounting', old_confirm, new_confirm)

old_pass = '''    println!("[POC08-UNIFIED-MULTI] LIVE PASS purchases={} vendor={} de={} stale_skipped={} de_limit_skipped={} vendor_limit=UNLIMITED de_limit={} snapshot_reused=YES",bought_total,bought_vendor,bought_de,stale_skipped,de_limit_skipped,de_limit); Ok(())'''
new_pass = '''    println!("[POC08-UNIFIED-V4] LIVE PASS purchases={} vendor={} de={} spend={} stale_skipped={} de_limit_skipped={} vendor_limit_skipped={} spend_limit_skipped={} total_limit={} vendor_limit={} de_limit={} spend_limit={} snapshot_reused=YES one_mutation_boundary=YES",bought_total,bought_vendor,bought_de,bought_spend,stale_skipped,de_limit_skipped,vendor_limit_skipped,spend_limit_skipped,total_limit,vendor_limit,de_limit,spend_limit); Ok(())'''
rep('bounded live pass', old_pass, new_pass)

for marker in [
    'POC08-UNIFIED-V4',
    'WOW112_VENDOR_FULL_SCOPE',
    'FULL_AFFORDABLE',
    'WOW112_UNIFIED_VENDOR_MAX_PURCHASES',
    'WOW112_UNIFIED_MAX_PURCHASES',
    'WOW112_UNIFIED_MAX_SPEND',
    'one_mutation_boundary=YES',
    'NO_AUTO_RETRY_FROM_THIS_POINT=YES',
]:
    if marker not in s:
        raise SystemExit('missing marker '+marker)

p.write_text(s, encoding='utf-8')
print('[POC08-UNIFIED-VENDOR-DE-V4-PATCH] PASS')
