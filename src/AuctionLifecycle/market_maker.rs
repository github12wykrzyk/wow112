// Market Maker V1 runtime. Included after adapter.rs + market_maker_inventory.rs.
// Canonical login, auction parser, guarded BUY, Lifecycle CANCEL/MAIL/POST and the
// shared durable mutation coordinator remain authoritative.
use crate::market_maker_policy as mm_policy;

#[derive(Clone,Debug)]
struct MmMarketRow { page:u32, auction:LifecycleAuction }
#[derive(Clone,Debug)]
struct MmSnapshot { rows:Vec<MmMarketRow>, complete:bool, stable:bool, max_total:u32 }

#[derive(Clone,Debug)]
struct MmConfig {
    live:bool,max_pages:u32,max_actions:u32,max_clear_buys:u32,max_post_units:u32,minutes:u32,
    default_floor_unit:u32,floors:std::collections::HashMap<u32,u32>,min_price_bps_of_own:u32,
    ah_cut_bps:u32,max_clear_spend:u32,max_clear_units:u32,clear_min_profit:u32,
    clear_min_roi_bps:u32,clear_min_jump_bps:u32,
}

fn mm_map(name:&str)->Result<std::collections::HashMap<u32,u32>,String>{
    let mut out=std::collections::HashMap::new();
    for tok in env::var(name).unwrap_or_default().split(|c|c==','||c==';') {
        let tok=tok.trim();if tok.is_empty(){continue;}
        let(a,b)=tok.split_once(':').or_else(||tok.split_once('=')).ok_or_else(||format!("invalid {name} token={tok:?}"))?;
        let item=a.trim().parse::<u32>().map_err(|_|format!("invalid {name} item"))?;
        let value=b.trim().parse::<u32>().map_err(|_|format!("invalid {name} value"))?;
        if item==0||value==0{return Err(format!("{name} refuses zero item/value"));}out.insert(item,value);
    } Ok(out)
}
fn mm_config()->Result<MmConfig,String>{
    let mode=env::var("WOW112_MM_MODE").unwrap_or_else(|_|"audit".into()).trim().to_ascii_lowercase();
    let live=match mode.as_str(){"audit"|"scan"|"read-only"=>false,"live"=>true,_=>return Err("WOW112_MM_MODE must be audit or live".into())};
    if live&&(env::var("WOW112_LIFECYCLE_CONFIRM").unwrap_or_default()!="YES"||env::var("WOW112_MM_CONFIRM").unwrap_or_default()!="YES"){return Err("MARKET_MAKER live requires both explicit confirms".into());}
    let c=MmConfig{
        live,max_pages:poc07_env_u32_default("WOW112_MM_MAX_PAGES",4096)?,max_actions:poc07_env_u32_default("WOW112_MM_MAX_ACTIONS",10)?,
        max_clear_buys:poc07_env_u32_default("WOW112_MM_MAX_CLEAR_BUYS",5)?,max_post_units:poc07_env_u32_default("WOW112_MM_MAX_POST_UNITS",20)?,
        minutes:poc07_env_u32_default("WOW112_MM_MINUTES",120)?,default_floor_unit:poc07_env_u32_default("WOW112_MM_DEFAULT_FLOOR_UNIT",1)?,
        floors:mm_map("WOW112_MM_FLOORS")?,min_price_bps_of_own:poc07_env_u32_default("WOW112_MM_MIN_PRICE_BPS_OF_OWN",8000)?,
        ah_cut_bps:poc07_env_u32_default("WOW112_MM_AH_CUT_BPS",500)?,max_clear_spend:poc07_env_u32_default("WOW112_MM_MAX_CLEAR_SPEND",10000)?,
        max_clear_units:poc07_env_u32_default("WOW112_MM_MAX_CLEAR_UNITS",5)?,clear_min_profit:poc07_env_u32_default("WOW112_MM_CLEAR_MIN_PROFIT",100)?,
        clear_min_roi_bps:poc07_env_u32_default("WOW112_MM_CLEAR_MIN_ROI_BPS",1000)?,clear_min_jump_bps:poc07_env_u32_default("WOW112_MM_CLEAR_MIN_JUMP_BPS",1000)?,
    };
    if c.max_pages==0||c.max_pages>4096||c.max_actions==0||c.max_actions>100||c.max_clear_buys==0||c.max_clear_buys>50||c.max_post_units==0||c.max_post_units>200||c.default_floor_unit==0||c.min_price_bps_of_own==0||c.min_price_bps_of_own>10000||c.ah_cut_bps>=10000||c.max_clear_units==0||c.max_clear_units>c.max_post_units||!matches!(c.minutes,120|480|1440){return Err("MARKET_MAKER invalid hard limits".into());}
    Ok(c)
}

