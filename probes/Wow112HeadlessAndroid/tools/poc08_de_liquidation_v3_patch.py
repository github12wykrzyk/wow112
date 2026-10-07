from pathlib import Path
import sys
if len(sys.argv)!=2:
    raise SystemExit('usage: UNIFIED_RS')
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

def rep(old,new,label):
    global s
    n=s.count(old)
    if n!=1:
        raise SystemExit(f'{label}: expected 1 got {n}')
    s=s.replace(old,new,1)

rep('''    guard_flags: u32,\n}''','''    guard_flags: u32,\n    self_listing_count: u32,\n    self_unit_count: u64,\n    self_lowest: u32,\n    market_total_units: u64,\n    depth_5_units: u64,\n    depth_10_units: u64,\n    depth_20_units: u64,\n    price_p25: u32,\n    price_median: u32,\n    own_share_bps: u32,\n    exposure_factor_bps: u32,\n    saturation_factor_bps: u32,\n}''','material point fields')

rep('''const POC08_MAT_GUARD_LIQUIDITY_HAIRCUT: u32 = 1 << 6;''','''const POC08_MAT_GUARD_LIQUIDITY_HAIRCUT: u32 = 1 << 6;\nconst POC08_MAT_GUARD_OWN_EXPOSURE: u32 = 1 << 7;\nconst POC08_MAT_GUARD_OWN_EXPOSURE_BLOCK: u32 = 1 << 8;\nconst POC08_MAT_GUARD_MARKET_SATURATION: u32 = 1 << 9;\nconst POC08_MAT_GUARD_OWN_AT_FLOOR: u32 = 1 << 10;''','v3 guard consts')

rep('''    if flags & POC08_MAT_GUARD_LIQUIDITY_HAIRCUT != 0 { out.push("LIQUIDITY_HAIRCUT"); }\n    if out.is_empty()''','''    if flags & POC08_MAT_GUARD_LIQUIDITY_HAIRCUT != 0 { out.push("LIQUIDITY_HAIRCUT"); }\n    if flags & POC08_MAT_GUARD_OWN_EXPOSURE != 0 { out.push("OWN_EXPOSURE"); }\n    if flags & POC08_MAT_GUARD_OWN_EXPOSURE_BLOCK != 0 { out.push("OWN_EXPOSURE_BLOCK"); }\n    if flags & POC08_MAT_GUARD_MARKET_SATURATION != 0 { out.push("MARKET_SATURATION"); }\n    if flags & POC08_MAT_GUARD_OWN_AT_FLOOR != 0 { out.push("OWN_AT_FLOOR"); }\n    if out.is_empty()''','v3 guard names')

