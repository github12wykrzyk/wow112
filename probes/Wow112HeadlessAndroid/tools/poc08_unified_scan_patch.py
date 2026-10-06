from pathlib import Path
import sys
if len(sys.argv)!=3: raise SystemExit('usage: INPUT OUTPUT')
s=Path(sys.argv[1]).read_text(encoding='utf-8')
def rep(a,b,label):
 n=s.count(a)
 if n!=1: raise SystemExit(f'{label}: expected1 got{n}')
 return s.replace(a,b,1)
marker='\n\nfn poc07_de_export_candidates_v5(candidates: &[Poc07Candidate]) -> Result<String, String> {'
helper=r'''

fn poc08_full_ah_scan(stream:&mut TcpStream,crypto:&mut HeaderCrypto,auctioneer_guid:u64,auction_house:u32,max_pages:u32)->Result<Vec<(u32,Poc06AuctionRecord)>,String>{
    if max_pages==0||max_pages>4096{return Err(format!("WOW112_AH_FULL_SCAN_MAX_PAGES must be 1..4096, got {max_pages}"));}
    let started=std::time::Instant::now();
    let mut out=Vec::<(u32,Poc06AuctionRecord)>::new();
    let mut seen=HashSet::<u32>::new();
    let mut dup=0usize;
    for page in 0..max_pages{
        let records=poc07_request_auction_page(stream,crypto,auctioneer_guid,auction_house,page,"poc08-unified-full-ah")?;
        let n=records.len();
        for r in records{if seen.insert(r.auction_id){out.push((page,r));}else{dup+=1;}}
        if page<8||(page+1)%50==0||n<50{let e=started.elapsed().as_secs_f64().max(0.001);println!("[POC08-UNIFIED-SCAN] progress pages={} unique_records={} duplicates={} last_page_records={} pages_per_s={:.2}",page+1,out.len(),dup,n,(page+1) as f64/e);}
        if n<50{println!("[POC08-UNIFIED-SCAN] FULL AH PASS pages={} unique_records={} duplicates={} source=ALL_CLASSES_ALL_QUALITIES_ALL_STACKS",page+1,out.len(),dup);return Ok(out);}
    }
    Err(format!("POC08_UNIFIED_FULL_AH_TRUNCATED fail-closed max_pages={max_pages}"))
}
'''
if s.count(marker)!=1: raise SystemExit('scan insert marker')
s=s.replace(marker,helper+marker,1)
old='''    let filter_max_pages = poc07_env_u32_default("WOW112_DE_FILTER_MAX_PAGES", 256)?;\n    let item_query_window = poc07_env_u32_default("WOW112_DE_ITEM_QUERY_WINDOW", 32)? as usize;\n    if net_bps == 0 || net_bps > 10_000 { return Err(format!("WOW112_DE_NET_BPS must be 1..10000, got {net_bps}")); }\n    if filter_max_pages == 0 || filter_max_pages > 512 { return Err(format!("WOW112_DE_FILTER_MAX_PAGES must be 1..512, got {filter_max_pages}")); }\n    if item_query_window == 0 || item_query_window > 128 { return Err(format!("WOW112_DE_ITEM_QUERY_WINDOW must be 1..128, got {item_query_window}")); }\n    println!("[POC07-DE-V5.3] mode=ScanOnly source=server-filtered(class=2+4,min_quality=2) max_buyout={max_buyout} min_profit={min_profit} net_bps={net_bps} filter_max_pages={filter_max_pages} item_query_window={item_query_window} de_scope=q2-q3_itemLevel1-65_count1 blacklist={} mutation=DISABLED disenchant_id_gate=OFFLINE_EXTERNAL", blacklist.len());\n    println!("[POC07-DE-V53-TURBO] AH paging=response-paced sleep_ms=0 item_query_window={item_query_window}");'''
new='''    let full_scan_max_pages = poc07_env_u32_default("WOW112_AH_FULL_SCAN_MAX_PAGES", 2048)?;\n    let item_query_window = poc07_env_u32_default("WOW112_DE_ITEM_QUERY_WINDOW", 64)? as usize;\n    if net_bps == 0 || net_bps > 10_000 { return Err(format!("WOW112_DE_NET_BPS must be 1..10000, got {net_bps}")); }\n    if full_scan_max_pages == 0 || full_scan_max_pages > 4096 { return Err(format!("WOW112_AH_FULL_SCAN_MAX_PAGES must be 1..4096, got {full_scan_max_pages}")); }\n    if item_query_window == 0 || item_query_window > 128 { return Err(format!("WOW112_DE_ITEM_QUERY_WINDOW must be 1..128, got {item_query_window}")); }\n    println!("[POC08-UNIFIED] source=FULL_AH_ALL_CLASSES_ALL_QUALITIES_ALL_STACKS max_buyout={max_buyout} full_scan_max_pages={full_scan_max_pages} item_query_window={item_query_window} de_scope=SAFE_COUNT1_ONLY");\n    println!("[POC08-UNIFIED] ordering_assumption=NONE dedupe=AUCTION_ID");'''
s=rep(old,new,'scan config')
a=s.find('    let ceiling = poc07_de_global_ceiling_v4(&mat_prices, net_bps, max_buyout, min_profit)?;\n')
b=s.find('    let item_query_started = std::time::Instant::now();\n',a)
if a<0 or b<0: raise SystemExit('scan block markers')
block=r'''    let scanned=poc08_full_ah_scan(stream,&mut crypto,auctioneer_guid,auction_house,full_scan_max_pages)?;
    println!("[POC08-UNIFIED] FULL AH SNAPSHOT PASS records={} max_buyout_filter={} applied_after_scan=YES",scanned.len(),max_buyout);
    let mut item_ids=scanned.iter().filter_map(|(_,r)|if r.buyout==0||r.buyout>max_buyout||r.count==0||blacklist.contains(&r.item_id){None}else{Some(r.item_id)}).collect::<Vec<_>>();
    item_ids.sort_unstable();item_ids.dedup();
    println!("[POC08-UNIFIED] item template valuation start unique_affordable_items={} vendor_scope=ALL de_scope=MODEL_SUPPORTED",item_ids.len());

'''
s=s[:a]+block+s[b:]
login=s[s.find('pub fn login_poc08_economy_audit('):]
for bad in ['poc07_de_scan_class_v4(stream, &mut crypto','source=server-filtered(class=2+4,min_quality=2)']:
 if bad in login: raise SystemExit('filtered scan remains: '+bad)
for m in ['FULL_AH_ALL_CLASSES_ALL_QUALITIES_ALL_STACKS','POC08_UNIFIED_FULL_AH_TRUNCATED','dedupe=AUCTION_ID']:
 if m not in s: raise SystemExit('missing '+m)
Path(sys.argv[2]).write_text(s,encoding='utf-8')
print('[POC08-UNIFIED-SCAN] PASS')