fn mm_scan(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,max_pages:u32,label:&str)->Result<MmSnapshot,String>{
    let mut seen=std::collections::HashMap::<u32,MmMarketRow>::new();let mut prior=None;let mut stable=true;let mut max_total=0u32;let mut complete=false;
    for page in 0..max_pages {
        let(rows,total)=lifecycle_market_page(stream,crypto,npc,house,page)?;
        if prior.is_some_and(|x|x!=total){stable=false;}prior=Some(total);max_total=max_total.max(total);
        for auction in rows { if auction.row.auction_id==0||auction.row.count==0{continue;} let r=MmMarketRow{page,auction};
            if let Some(old)=seen.get(&r.auction.row.auction_id){if !lifecycle_same(&old.auction,&r.auction){return Err("MARKET_MAKER conflicting duplicate auction id".into());}}
            else{seen.insert(r.auction.row.auction_id,r);} }
        if (page+1).saturating_mul(50)>=max_total{complete=true;break;}
    }
    let mut rows:Vec<_>=seen.into_values().collect();rows.sort_by(|a,b|a.page.cmp(&b.page).then(a.auction.row.auction_id.cmp(&b.auction.row.auction_id)));
    println!("[MARKET-MAKER] SCAN label={label} rows={} complete={} stable={} total={}",rows.len(),if complete{"YES"}else{"NO"},if stable{"YES"}else{"NO"},max_total);
    Ok(MmSnapshot{rows,complete,stable,max_total})
}
fn mm_same_item(a:&LifecycleAuction,b:&LifecycleAuction)->bool{a.row.item_id==b.row.item_id&&a.signature==b.signature}
fn mm_cmp_unit(a:&LifecycleAuction,b:&LifecycleAuction)->std::cmp::Ordering{
    (u128::from(a.row.buyout)*u128::from(b.row.count)).cmp(&(u128::from(b.row.buyout)*u128::from(a.row.count))).then(a.row.auction_id.cmp(&b.row.auction_id))
}
fn mm_unit_ceil(a:&LifecycleAuction)->u32{if a.row.count==0{u32::MAX}else{((u128::from(a.row.buyout)+u128::from(a.row.count)-1)/u128::from(a.row.count)).min(u128::from(u32::MAX)) as u32}}
fn mm_strict_below(a:&LifecycleAuction)->u32{if a.row.buyout==0||a.row.count==0{0}else{(a.row.buyout-1)/a.row.count}}
fn mm_floor(own:&LifecycleAuction,c:&MmConfig)->u32{c.default_floor_unit.max(*c.floors.get(&own.row.item_id).unwrap_or(&0))}
fn mm_effective_floor(own:&LifecycleAuction,c:&MmConfig)->u32{
    if own.row.count==0{return u32::MAX;}
    let den=u128::from(own.row.count)*10000;
    let pct=((u128::from(own.row.buyout)*u128::from(c.min_price_bps_of_own)+den-1)/den).min(u128::from(u32::MAX)) as u32;
    mm_floor(own,c).max(pct)
}
fn mm_policy_for(own:&LifecycleAuction,player:u64,s:&MmSnapshot,c:&MmConfig)->mm_policy::Decision{
    let competitors:Vec<_>=s.rows.iter().filter(|r|r.auction.row.owner_guid!=player&&r.auction.row.buyout>0&&r.auction.row.count>0&&mm_same_item(own,&r.auction)).map(|r|mm_policy::Quote{auction_id:r.auction.row.auction_id,buyout:r.auction.row.buyout,count:r.auction.row.count}).collect();
    mm_policy::decide(mm_policy::Quote{auction_id:own.row.auction_id,buyout:own.row.buyout,count:own.row.count},&competitors,mm_policy::PolicyConfig{floor_unit:mm_floor(own,c),min_price_bps_of_own:c.min_price_bps_of_own,ah_cut_bps:c.ah_cut_bps,max_clear_spend:c.max_clear_spend,max_clear_units:c.max_clear_units,clear_min_profit:c.clear_min_profit,clear_min_roi_bps:c.clear_min_roi_bps,clear_min_jump_bps:c.clear_min_jump_bps},s.complete&&s.stable)
}
fn mm_print(own:&LifecycleAuction,d:&mm_policy::Decision){println!("[MARKET-MAKER] DECISION own={} item={} count={} buyout={} bid={} => {:?}",own.row.auction_id,own.row.item_id,own.row.count,own.row.buyout,own.row.highest_bid,d);}