append_start=s.index('fn poc08_append_material_history(')
collect_start=s.index('fn poc08_collect_material_pricebook(',append_start)
new_append=r'''fn poc08_append_material_history(
    path: &str,
    points: &[Poc08MaterialBookPoint],
) -> Result<(), String> {
    use std::io::Write as _;
    let exists_nonempty = std::fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false);
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("POC08 material history open failed path={path:?}: {e}"))?;
    if !exists_nonempty {
        // First nine columns intentionally preserve V2 compatibility.
        writeln!(file, "unix_s,item_id,raw_lowest,listing_count,unit_count,safe_price,confidence,unique_sellers,guard_flags,self_listing_count,self_unit_count,self_lowest,market_total_units,depth_5_units,depth_10_units,depth_20_units,price_p25,price_median,own_share_bps,exposure_factor_bps,saturation_factor_bps")
            .map_err(|e| format!("POC08 material history header failed: {e}"))?;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    for p in points {
        writeln!(
            file,
            "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
            now, p.item_id, p.raw_lowest, p.listing_count, p.unit_count, p.safe_price,
            poc08_material_confidence_name(p.confidence), p.unique_sellers,
            poc08_guard_flags_name(p.guard_flags), p.self_listing_count, p.self_unit_count,
            p.self_lowest, p.market_total_units, p.depth_5_units, p.depth_10_units,
            p.depth_20_units, p.price_p25, p.price_median, p.own_share_bps,
            p.exposure_factor_bps, p.saturation_factor_bps,
        ).map_err(|e| format!("POC08 material history append failed: {e}"))?;
    }
    Ok(())
}

fn poc08_weighted_price_at_bps(rows: &[(u32,u32)], bps: u32) -> u32 {
    if rows.is_empty() { return 0; }
    let total = rows.iter().fold(0u64, |a,(_,n)| a.saturating_add(u64::from(*n)));
    if total == 0 { return 0; }
    let target = (total.saturating_mul(u64::from(bps)).saturating_add(9_999) / 10_000).max(1);
    let mut cumulative=0u64;
    for (price,count) in rows.iter().copied() {
        cumulative=cumulative.saturating_add(u64::from(count));
        if cumulative>=target { return price; }
    }
    rows.last().map(|x|x.0).unwrap_or(0)
}

fn poc08_units_within_bps(rows:&[(u32,u32)], floor:u32, premium_bps:u32)->u64{
    if floor==0{return 0;}
    let cap=(u64::from(floor).saturating_mul(u64::from(10_000u32.saturating_add(premium_bps)))/10_000)
        .min(u64::from(u32::MAX)) as u32;
    rows.iter().filter(|(p,_)|*p<=cap).fold(0u64,|a,(_,n)|a.saturating_add(u64::from(*n)))
}

fn poc08_supply_factor_bps(external_units:u64,depth_10_units:u64)->u32{
    if external_units==0{return 0;}
    let absolute = if external_units>=500{8_500}else if external_units>=250{9_000}else if external_units>=100{9_500}else if external_units>=50{9_750}else{10_000};
    let depth_share=(depth_10_units.saturating_mul(10_000)/external_units).min(10_000) as u32;
    let clustered=if depth_share>=8_000{9_000}else if depth_share>=6_000{9_500}else if depth_share>=3_000{9_750}else{10_000};
    ((u64::from(absolute)*u64::from(clustered)/10_000).max(8_000).min(10_000)) as u32
}

fn poc08_exposure_factor_bps(self_units:u64,external_units:u64,floor_bps:u32)->(u32,u32){
    if self_units==0{return(0,10_000);}
    let total=self_units.saturating_add(external_units).max(1);
    let share=(self_units.saturating_mul(10_000)/total).min(10_000) as u32;
    let factor=10_000u32.saturating_sub(share/2).max(floor_bps.min(10_000));
    (share,factor)
}

'''
s=s[:append_start]+new_append+s[collect_start:]

