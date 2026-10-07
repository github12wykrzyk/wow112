from pathlib import Path
import re
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

limit_pattern = re.compile(r'(?m)^(\s*let de_limit=poc07_env_u32_default\("WOW112_UNIFIED_DE_MAX_PURCHASES",\s*[0-9_]+\)\?;\s*)$')
m = limit_pattern.search(s)
if not m:
    raise SystemExit('unified hard limits: de_limit anchor missing')
if 'WOW112_UNIFIED_VENDOR_MAX_PURCHASES' in s:
    raise SystemExit('unified hard limits: already applied unexpectedly')
indent = re.match(r'\s*', m.group(1)).group(0)
insert = m.group(1) + '\n' + indent + 'let vendor_limit=poc07_env_u32_default("WOW112_UNIFIED_VENDOR_MAX_PURCHASES",25)?;' + '\n' + indent + 'let total_limit=poc07_env_u32_default("WOW112_UNIFIED_MAX_PURCHASES",25)?;' + '\n' + indent + 'let spend_limit=poc07_env_u32_default("WOW112_UNIFIED_MAX_SPEND",100_000)?;'
s = s[:m.start()] + insert + s[m.end():]

queue_log_pattern = re.compile(r'(?m)^(\s*)println!\("\[POC08-UNIFIED-MULTI\] QUEUE[^\n]*\);\s*$')
qm = queue_log_pattern.search(s)
if not qm:
    raise SystemExit('queue limits log: semantic anchor missing')
new_queue_log = qm.group(1) + 'println!("[POC08-UNIFIED-V4][POC08-UNIFIED-MULTI] QUEUE action={:?} eligible={} vendor={} de={} limits_total={} limits_vendor={} limits_de={} max_spend={} order=RISK_ADJUSTED_PROFIT_DESC_VENDOR_TIE",f1_action,queue.len(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Vendor)).count(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Disenchant)).count(),total_limit,vendor_limit,de_limit,spend_limit);'
s = s[:qm.start()] + new_queue_log + s[qm.end():]

# Replace the complete mutable-buy loop as one semantic unit. Prior V3/V3.1 patches
# are free to reformat the body; the stable structural anchors are the queue-empty
# guard and the final unified LIVE PASS. Safety semantics are copied unchanged:
# exact revalidation remains in poc07_buy_exact_one and unknown mutation errors return.
loop_pattern = re.compile(
    r'(?ms)^(\s*)let\(mut bought_total,.*?^\s*println!\("\[POC08-UNIFIED-MULTI\] LIVE PASS[^\n]*?Ok\(\(\)\)\s*$'
)
lm = loop_pattern.search(s)
if not lm:
    raise SystemExit('bounded unified loop: semantic block missing')
indent = lm.group(1)
new_loop = indent + '''let(mut bought_total,mut bought_vendor,mut bought_de,mut bought_spend,mut stale_skipped,mut de_limit_skipped,mut vendor_limit_skipped,mut spend_limit_skipped)=(0u32,0u32,0u32,0u32,0u32,0u32,0u32,0u32);
    for(rank,(route,c,profit))in queue.iter().enumerate(){
        if bought_total>=total_limit { break; }
        if matches!(route,Poc08Exit::Disenchant)&&bought_de>=de_limit{de_limit_skipped+=1;continue;}
        if matches!(route,Poc08Exit::Vendor)&&bought_vendor>=vendor_limit{vendor_limit_skipped+=1;continue;}
        if bought_spend.saturating_add(c.record.buyout)>spend_limit{spend_limit_skipped+=1;continue;}
        println!("[POC08-UNIFIED-V4] TRY rank={} route={} auction_id={} item_id={} count={} buyout={} profit={} spend_before={} spend_cap={}",rank,route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,profit,bought_spend,spend_limit);
        let buy=poc08_f1_as_poc07(c,*route);
        match poc07_buy_exact_one(stream,&mut crypto,auctioneer_guid,auction_house,mailbox_guid,buy,ah_mutation_committed){
            Ok(())=>{bought_total+=1;bought_spend=bought_spend.saturating_add(c.record.buyout);if matches!(route,Poc08Exit::Vendor){bought_vendor+=1}else{bought_de+=1};*ah_mutation_committed=false;println!("[POC08-UNIFIED-V4] CONFIRMED auction_id={} purchases={} vendor={} de={} spend={} next_buy_armed=YES",c.record.auction_id,bought_total,bought_vendor,bought_de,bought_spend);},
            Err(error) if error.starts_with("POC07_BUY_TARGET_STALE")=>{*ah_mutation_committed=false;stale_skipped+=1;println!("[POC08-UNIFIED-V4] STALE SKIP auction_id={} no_purchase_sent=YES stale_skipped={}",c.record.auction_id,stale_skipped);},
            Err(error)=>return Err(error),
        }
    }
    println!("[POC08-UNIFIED-V4] LIVE PASS purchases={} vendor={} de={} spend={} stale_skipped={} de_limit_skipped={} vendor_limit_skipped={} spend_limit_skipped={} total_limit={} vendor_limit={} de_limit={} spend_limit={} snapshot_reused=YES one_mutation_boundary=YES",bought_total,bought_vendor,bought_de,bought_spend,stale_skipped,de_limit_skipped,vendor_limit_skipped,spend_limit_skipped,total_limit,vendor_limit,de_limit,spend_limit); Ok(())'''
s = s[:lm.start()] + new_loop + s[lm.end():]

for marker in [
    'POC08-UNIFIED-V4',
    'POC08-UNIFIED-MULTI',
    'WOW112_VENDOR_FULL_SCOPE',
    'FULL_AFFORDABLE',
    'WOW112_UNIFIED_VENDOR_MAX_PURCHASES',
    'WOW112_UNIFIED_MAX_PURCHASES',
    'WOW112_UNIFIED_MAX_SPEND',
    'one_mutation_boundary=YES',
    'NO_AUTO_RETRY_FROM_THIS_POINT=YES',
    'POC07_BUY_TARGET_STALE',
]:
    if marker not in s:
        raise SystemExit('missing marker '+marker)

p.write_text(s, encoding='utf-8')
print('[POC08-UNIFIED-VENDOR-DE-V4-PATCH] PASS')