fn mm_wait_new_mail(stream:&mut TcpStream,crypto:&mut HeaderCrypto,mailbox:u64,before:&[Poc05MailRecord],item:u32,count:u32)->Result<Poc05MailRecord,String>{
    for _ in 0..8 { let now=poc05_request_mail_list(stream,crypto,mailbox)?;let found:Vec<_>=now.iter().filter(|m|m.cod==0&&m.item==item&&u32::from(m.stack)==count&&!before.iter().any(|b|b.id==m.id)).cloned().collect();
        if found.len()==1{return Ok(found[0].clone());}if found.len()>1{return Err("MARKET_MAKER ambiguous new item mail".into());} }
    Err("MARKET_MAKER expected item mail not observed".into())
}

fn mm_execute_clear_buy(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,mailbox:u64,row:&MmMarketRow)->Result<MmOwnedStack,String>{
    let before=poc05_request_mail_list(stream,crypto,mailbox)?;
    let candidate=Poc07Candidate{page:row.page,record:row.auction.row,strategy:Poc07Strategy::Vendor,unit_value:0,gross_value:0,expected_profit:0};
    // Canonical BUY remains byte-for-byte unchanged. A fresh one-operation guard is
    // scoped to this market-maker step; outer hard caps + a full rescan gate every next BUY.
    let mut one=false;poc07_buy_exact_one(stream,crypto,npc,house,mailbox,candidate,&mut one)?;
    if !one{return Err("MARKET_MAKER canonical BUY returned without commit evidence".into());}
    let mail=mm_wait_new_mail(stream,crypto,mailbox,&before,row.auction.row.item_id,row.auction.row.count)?;
    mm_take_mail_stack(stream,crypto,mailbox,&mail)
}

fn mm_target_for_stock(item:u32,signature:[u32;3],player:u64,s:&MmSnapshot,ceiling:u32,floor:u32)->Result<u32,String>{
    // A partial scan may have missed a cheaper frontier row. Never price/post stock from it.
    // `stable` is intentionally not required here: total-count drift is common on a live AH;
    // a complete pass plus the economic floor is safe, while CLEAR itself remains stable-only.
    if !s.complete{return Err("MARKET_MAKER final pricing snapshot incomplete; stock held, not posted".into());}
    let mut ext:Vec<_>=s.rows.iter().filter(|r|r.auction.row.owner_guid!=player&&r.auction.row.item_id==item&&r.auction.signature==signature&&r.auction.row.buyout>0&&r.auction.row.count>0).collect();
    ext.sort_by(|a,b|mm_cmp_unit(&a.auction,&b.auction));
    let target=ext.first().map(|r|mm_strict_below(&r.auction)).unwrap_or(ceiling).min(ceiling);
    if target==0||target<floor{return Err(format!("MARKET_MAKER target below floor target={target} floor={floor}; stock held, not dumped"));}Ok(target)
}
fn mm_post_units(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,player:u64,item:u32,units:Vec<u64>,target:u32,floor:u32,minutes:u32)->Result<(),String>{
    for guid in units { lifecycle_post(stream,crypto,npc,player,guid,item,1,target,target,floor,minutes)?; }
    Ok(())
}

