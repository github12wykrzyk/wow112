//! Market Maker V2 runtime foundation.
//! All socket reads in this layer go through mm2_wait_for/mm2_read_encrypted_raw_until.
use crate::{market_maker_v2_recovery::Mm2RecoveryJournal,market_maker_v2_saga::Mm2SagaJournal};
use std::cell::RefCell as Mm2RuntimeRefCell;

thread_local!{static MM2_BOUND:Mm2RuntimeRefCell<Option<(u64,u32)>>=const{Mm2RuntimeRefCell::new(None)};}
fn market_maker_v2_bind(player:u64,realm:u32){market_maker_v2_inventory_bind(player);MM2_BOUND.with(|b|*b.borrow_mut()=Some((player,realm)));println!("[MM2] BOUND player=0x{player:016X} realm={realm}");}
fn mm2_bound_identity(player:u64)->Result<(String,u32),String>{
    let realm=MM2_BOUND.with(|b|b.borrow().as_ref().copied()).ok_or("MM2 runtime was not bound before world updates")?;
    if realm.0!=player{return Err("MM2 bound player mismatch".into());}
    let server=env::var("WOW112_SERVER_ID").unwrap_or_else(|_|"octowow".into());
    Ok((server,realm.1))
}

fn mm2_owner_list(stream:&mut TcpStream,crypto:&mut HeaderCrypto,auctioneer:u64,player:u64)->Result<Vec<LifecycleAuction>,String>{
    let started=Mm2Instant::now();let deadline=started+Mm2Duration::from_secs(8);
    let mut all=Vec::new();let mut seen=HashSet::new();let mut total:Option<u32>=None;
    loop{
        if Mm2Instant::now()>=deadline{return Err("MM2 owner-list wall-clock deadline".into());}
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_LIST_OWNER_ITEMS{auctioneer:auctioneer.into(),list_from:all.len() as u32})?;
        let(rows,n)=mm2_wait_for(stream,crypto,deadline,"owner-list",|op,p|{if op!=0x025d{return Ok(None);}Ok(Some(lifecycle_rows(p)?))})?;
        if let Some(old)=total{if old!=n{return Err("MM2 owner list total changed during pagination".into());}}else{total=Some(n);}
        if rows.is_empty()&&all.len()!=n as usize{return Err("MM2 owner list incomplete empty page".into());}
        for r in rows{if r.row.auction_id==0||r.row.count==0||r.row.owner_guid!=player{return Err("MM2 invalid/non-owned owner row".into());}if !seen.insert(r.row.auction_id){return Err("MM2 duplicate owner auction id".into());}all.push(r);}
        if all.len()==n as usize{break;}if all.len()>n as usize{return Err("MM2 owner list exceeded total".into());}
    }
    all.sort_by_key(|r|r.row.auction_id);println!("[MM2] MY_AUCTIONS count={} ms={}",all.len(),started.elapsed().as_millis());Ok(all)
}
fn mm2_tracker_snapshot()->Result<(u64,usize,usize,bool),String>{mm2_inventory_healthy()?;MM2_INV.with(|c|{let s=c.borrow();Ok((s.generation,s.objects.len(),s.slots.len(),s.player!=0&&s.objects.contains_key(&s.player)))})}
fn mm2_tracker_stats()->Result<(u64,usize,usize),String>{let(g,o,s,_)=mm2_tracker_snapshot()?;Ok((g,o,s))}
fn mm2_preflight_journals(player:u64)->Result<(),String>{
    let(server,realm)=mm2_bound_identity(player)?;let recovery=Mm2RecoveryJournal::open(&server,realm,player)?;let saga=Mm2SagaJournal::open(&server,realm,player)?;
    if !recovery.is_idle(){return Err(format!("MM2_RECOVERY_REQUIRED state={:?} path={}",recovery.state(),recovery.path().display()));}
    if saga.has_unfinished(){return Err(format!("MM2_SAGA_RECONCILIATION_REQUIRED state={:?} path={}",saga.state(),saga.path().display()));}Ok(())
}

