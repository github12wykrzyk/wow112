from pathlib import Path
import sys
if len(sys.argv)!=2: raise SystemExit('usage: UNIFIED_RS')
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

def rep(old,new,label):
    global s
    n=s.count(old)
    if n!=1: raise SystemExit(f'{label}: expected 1 got {n}')
    s=s.replace(old,new,1)

rep('const POC08_MAT_GUARD_THIN_SELLERS: u32 = 1 << 5;','const POC08_MAT_GUARD_THIN_SELLERS: u32 = 1 << 5;\nconst POC08_MAT_GUARD_LIQUIDITY_HAIRCUT: u32 = 1 << 6;','guard const')
rep('    if flags & POC08_MAT_GUARD_THIN_SELLERS != 0 { out.push("THIN_SELLERS"); }\n    if out.is_empty()',
    '    if flags & POC08_MAT_GUARD_THIN_SELLERS != 0 { out.push("THIN_SELLERS"); }\n    if flags & POC08_MAT_GUARD_LIQUIDITY_HAIRCUT != 0 { out.push("LIQUIDITY_HAIRCUT"); }\n    if out.is_empty()', 'guard name')

start=s.index('fn poc08_load_material_history(path: &str) -> std::collections::HashMap<u32, Vec<u32>> {')
end=s.index('\nfn poc08_append_material_history(',start)
loader=r'''fn poc08_load_material_history(path: &str) -> std::collections::HashMap<u32, Vec<u32>> {
    // V2: history is evidence over TIME, not over scan count. Several scans in
    // one short manipulation window must not manufacture "3 observations".
    let bucket_secs = env::var("WOW112_MATERIAL_HISTORY_BUCKET_SECS").ok()
        .and_then(|v| v.parse::<u64>().ok()).unwrap_or(1_800).max(300);
    let max_age_secs = env::var("WOW112_MATERIAL_HISTORY_MAX_AGE_SECS").ok()
        .and_then(|v| v.parse::<u64>().ok()).unwrap_or(172_800).max(bucket_secs);
    let accept_legacy = env::var("WOW112_MATERIAL_HISTORY_ACCEPT_LEGACY").ok()
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1"|"true"|"yes"|"on"))
        .unwrap_or(false);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs()).unwrap_or(0);
    let mut bucket_min = std::collections::HashMap::<(u32,u64),u32>::new();
    let mut accepted_rows=0u32; let mut rejected_legacy=0u32; let mut rejected_quality=0u32; let mut rejected_age=0u32;
    let Ok(text) = std::fs::read_to_string(path) else { return std::collections::HashMap::new(); };
    for line in text.lines().skip(1) {
        let cols = line.split(',').collect::<Vec<_>>();
        if cols.len() < 7 { continue; }
        let is_v2 = cols.len() >= 9;
        if !is_v2 && !accept_legacy { rejected_legacy=rejected_legacy.saturating_add(1); continue; }
        let Ok(unix_s) = cols[0].trim().parse::<u64>() else { continue; };
        if unix_s > now.saturating_add(300) || now.saturating_sub(unix_s) > max_age_secs {
            rejected_age=rejected_age.saturating_add(1); continue;
        }
        let Ok(item_id) = cols[1].trim().parse::<u32>() else { continue; };
        let Ok(safe_price) = cols[5].trim().parse::<u32>() else { continue; };
        let conf = cols[6].trim();
        if item_id==0 || safe_price==0 || !matches!(conf,"MEDIUM"|"HIGH") { rejected_quality=rejected_quality.saturating_add(1); continue; }
        if is_v2 {
            let sellers=cols[7].trim().parse::<usize>().unwrap_or(0);
            let flags=cols[8].trim();
            // Only independently supported, non-anomalous observations may
            // teach the historical baseline. COLD_START is allowed because
            // its price is already conservatively haircutted.
            if sellers < 2 || flags.contains("SPIKE_BLOCK") || flags.contains("PARITY_BLOCK") || flags.contains("THIN_SELLERS") {
                rejected_quality=rejected_quality.saturating_add(1); continue;
            }
        }
        let bucket=unix_s / bucket_secs;
        bucket_min.entry((item_id,bucket)).and_modify(|v| *v=(*v).min(safe_price)).or_insert(safe_price);
        accepted_rows=accepted_rows.saturating_add(1);
    }
    let mut by_item = std::collections::HashMap::<u32,Vec<(u64,u32)>>::new();
    for ((item_id,bucket),price) in bucket_min { by_item.entry(item_id).or_default().push((bucket,price)); }
    let mut out=std::collections::HashMap::<u32,Vec<u32>>::new();
    let mut total_buckets=0usize;
    for (item_id,mut rows) in by_item {
        rows.sort_unstable_by_key(|x|x.0);
        if rows.len()>200 { let drain=rows.len()-200; rows.drain(0..drain); }
        total_buckets+=rows.len();
        out.insert(item_id,rows.into_iter().map(|x|x.1).collect());
    }
    println!("[POC08-C-HISTORY-V2] path={:?} bucket_secs={} max_age_secs={} accept_legacy={} accepted_rows={} distinct_buckets={} rejected_legacy={} rejected_quality={} rejected_age={}",
        path,bucket_secs,max_age_secs,accept_legacy,accepted_rows,total_buckets,rejected_legacy,rejected_quality,rejected_age);
    out
}
'''
s=s[:start]+loader+s[end:]