fn mm_clear_prefix(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,mailbox:u64,player:u64,own_id:u32,c:&MmConfig)->Result<(),String>{
    let mut acquired:Vec<MmOwnedStack>=Vec::new();let mut reference:Option<(u32,[u32;3],u32,u32)>=None;
    let mut spent=0u64;let mut units_bought=0u64;
    for n in 0..c.max_clear_buys {
        if spent>=u64::from(c.max_clear_spend)||units_bought>=u64::from(c.max_clear_units){break;}
        let mine=lifecycle_owner_list(stream,crypto,npc,player)?;let own=match mine.iter().find(|x|x.row.auction_id==own_id){Some(x)=>x.clone(),None=>break};
        if own.row.highest_bid!=0{return Err("MARKET_MAKER clear stopped: own auction acquired a bid".into());}
        if own.signature!=[0,0,0]{return Err("MARKET_MAKER V1 live supports plain-stack market making only".into());}
        reference.get_or_insert((own.row.item_id,own.signature,mm_unit_ceil(&own),mm_effective_floor(&own,c)));
        let mut scoped=c.clone();
        scoped.max_clear_spend=c.max_clear_spend.saturating_sub(spent.min(u64::from(u32::MAX)) as u32);
        scoped.max_clear_units=c.max_clear_units.saturating_sub(units_bought.min(u64::from(u32::MAX)) as u32);
        if scoped.max_clear_spend==0||scoped.max_clear_units==0{break;}
        let snap=mm_scan(stream,crypto,npc,house,c.max_pages,"clear-revalidate")?;let d=mm_policy_for(&own,player,&snap,&scoped);mm_print(&own,&d);
        let ids=match d{mm_policy::Decision::ClearThenRelist{auction_ids,..}=>auction_ids,_=>break};
        let id=*ids.first().ok_or("MARKET_MAKER empty clear plan")?;
        let row=snap.rows.iter().find(|r|r.auction.row.auction_id==id&&r.auction.row.owner_guid!=player&&mm_same_item(&own,&r.auction)).ok_or("MARKET_MAKER clear target vanished before BUY")?.clone();
        let new_spend=spent.saturating_add(u64::from(row.auction.row.buyout));let new_units=units_bought.saturating_add(u64::from(row.auction.row.count));
        if new_spend>u64::from(c.max_clear_spend)||new_units>u64::from(c.max_clear_units){return Err("MARKET_MAKER cumulative clear budget guard".into());}
        println!("[MARKET-MAKER] CLEAR step={} auction={} item={} count={} buyout={} cumulative_spend={} cumulative_units={}",n+1,id,row.auction.row.item_id,row.auction.row.count,row.auction.row.buyout,new_spend,new_units);
        acquired.push(mm_execute_clear_buy(stream,crypto,npc,house,mailbox,&row)?);spent=new_spend;units_bought=new_units;
    }
    if acquired.is_empty(){return Ok(());}let(item,sig,ceiling,floor)=reference.unwrap();
    let fresh=mm_scan(stream,crypto,npc,house,c.max_pages,"clear-post-reprice")?;let target=mm_target_for_stock(item,sig,player,&fresh,ceiling,floor)?;
    println!("[MARKET-MAKER] CLEAR_RELIST acquired_stacks={} spend={} units={} target_unit={} floor={}",acquired.len(),spent,units_bought,target,floor);
    for stack in acquired { let units=mm_split_all_to_units(stream,crypto,stack,c.max_post_units)?;mm_post_units(stream,crypto,npc,player,item,units,target,floor,c.minutes)?; }
    Ok(())
}