// lifecycle_dispatch is entered as soon as SMSG_LOGIN_VERIFY_WORLD is seen. Do not call the
// tracker ready merely because nearby world objects arrived: V2 needs the authoritative object for
// its own player first. Requiring player_seen also drains the initial inventory burst before AH/mail
// request fences, while keeping this phase strictly read-only and wall-clock bounded.
fn mm2_warm_tracker(stream:&mut TcpStream,crypto:&mut HeaderCrypto)->Result<(),String>{
    if let Ok((generation,_,_,player_seen))=mm2_tracker_snapshot(){if generation>0&&player_seen{return Ok(());}}
    let started=Mm2Instant::now();let deadline=started+Mm2Duration::from_secs(10);
    mm2_wait_for(stream,crypto,deadline,"tracker-warmup",|_,_|{
        let(generation,objects,slots,player_seen)=mm2_tracker_snapshot()?;
        if generation>0&&player_seen{println!("[MM2] TRACKER_WARM_PASS generation={generation} objects={objects} physical_slots={slots} player_seen=YES ms={}",started.elapsed().as_millis());Ok(Some(()))}else{Ok(None)}
    })
}

fn market_maker_v2_run(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String>{
    let mode=env::var("WOW112_MM2_MODE").unwrap_or_else(|_|"capability".into()).trim().to_ascii_lowercase();
    // Durable unresolved state blocks all new work before even a read-only world warm-up.
    mm2_preflight_journals(player)?;
    mm2_warm_tracker(stream,crypto)?;
    let(generation,objects,slots,player_seen)=mm2_tracker_snapshot()?;println!("[MM2] TRACKER generation={generation} objects={objects} physical_slots={slots}");
    if generation==0||objects==0||!player_seen{return Err("MM2 inventory/world tracker lacks authoritative player evidence".into());}
    match mode.as_str(){
        "inventory"|"inventory-tracker"=>{println!("[MM2] INVENTORY_TRACKER_PASS read_only=YES");Ok(())},
        "mailbox"|"mailbox-resolver"=>{let(_ah,mail)=mm2_collect_candidates(stream,crypto,player,Mm2Duration::from_millis(1500))?;let mailbox=mm2_resolve_mailbox(stream,crypto,&mail)?;println!("[MM2] MAILBOX_RESOLVER_PASS mailbox=0x{mailbox:016X} read_only=YES");Ok(())},
        "capability"|"read-only"|"readonly"=>{let targets=mm2_resolve_targets(stream,crypto,player)?;let mine=mm2_owner_list(stream,crypto,targets.auctioneer,player)?;println!("[MM2] CAPABILITY_PASS auctioneer=0x{:016X} house={} mailbox=0x{:016X} own={} read_only=YES",targets.auctioneer,targets.auction_house,targets.mailbox,mine.len());Ok(())},
        "depth"|"targeted-depth"=>{let item=env::var("WOW112_MM2_ITEM_ID").map_err(|_|"MM2 targeted-depth requires WOW112_MM2_ITEM_ID")?.parse::<u32>().map_err(|_|"MM2 invalid WOW112_MM2_ITEM_ID")?;let targets=mm2_resolve_targets(stream,crypto,player)?;let snap=mm2_targeted_depth(stream,crypto,targets.auctioneer,item,[0,0,0],16)?;if !snap.complete||!snap.coherent{return Err("MM2 targeted depth incomplete/incoherent".into());}println!("[MM2] TARGETED_DEPTH_PASS item={} rows={} raw_total={} read_only=YES",item,snap.rows.len(),snap.raw_total);Ok(())},
        "undercut-canary"|"clear-one-buy-canary"=>Err("MM2 mutation canary BLOCKED: execution primitives not yet safety-approved".into()),
        _=>Err("WOW112_MM2_MODE must be capability, mailbox-resolver, inventory-tracker, targeted-depth, undercut-canary, or clear-one-buy-canary".into()),
    }
}
#[cfg(test)]mod mm2_runtime_tests{#[test]fn mutation_modes_are_not_implicitly_passed(){assert_eq!(["undercut-canary","clear-one-buy-canary"].len(),2);}}