collect_start=s.index('fn poc08_collect_material_pricebook(')
collect_end=s.index('\nfn poc08_safe_ev_from_outcomes(',collect_start)
new_collect=r'''fn poc08_collect_material_pricebook(
    scanned: &[(u32,Poc06AuctionRecord)],
    player_guid: u64,
) -> Result<(
    std::collections::HashMap<u32, u32>,
    std::collections::HashMap<u32, u32>,
    std::collections::HashMap<u32, u8>,
), String> {
    let history_path = env::var("WOW112_MATERIAL_HISTORY_PATH")
        .unwrap_or_else(|_| "POC08_MATERIAL_HISTORY.csv".to_string());
    let history = poc08_load_material_history(&history_path);
    let medium_haircut_bps = poc07_env_u32_default("WOW112_MATERIAL_MEDIUM_HAIRCUT_BPS", 8_500)?;
    let exposure_floor_bps = poc07_env_u32_default("WOW112_MATERIAL_OWN_EXPOSURE_FLOOR_BPS", 6_500)?;
    let own_share_block_bps = poc07_env_u32_default("WOW112_MATERIAL_OWN_SHARE_BLOCK_BPS", 7_500)?;
    let own_units_block_min = u64::from(poc07_env_u32_default("WOW112_MATERIAL_OWN_UNITS_BLOCK_MIN", 10)?);
    if medium_haircut_bps > 10_000 || exposure_floor_bps > 10_000 || own_share_block_bps > 10_000 {
        return Err("material liquidation BPS configs must be <=10000".to_string());
    }
    let overrides = poc07_parse_value_map("WOW112_DE_MAT_VALUES")?;
    let mut raw_prices = std::collections::HashMap::<u32, u32>::new();
    let mut safe_prices = std::collections::HashMap::<u32, u32>::new();
    let mut confidence = std::collections::HashMap::<u32, u8>::new();
    let mut points = Vec::<Poc08MaterialBookPoint>::new();

    println!("[POC08-C-LIQUIDATION-V3] START source=SAME_FULL_AH_SNAPSHOT materials={} snapshot_records={} own_owner_guid=0x{:016X} exposure_floor_bps={} own_share_block_bps={} own_units_block_min={}",
        POC07_DE_MATERIALS_V4.len(),scanned.len(),player_guid,exposure_floor_bps,own_share_block_bps,own_units_block_min);

    for (material_id, _english_name) in POC07_DE_MATERIALS_V4.iter().copied() {
        if let Some(value) = overrides.get(&material_id).copied() {
            raw_prices.insert(material_id, value); safe_prices.insert(material_id, value); confidence.insert(material_id, 3);
            points.push(Poc08MaterialBookPoint{item_id:material_id,raw_lowest:value,safe_price:value,listing_count:0,unit_count:0,unique_sellers:0,history_count:0,history_median:0,confidence:3,guard_flags:0,self_listing_count:0,self_unit_count:0,self_lowest:0,market_total_units:0,depth_5_units:0,depth_10_units:0,depth_20_units:0,price_p25:0,price_median:0,own_share_bps:0,exposure_factor_bps:10_000,saturation_factor_bps:10_000});
            println!("[POC08-C-LIQUIDATION-V3] OVERRIDE item_id={} value={} confidence=HIGH",material_id,value);
            continue;
        }

        let mut rows=Vec::<(u32,u32)>::new();
        let mut self_prices=Vec::<u32>::new();
        let mut seller_guids=HashSet::<u64>::new();
        let mut listing_count=0u32; let mut unit_count=0u64;
        let mut self_listing_count=0u32; let mut self_unit_count=0u64;
        for (_,record) in scanned.iter() {
            if record.item_id!=material_id || record.buyout==0 || record.count==0 {continue;}
            let unit=(u64::from(record.buyout)/u64::from(record.count)).min(u64::from(u32::MAX)) as u32;
            if unit==0{continue;}
            if record.owner_guid==player_guid {
                self_listing_count=self_listing_count.saturating_add(1);
                self_unit_count=self_unit_count.saturating_add(u64::from(record.count));
                self_prices.push(unit);
            } else {
                rows.push((unit,record.count));
                listing_count=listing_count.saturating_add(1);
                unit_count=unit_count.saturating_add(u64::from(record.count));
                if record.owner_guid!=0{seller_guids.insert(record.owner_guid);}
            }
        }
        rows.sort_unstable_by_key(|x|x.0); self_prices.sort_unstable();
        let raw_lowest=rows.first().map(|x|x.0).unwrap_or(0);
        let self_lowest=self_prices.first().copied().unwrap_or(0);
        let price_p25=poc08_weighted_price_at_bps(&rows,2_500);
        let price_median=poc08_weighted_price_at_bps(&rows,5_000);
        let depth_5_units=poc08_units_within_bps(&rows,raw_lowest,500);
        let depth_10_units=poc08_units_within_bps(&rows,raw_lowest,1_000);
        let depth_20_units=poc08_units_within_bps(&rows,raw_lowest,2_000);
        let market_total_units=unit_count.saturating_add(self_unit_count);
        let unique_sellers=seller_guids.len();

        let mut hist=history.get(&material_id).cloned().unwrap_or_default();
        let history_count=hist.len(); let history_median=poc08_median_u32(&mut hist);
        let depth_conf=if listing_count>=5&&unit_count>=10&&unique_sellers>=3{3u8}else if listing_count>=2&&unit_count>=3&&unique_sellers>=2{2u8}else if listing_count>=1{1u8}else{0u8};
        let effective_conf=if raw_lowest==0{0u8}else if depth_conf>=2{depth_conf}else if history_count>=3&&history_median>0{2u8}else{depth_conf};
        let mut guard_flags=0u32;
        if unique_sellers<2&&raw_lowest>0{guard_flags|=POC08_MAT_GUARD_THIN_SELLERS;}
        if history_count<3&&raw_lowest>0{guard_flags|=POC08_MAT_GUARD_COLD_START;}
        let mut safe_price=if effective_conf>=2{raw_lowest}else{0};
        let mut final_conf=effective_conf;

        if safe_price>0&&history_count>=3&&history_median>0{
            let history_cap=(u64::from(history_median).saturating_mul(120)/100).min(u64::from(u32::MAX)) as u32;
            if safe_price>history_cap{safe_price=history_cap;guard_flags|=POC08_MAT_GUARD_HISTORY_CAP;final_conf=final_conf.min(2);}
            let spike_block=(u64::from(history_median).saturating_mul(150)/100).min(u64::from(u32::MAX)) as u32;
            if raw_lowest>spike_block{guard_flags|=POC08_MAT_GUARD_SPIKE_BLOCK;final_conf=final_conf.min(1);}
        }
        if safe_price>0&&history_count<3{safe_price=(u64::from(safe_price)*7000/10_000).min(u64::from(u32::MAX)) as u32;final_conf=final_conf.min(2);}
        if safe_price>0&&history_count>=3&&final_conf==2&&medium_haircut_bps<10_000{safe_price=(u64::from(safe_price)*u64::from(medium_haircut_bps)/10_000).min(u64::from(u32::MAX)) as u32;guard_flags|=POC08_MAT_GUARD_LIQUIDITY_HAIRCUT;}

        let (own_share_bps,mut exposure_factor_bps)=poc08_exposure_factor_bps(self_unit_count,unit_count,exposure_floor_bps);
        if self_unit_count>0{guard_flags|=POC08_MAT_GUARD_OWN_EXPOSURE;}
        if self_lowest>0&&raw_lowest>0&&self_lowest<=raw_lowest{
            exposure_factor_bps=((u64::from(exposure_factor_bps)*9_500)/10_000) as u32;
            guard_flags|=POC08_MAT_GUARD_OWN_AT_FLOOR;
        }
        let saturation_factor_bps=poc08_supply_factor_bps(unit_count,depth_10_units);
        if saturation_factor_bps<10_000{guard_flags|=POC08_MAT_GUARD_MARKET_SATURATION;}
        if safe_price>0{
            safe_price=(u64::from(safe_price).saturating_mul(u64::from(exposure_factor_bps))/10_000)
                .saturating_mul(u64::from(saturation_factor_bps))/10_000;
            safe_price=safe_price.min(u64::from(u32::MAX)) as u32;
        }
        if self_unit_count>=own_units_block_min&&own_share_bps>=own_share_block_bps&&raw_lowest>0{
            guard_flags|=POC08_MAT_GUARD_OWN_EXPOSURE_BLOCK;
            final_conf=final_conf.min(1);
        }

        if raw_lowest>0{raw_prices.insert(material_id,raw_lowest);}
        if safe_price>0{safe_prices.insert(material_id,safe_price);}
        confidence.insert(material_id,final_conf);
        points.push(Poc08MaterialBookPoint{item_id:material_id,raw_lowest,safe_price,listing_count,unit_count,unique_sellers,history_count,history_median,confidence:final_conf,guard_flags,self_listing_count,self_unit_count,self_lowest,market_total_units,depth_5_units,depth_10_units,depth_20_units,price_p25,price_median,own_share_bps,exposure_factor_bps,saturation_factor_bps});
        println!("[POC08-C-LIQUIDATION-V3] item_id={} raw={} safe={} ext_listings={} ext_units={} sellers={} self_listings={} self_units={} self_lowest={} total_units={} depth5={} depth10={} depth20={} p25={} median={} own_share_bps={} exposure_factor_bps={} saturation_factor_bps={} history_n={} history_median={} confidence={} guards={}",material_id,raw_lowest,safe_price,listing_count,unit_count,unique_sellers,self_listing_count,self_unit_count,self_lowest,market_total_units,depth_5_units,depth_10_units,depth_20_units,price_p25,price_median,own_share_bps,exposure_factor_bps,saturation_factor_bps,history_count,history_median,poc08_material_confidence_name(final_conf),poc08_guard_flags_name(guard_flags));
    }

    // Same 3:1 essence parity circuit breaker as V2, applied after portfolio/liquidity haircuts.
    for &(lesser_id,greater_id) in POC08_ESSENCE_PARITY_PAIRS{
        let raw_lesser=raw_prices.get(&lesser_id).copied().unwrap_or(0); let raw_greater=raw_prices.get(&greater_id).copied().unwrap_or(0);
        let lesser_cap=if raw_greater>0{raw_greater/3}else{0};
        let greater_cap=if raw_lesser>0{u64::from(raw_lesser).saturating_mul(3).min(u64::from(u32::MAX)) as u32}else{0};
        for(item_id,cap)in[(lesser_id,lesser_cap),(greater_id,greater_cap)]{
            if cap==0{continue;}
            let Some(point)=points.iter_mut().find(|p|p.item_id==item_id)else{continue;};
            if point.safe_price==0||point.safe_price<=cap{continue;}
            let before=point.safe_price;point.safe_price=cap;point.guard_flags|=POC08_MAT_GUARD_PARITY_CAP;
            if u64::from(before).saturating_mul(100)>u64::from(cap).saturating_mul(125){point.guard_flags|=POC08_MAT_GUARD_PARITY_BLOCK;point.confidence=point.confidence.min(1);}else{point.confidence=point.confidence.min(2);}
            safe_prices.insert(item_id,point.safe_price);confidence.insert(item_id,point.confidence);
            println!("[POC08-C-PARITY] item_id={} before={} cap={} after={} confidence={} guards={}",item_id,before,cap,point.safe_price,poc08_material_confidence_name(point.confidence),poc08_guard_flags_name(point.guard_flags));
        }
    }

    let export_path=env::var("WOW112_MATERIAL_BOOK_EXPORT").unwrap_or_else(|_|"POC08_MATERIAL_BOOK.csv".to_string());
    let mut csv=String::from("item_id,raw_lowest,safe_price,listing_count,unit_count,unique_sellers,history_count,history_median,confidence,guard_flags,self_listing_count,self_unit_count,self_lowest,market_total_units,depth_5_units,depth_10_units,depth_20_units,price_p25,price_median,own_share_bps,exposure_factor_bps,saturation_factor_bps\n");
    for p in points.iter(){csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\n",p.item_id,p.raw_lowest,p.safe_price,p.listing_count,p.unit_count,p.unique_sellers,p.history_count,p.history_median,poc08_material_confidence_name(p.confidence),poc08_guard_flags_name(p.guard_flags),p.self_listing_count,p.self_unit_count,p.self_lowest,p.market_total_units,p.depth_5_units,p.depth_10_units,p.depth_20_units,p.price_p25,p.price_median,p.own_share_bps,p.exposure_factor_bps,p.saturation_factor_bps));}
    std::fs::write(&export_path,csv.as_bytes()).map_err(|e|format!("POC08 material book export failed path={export_path:?}: {e}"))?;
    poc08_append_material_history(&history_path,&points)?;
    println!("[POC08-C-LIQUIDATION-V3] PASS raw_coverage={}/{} safe_coverage={}/{} export={:?} history={:?} source=SAME_FULL_AH_SNAPSHOT",raw_prices.len(),POC07_DE_MATERIALS_V4.len(),safe_prices.len(),POC07_DE_MATERIALS_V4.len(),export_path,history_path);
    Ok((raw_prices,safe_prices,confidence))
}
'''
s=s[:collect_start]+new_collect+s[collect_end:]