fn mm_reprice_one(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,mailbox:u64,player:u64,own:&LifecycleAuction,witness_id:u32,c:&MmConfig)->Result<(),String>{
    if own.row.highest_bid!=0{return Err("MARKET_MAKER cancel blocked by active bid".into());}
    if own.row.count>c.max_post_units{return Err("MARKET_MAKER own stack exceeds guarded split/post limit".into());}
    if own.signature!=[0,0,0]{return Err("MARKET_MAKER V1 live supports plain-stack repricing only".into());}
    let snap=mm_scan(stream,crypto,npc,house,c.max_pages,"reprice-pre-cancel")?;
    let witness=snap.rows.iter().find(|r|r.auction.row.auction_id==witness_id&&r.auction.row.owner_guid!=player&&mm_same_item(own,&r.auction)&&lifecycle_cheaper(own,&r.auction)).ok_or("MARKET_MAKER undercut witness stale")?.clone();
    let before=poc05_request_mail_list(stream,crypto,mailbox)?;let ceiling=mm_unit_ceil(own);let floor=mm_effective_floor(own,c);
    lifecycle_cancel(stream,crypto,npc,house,player,own,(witness.page,witness.auction.clone()))?;
    let mail=mm_wait_new_mail(stream,crypto,mailbox,&before,own.row.item_id,own.row.count)?;let returned=mm_take_mail_stack(stream,crypto,mailbox,&mail)?;
    let units=mm_split_all_to_units(stream,crypto,returned,c.max_post_units)?;
    // Price is recomputed AFTER cancellation/mail/split so a slow return path never posts
    // using the old witness. Own auctions are ignored; we never undercut ourselves.
    let fresh=mm_scan(stream,crypto,npc,house,c.max_pages,"reprice-post-mail")?;let target=mm_target_for_stock(own.row.item_id,own.signature,player,&fresh,ceiling,floor)?;
    println!("[MARKET-MAKER] REPRICE auction={} -> singles={} target_unit={} floor={}",own.row.auction_id,units.len(),target,floor);
    mm_post_units(stream,crypto,npc,player,own.row.item_id,units,target,floor,c.minutes)
}

fn market_maker_run(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String>{
    let c=mm_config()?;let(npcs,mailbox)=discover_poc05_context_retry(stream,crypto,player)?;let(npc,house)=poc05_send_auction_hello_candidates(stream,crypto,npcs)?;
    if !c.live {
        let mine=lifecycle_owner_list(stream,crypto,npc,player)?;let snap=mm_scan(stream,crypto,npc,house,c.max_pages,"audit")?;
        for own in &mine {let d=if own.row.highest_bid!=0{mm_policy::Decision::Keep}else{mm_policy_for(own,player,&snap,&c)};mm_print(own,&d);}println!("[MARKET-MAKER] AUDIT PASS own={} mutation=DISABLED",mine.len());return Ok(());
    }
    for action in 0..c.max_actions {
        let mine=lifecycle_owner_list(stream,crypto,npc,player)?;if mine.is_empty(){println!("[MARKET-MAKER] LIVE PASS no-owned-auctions");return Ok(());}let snap=mm_scan(stream,crypto,npc,house,c.max_pages,"live-select")?;
        let mut chosen:Option<(LifecycleAuction,mm_policy::Decision)>=None;
        for own in &mine {if own.row.highest_bid!=0{continue;}let d=mm_policy_for(own,player,&snap,&c);mm_print(own,&d);if matches!(d,mm_policy::Decision::ClearThenRelist{..}){chosen=Some((own.clone(),d));break;}if chosen.is_none()&&matches!(d,mm_policy::Decision::Undercut{..}){chosen=Some((own.clone(),d));}}
        let Some((own,d))=chosen else{println!("[MARKET-MAKER] LIVE PASS no-actionable-auctions actions={action}");return Ok(());};
        match d {
            mm_policy::Decision::ClearThenRelist{..}=>mm_clear_prefix(stream,crypto,npc,house,mailbox,player,own.row.auction_id,&c)?,
            mm_policy::Decision::Undercut{witness_auction_id,..}=>mm_reprice_one(stream,crypto,npc,house,mailbox,player,&own,witness_auction_id,&c)?,
            _=>{}
        }
    }
    println!("[MARKET-MAKER] ACTION_LIMIT_REACHED no_retry=YES");Ok(())
}

fn lifecycle_dispatch(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String>{
    if env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default()=="marketmaker"{market_maker_run(stream,crypto,player)}else{lifecycle_run(stream,crypto,player)}
}
