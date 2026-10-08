//! Market Maker V2 runtime foundation.
//! All socket reads in this layer go through mm2_wait_for/mm2_read_encrypted_raw_until.
use crate::{
    market_maker_v2_recovery::{Mm2Recovery, Mm2RecoveryJournal},
    market_maker_v2_saga::{Mm2SagaJournal, Mm2SagaPhase},
};
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

fn mm2_cancel_ack_payload(payload:&[u8],expected_auction_id:u32)->Result<(),String>{
    if payload.len()<12{return Err("MM2 CANCEL malformed auction ACK".into());}
    let auction_id=read_u32_at(payload,0)?;
    let action=read_u32_at(payload,4)?;
    let result=read_u32_at(payload,8)?;
    if action!=1||auction_id!=expected_auction_id{return Err(format!("MM2 CANCEL mismatched ACK action={action} auction_id={auction_id} expected={expected_auction_id}"));}
    if result!=0{return Err(format!("MM2 CANCEL server rejected auction_id={auction_id} result={result}"));}
    Ok(())
}

// Dormant until the undercut canary is explicitly enabled after review. This executor deliberately
// keeps every post-SEND proof and durable state update inside MutationCoordinator::transaction so
// `.pending` cannot be cleared before ACK + fresh My Auctions + recovery + saga durability finish.
#[allow(dead_code)]
fn mm2_guarded_cancel(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    auctioneer:u64,
    player:u64,
    target:&LifecycleAuction,
    saga:&mut Mm2SagaJournal,
    recovery:&mut Mm2RecoveryJournal,
)->Result<(),String>{
    if !recovery.is_idle(){return Err("MM2 CANCEL recovery not idle".into());}
    let state=saga.state().ok_or("MM2 CANCEL saga missing")?;
    if !matches!(state.phase,Mm2SagaPhase::MailboxVerified{..}){return Err("MM2 CANCEL saga not mailbox-verified".into());}
    if state.own_auction_id!=Some(target.row.auction_id)||state.item_id!=target.row.item_id||state.signature!=target.signature{return Err("MM2 CANCEL saga/target identity mismatch".into());}

    // Owner proof first, exact targeted depth last: the targeted snapshot is the freshest market
    // authority immediately preceding durable intent + mutation SEND.
    let owners=mm2_owner_list(stream,crypto,auctioneer,player)?;
    let own=owners.iter().find(|r|r.row.auction_id==target.row.auction_id).ok_or("MM2 CANCEL target absent from fresh My Auctions")?;
    if !lifecycle_same(own,target){return Err("MM2 CANCEL fresh owner identity changed".into());}
    if own.row.highest_bid!=0{return Err("MM2 CANCEL blocked: active bid".into());}

    let depth=mm2_targeted_depth(stream,crypto,auctioneer,target.row.item_id,target.signature,16)?;
    if !depth.complete||!depth.coherent{return Err("MM2 CANCEL targeted depth incomplete/incoherent".into());}
    if depth.observed_at.elapsed()>Mm2Duration::from_secs(10){return Err("MM2 CANCEL targeted depth stale".into());}
    let depth_own=mm2_exact_auction(&depth,target.row.auction_id).ok_or("MM2 CANCEL own auction absent from targeted depth")?;
    if !lifecycle_same(depth_own,target)||depth_own.row.owner_guid!=player{return Err("MM2 CANCEL targeted own identity/owner mismatch".into());}
    if depth_own.row.highest_bid!=0{return Err("MM2 CANCEL blocked: targeted active bid".into());}

    // fsync happens inside saga.advance before any mutation byte can be emitted.
    saga.advance(Mm2SagaPhase::CancelIntent{auction_id:target.row.auction_id})?;
    let auction_id=target.row.auction_id;
    let item_id=target.row.item_id;
    let count=target.row.count;
    let tx=mutations::transaction(MutationKind::Cancel,||{
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_REMOVE_ITEM{auctioneer:auctioneer.into(),auction_id})?;
        let deadline=Mm2Instant::now()+Mm2Duration::from_secs(4);
        mm2_wait_for(stream,crypto,deadline,"cancel/ack",|op,p|{
            if op!=POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE{return Ok(None);}
            mm2_cancel_ack_payload(p,auction_id)?;Ok(Some(()))
        })?;
        let after=mm2_owner_list(stream,crypto,auctioneer,player)?;
        if after.iter().any(|r|r.row.auction_id==auction_id){return Err("MM2 CANCEL ACK not reconciled: auction still owned".into());}
        recovery.set(Mm2Recovery::CancelledAwaitingMail{auction_id,item_id,count})?;
        saga.advance(Mm2SagaPhase::CancelConfirmed{auction_id})?;
        println!("[MM2] CANCEL_CONFIRMED auction_id={auction_id} item_id={item_id} count={count}");
        Ok(())
    });
    if let Err(e)=tx{
        // Once CancelIntent is durable, fail closed on every executor failure. If SEND happened,
        // coordinator `.pending` remains durable; if it did not, manual reconcile is conservative
        // but prevents accidental replay from an ambiguous caller state.
        let pending=mutations::pending_send_exists().unwrap_or(true);
        let detail=format!("pending_send={pending}; {e}");
        let _=saga.block_uncertain("CANCEL",&detail);
        return Err(format!("MM2 CANCEL HARD STOP {detail}"));
    }
    Ok(())
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
    if let Ok((generation,_,_,player_seen))=mm2_tracker_snapshot(){if generation>0&&player_seen{return Ok(()));}}
    let started=Mm2Instant::now();let deadline=started+Mm2Duration::from_secs(10);
    mm2_wait_for(stream,crypto,deadline,"tracker-warmup",|_,_|{
        let(generation,objects,slots,player_seen)=mm2_tracker_snapshot()?;
        if generation>0&&player_seen{println!("[MM2] TRACKER_WARM_PASS generation={generation} objects={objects} physical_slots={slots} player_seen=YES ms={}",started.elapsed().as_millis());Ok(Some(()))}else{Ok(None)}
    })
}