rep('    let history = poc08_load_material_history(&history_path);\n    let overrides = poc07_parse_value_map("WOW112_DE_MAT_VALUES")?;',
'''    let history = poc08_load_material_history(&history_path);
    let medium_haircut_bps = poc07_env_u32_default("WOW112_MATERIAL_MEDIUM_HAIRCUT_BPS", 8_500)?;
    if medium_haircut_bps > 10_000 { return Err(format!("WOW112_MATERIAL_MEDIUM_HAIRCUT_BPS must be <=10000, got {medium_haircut_bps}")); }
    let overrides = poc07_parse_value_map("WOW112_DE_MAT_VALUES")?;''','medium config')

needle='''        // Cold start never gets full spot-price trust even if the current AH
        // looks deep: 30% liquidation haircut until >=3 accepted observations.
        if safe_price > 0 && history_count < 3 {
            safe_price = (u64::from(safe_price).saturating_mul(7000) / 10_000)
                .min(u64::from(u32::MAX)) as u32;
            final_conf = final_conf.min(2);
        }

        if truncated { safe_price = 0; final_conf = 0; }'''
repl='''        // Cold start never gets full spot-price trust even if the current AH
        // looks deep: 30% liquidation haircut until >=3 TIME-BUCKETED observations.
        if safe_price > 0 && history_count < 3 {
            safe_price = (u64::from(safe_price).saturating_mul(7000) / 10_000)
                .min(u64::from(u32::MAX)) as u32;
            final_conf = final_conf.min(2);
        }

        // Established but only MEDIUM-liquidity markets get an additional
        // liquidation haircut. HIGH-depth markets do not. This models the
        // fact that a quoted AH price is not the same thing as realizable cash.
        if safe_price > 0 && history_count >= 3 && final_conf == 2 && medium_haircut_bps < 10_000 {
            safe_price = (u64::from(safe_price).saturating_mul(u64::from(medium_haircut_bps)) / 10_000)
                .min(u64::from(u32::MAX)) as u32;
            guard_flags |= POC08_MAT_GUARD_LIQUIDITY_HAIRCUT;
        }

        if truncated { safe_price = 0; final_conf = 0; }'''
rep(needle,repl,'liquidity haircut')

old='''    for(rank,(route,c,profit))in queue.iter().enumerate(){
        if matches!(route,Poc08Exit::Disenchant){
            if bought_de>=de_limit{de_limit_skipped+=1;continue;}
            let bucket_count=bought_by_deid.get(&c.disenchant_id).copied().unwrap_or(0);
            if bucket_count>=de_per_deid_limit{de_bucket_skipped+=1;continue;}
            if bought_de_spend.saturating_add(c.record.buyout)>de_spend_limit{de_spend_skipped+=1;continue;}
        }
        println!("[POC08-UNIFIED-MULTI] TRY rank={} route={} auction_id={} item_id={} count={} buyout={} profit={}",rank,route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,profit);
        let buy=poc08_f1_as_poc07(c,*route);
        match poc07_buy_exact_one(stream,&mut crypto,auctioneer_guid,auction_house,mailbox_guid,buy,ah_mutation_committed){
            Ok(())=>{bought_total+=1;if matches!(route,Poc08Exit::Vendor){bought_vendor+=1}else{bought_de+=1;bought_de_spend=bought_de_spend.saturating_add(c.record.buyout);*bought_by_deid.entry(c.disenchant_id).or_insert(0)+=1;};*ah_mutation_committed=false;println!("[POC08-UNIFIED-MULTI] CONFIRMED auction_id={} purchases={} vendor={} de={} de_spend={} deid={} deid_count={} next_buy_armed=YES",c.record.auction_id,bought_total,bought_vendor,bought_de,bought_de_spend,c.disenchant_id,bought_by_deid.get(&c.disenchant_id).copied().unwrap_or(0));},
            Err(error) if error.starts_with("POC07_BUY_TARGET_STALE")=>{*ah_mutation_committed=false;stale_skipped+=1;println!("[POC08-UNIFIED-MULTI] STALE SKIP auction_id={} no_purchase_sent=YES stale_skipped={}",c.record.auction_id,stale_skipped);},
            Err(error)=>return Err(error),
        }
    }
    println!("[POC08-UNIFIED-MULTI] LIVE PASS purchases={} vendor={} de={} de_spend={} stale_skipped={} de_limit_skipped={} de_bucket_skipped={} de_spend_skipped={} vendor_limit=UNLIMITED de_limit={} de_per_deid_limit={} de_spend_limit={} snapshot_reused=YES",bought_total,bought_vendor,bought_de,bought_de_spend,stale_skipped,de_limit_skipped,de_bucket_skipped,de_spend_skipped,de_limit,de_per_deid_limit,de_spend_limit); Ok(())'''