old='''    let (mat_prices, safe_mat_prices, material_confidence) = poc08_collect_material_pricebook(\n        stream, &mut crypto, auctioneer_guid, auction_house, player_guid\n    )?;\n    let scanned=poc08_full_ah_scan(stream,&mut crypto,auctioneer_guid,auction_house,full_scan_max_pages)?;\n    println!("[POC08-UNIFIED] FULL AH SNAPSHOT PASS records={} max_buyout_filter={} applied_after_scan=YES",scanned.len(),max_buyout);'''
new='''    let scanned=poc08_full_ah_scan(stream,&mut crypto,auctioneer_guid,auction_house,full_scan_max_pages)?;\n    println!("[POC08-UNIFIED] FULL AH SNAPSHOT PASS records={} max_buyout_filter={} applied_after_scan=YES",scanned.len(),max_buyout);\n    let (mat_prices, safe_mat_prices, material_confidence) = poc08_collect_material_pricebook(&scanned, player_guid)?;'''
rep(old,new,'scan then liquidation book')

rep('''println!("[POC08-C] MATERIAL PRICE MODEL source=DEPTH+HISTORY raw_for_discovery safe_for_decision own_listings_excluded=YES autobuy=DISABLED");''','''println!("[POC08-C] MATERIAL PRICE MODEL source=SAME_FULL_AH_SNAPSHOT+DEPTH+HISTORY+OWN_EXPOSURE raw_for_discovery liquidation_safe_for_decision own_listings=WEIGHTED_NOT_VALUED autobuy=DISABLED");''','model log')

for m in ['POC08-C-LIQUIDATION-V3','OWN_EXPOSURE_BLOCK','WOW112_MATERIAL_OWN_SHARE_BLOCK_BPS','self_unit_count','depth_10_units','saturation_factor_bps','SAME_FULL_AH_SNAPSHOT']:
    if m not in s: raise SystemExit('missing marker '+m)
p.write_text(s,encoding='utf-8')
print('[POC08-DE-LIQUIDATION-V3] PASS')