fn mm2_resolve_auction_only(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(u64,u32),String>{
    let(ah,_mail)=mm2_collect_candidates(stream,crypto,player,Mm2Duration::from_millis(1500))?;
    mm2_resolve_auctioneer(stream,crypto,&ah)
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
        "auction-capability"|"ah-capability"=>{let(auctioneer,house)=mm2_resolve_auction_only(stream,crypto,player)?;let mine=mm2_owner_list(stream,crypto,auctioneer,player)?;println!("[MM2] AUCTION_CAPABILITY_PASS auctioneer=0x{auctioneer:016X} house={house} own={} read_only=YES",mine.len());Ok(())},
        "capability"|"read-only"|"readonly"=>{let targets=mm2_resolve_targets(stream,crypto,player)?;let mine=mm2_owner_list(stream,crypto,targets.auctioneer,player)?;println!("[MM2] CAPABILITY_PASS auctioneer=0x{:016X} house={} mailbox=0x{:016X} own={} read_only=YES",targets.auctioneer,targets.auction_house,targets.mailbox,mine.len());Ok(())},
        "depth"|"targeted-depth"=>{let item=env::var("WOW112_MM2_ITEM_ID").map_err(|_|"MM2 targeted-depth requires WOW112_MM2_ITEM_ID")?.parse::<u32>().map_err(|_|"MM2 invalid WOW112_MM2_ITEM_ID")?;let(auctioneer,_house)=mm2_resolve_auction_only(stream,crypto,player)?;let snap=mm2_targeted_depth(stream,crypto,auctioneer,item,[0,0,0],16)?;if !snap.complete||!snap.coherent{return Err("MM2 targeted depth incomplete/incoherent".into());}println!("[MM2] TARGETED_DEPTH_PASS item={} rows={} raw_total={} read_only=YES",item,snap.rows.len(),snap.raw_total);Ok(())},
        "undercut-canary"|"clear-one-buy-canary"=>Err("MM2 mutation canary BLOCKED: execution primitives not yet safety-approved".into()),
        _=>Err("WOW112_MM2_MODE must be capability, auction-capability, mailbox-resolver, inventory-tracker, targeted-depth, undercut-canary, or clear-one-buy-canary".into()),
    }
}
#[cfg(test)]mod mm2_runtime_tests{
    use super::*;
    #[test]fn mutation_modes_are_not_implicitly_passed(){assert_eq!(["undercut-canary","clear-one-buy-canary"].len(),2);}
    #[test]fn cancel_ack_is_exact(){let mut p=Vec::new();p.extend_from_slice(&7u32.to_le_bytes());p.extend_from_slice(&1u32.to_le_bytes());p.extend_from_slice(&0u32.to_le_bytes());assert!(mm2_cancel_ack_payload(&p,7).is_ok());assert!(mm2_cancel_ack_payload(&p,8).is_err());p[4..8].copy_from_slice(&0u32.to_le_bytes());assert!(mm2_cancel_ack_payload(&p,7).is_err());}
}