new='''    let mut de_guard_fallback_vendor=0u32;
    for(rank,(route,c,profit))in queue.iter().enumerate(){
        let mut exec_route=*route; let mut exec_profit=*profit;
        if matches!(exec_route,Poc08Exit::Disenchant){
            let bucket_count=bought_by_deid.get(&c.disenchant_id).copied().unwrap_or(0);
            let block_reason = if bought_de>=de_limit { Some("GLOBAL_DE_LIMIT") }
                else if bucket_count>=de_per_deid_limit { Some("DEID_LIMIT") }
                else if bought_de_spend.saturating_add(c.record.buyout)>de_spend_limit { Some("DE_SPEND_LIMIT") }
                else { None };
            if let Some(reason)=block_reason {
                if matches!(f1_action,Poc08F1Action::AutoBest) && vendor_ok(c) {
                    exec_route=Poc08Exit::Vendor; exec_profit=c.vendor_profit; de_guard_fallback_vendor=de_guard_fallback_vendor.saturating_add(1);
                    println!("[POC08-UNIFIED-MULTI] DE_GUARD_FALLBACK_VENDOR rank={} reason={} auction_id={} item_id={} deid={} vendor_profit={} de_profit={}",rank,reason,c.record.auction_id,c.record.item_id,c.disenchant_id,c.vendor_profit,c.de_profit);
                } else {
                    match reason {"GLOBAL_DE_LIMIT"=>de_limit_skipped=de_limit_skipped.saturating_add(1),"DEID_LIMIT"=>de_bucket_skipped=de_bucket_skipped.saturating_add(1),_=>de_spend_skipped=de_spend_skipped.saturating_add(1)}
                    continue;
                }
            }
        }
        println!("[POC08-UNIFIED-MULTI] TRY rank={} route={} auction_id={} item_id={} count={} buyout={} profit={}",rank,exec_route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,exec_profit);
        let buy=poc08_f1_as_poc07(c,exec_route);
        match poc07_buy_exact_one(stream,&mut crypto,auctioneer_guid,auction_house,mailbox_guid,buy,ah_mutation_committed){
            Ok(())=>{bought_total+=1;if matches!(exec_route,Poc08Exit::Vendor){bought_vendor+=1}else{bought_de+=1;bought_de_spend=bought_de_spend.saturating_add(c.record.buyout);*bought_by_deid.entry(c.disenchant_id).or_insert(0)+=1;};*ah_mutation_committed=false;println!("[POC08-UNIFIED-MULTI] CONFIRMED auction_id={} purchases={} vendor={} de={} de_spend={} deid={} deid_count={} next_buy_armed=YES",c.record.auction_id,bought_total,bought_vendor,bought_de,bought_de_spend,c.disenchant_id,bought_by_deid.get(&c.disenchant_id).copied().unwrap_or(0));},
            Err(error) if error.starts_with("POC07_BUY_TARGET_STALE")=>{*ah_mutation_committed=false;stale_skipped+=1;println!("[POC08-UNIFIED-MULTI] STALE SKIP auction_id={} no_purchase_sent=YES stale_skipped={}",c.record.auction_id,stale_skipped);},
            Err(error)=>return Err(error),
        }
    }
    println!("[POC08-UNIFIED-MULTI] LIVE PASS purchases={} vendor={} de={} de_spend={} stale_skipped={} de_limit_skipped={} de_bucket_skipped={} de_spend_skipped={} de_guard_fallback_vendor={} vendor_limit=UNLIMITED de_limit={} de_per_deid_limit={} de_spend_limit={} snapshot_reused=YES",bought_total,bought_vendor,bought_de,bought_de_spend,stale_skipped,de_limit_skipped,de_bucket_skipped,de_spend_skipped,de_guard_fallback_vendor,de_limit,de_per_deid_limit,de_spend_limit); Ok(())'''
rep(old,new,'execution fallback')

for m in ['POC08-C-HISTORY-V2','WOW112_MATERIAL_HISTORY_BUCKET_SECS','WOW112_MATERIAL_HISTORY_ACCEPT_LEGACY','POC08_MAT_GUARD_LIQUIDITY_HAIRCUT','WOW112_MATERIAL_MEDIUM_HAIRCUT_BPS','DE_GUARD_FALLBACK_VENDOR','de_guard_fallback_vendor']:
    if m not in s: raise SystemExit('missing '+m)
p.write_text(s,encoding='utf-8')
print('[POC08-DE-HISTORY-LIQUIDITY-V2] PASS')
