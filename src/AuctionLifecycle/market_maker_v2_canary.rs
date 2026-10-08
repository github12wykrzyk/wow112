//! Prompt-2 one-shot live UNDERCUT canary for Market Maker V2.
//! Scope is intentionally narrow: one plain stack=1 owned auction, one lifecycle, no CLEAR,
//! no automatic retry after any uncertain SEND. Every mutation uses the shared coordinator.

const MM2_CANARY_MAIL_RESULT_OPCODE:u16=0x0239;
const MM2_CANARY_TAKE_ITEM_OPCODE:u32=0x0246;
const MM2_CANARY_SPLIT_OPCODE:u32=0x010e;

#[derive(Clone,Debug)]
struct Mm2CanaryChoice {
    own:LifecycleAuction,
    pre_target_unit:u32,
    witness_auction_id:u32,
}

fn mm2_canary_env_u32(name:&str,default:u32)->Result<u32,String>{
    match env::var(name){
        Ok(v)=>v.trim().parse::<u32>().map_err(|_|format!("MM2 canary invalid {name}")),
        Err(_)=>Ok(default),
    }
}

fn mm2_canary_floors()->Result<crate::market_maker_v2_policy::Floors,String>{
    Ok(crate::market_maker_v2_policy::Floors{
        explicit_unit:mm2_canary_env_u32("WOW112_MM2_EXPLICIT_FLOOR_UNIT",1)?.max(1),
        economic_unit:mm2_canary_env_u32("WOW112_MM2_ECONOMIC_FLOOR_UNIT",1)?.max(1),
        history_unit:None,
    })
}

fn mm2_canary_limits(max_total:u32)->crate::market_maker_v2_policy::Limits{
    crate::market_maker_v2_policy::Limits{
        ah_cut_bps:500,
        max_depth_age_ms:3000,
        max_step_drop_bps:3000,
        support_band_bps:500,
        support_min_units:5,
        cliff_min_bps:2500,
        max_clear_units:5,
        max_clear_spend:max_total,
        max_exposure_units:50,
        clear_min_profit:1,
        clear_min_roi_bps:1,
    }
}

fn mm2_canary_quote(a:&LifecycleAuction)->crate::market_maker_v2_policy::Quote{
    crate::market_maker_v2_policy::Quote{
        auction_id:a.row.auction_id,
        owner_guid:a.row.owner_guid,
        buyout:a.row.buyout,
        count:a.row.count,
    }
}

fn mm2_canary_choose(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    auctioneer:u64,
    player:u64,
    mine:&[LifecycleAuction],
    max_total:u32,
    floors:crate::market_maker_v2_policy::Floors,
)->Result<Option<Mm2CanaryChoice>,String>{
    let limits=mm2_canary_limits(max_total);
    let mut candidates=mine.iter().filter(|a|
        a.row.highest_bid==0 && a.row.buyout>0 && a.row.buyout<=max_total &&
        a.row.count==1 && a.signature==[0,0,0]
    ).cloned().collect::<Vec<_>>();
    candidates.sort_by_key(|a|(a.row.buyout,a.row.auction_id));
    println!("[MM2-CANARY] SAFE_CANDIDATE_POOL count={} constraints=plain,stack1,no_bid,max_total={}c",candidates.len(),max_total);
    for own in candidates{
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/select-pre-depth")?;
        let depth=mm2_targeted_depth(stream,crypto,auctioneer,own.row.item_id,own.signature,16)?;
        if !depth.complete||!depth.coherent||depth.observed_at.elapsed()>Mm2Duration::from_secs(3){
            println!("[MM2-CANARY] CANDIDATE_REJECT auction_id={} reason=depth",own.row.auction_id);continue;
        }
        let Some(exact)=mm2_exact_auction(&depth,own.row.auction_id) else{
            println!("[MM2-CANARY] CANDIDATE_REJECT auction_id={} reason=own_missing",own.row.auction_id);continue;
        };
        if !lifecycle_same(exact,&own)||exact.row.owner_guid!=player||exact.row.highest_bid!=0{
            println!("[MM2-CANARY] CANDIDATE_REJECT auction_id={} reason=identity_or_bid",own.row.auction_id);continue;
        }
        let view=mm2_depth_view(&depth,own.row.auction_id);
        let decision=crate::market_maker_v2_policy::decide(
            mm2_canary_quote(&own),player,&view,floors,
            crate::market_maker_v2_policy::Exposure{owned_units:1,acquired_units:0,acquired_spend:0},limits,
        );
        match decision{
            crate::market_maker_v2_policy::Decision::Undercut{target_unit,witness_auction_id,..}
                if target_unit>0 && target_unit<own.row.buyout =>{
                    println!("[MM2-CANARY] SAFE_TARGET auction_id={} item_id={} own={}c target={}c witness={} sig={:?}",own.row.auction_id,own.row.item_id,own.row.buyout,target_unit,witness_auction_id,own.signature);
                    return Ok(Some(Mm2CanaryChoice{own,pre_target_unit:target_unit,witness_auction_id}));
                },
            other=>println!("[MM2-CANARY] CANDIDATE_REJECT auction_id={} decision={other:?}",own.row.auction_id),
        }
    }
    Ok(None)
}

fn mm2_canary_return_mail(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    mailbox:u64,
    baseline:&Mm2MailProof,
    item_id:u32,
    count:u32,
)->Result<Poc05MailRecord,String>{
    let deadline=Mm2Instant::now()+Mm2Duration::from_secs(8);
    loop{
        if Mm2Instant::now()>=deadline{return Err("MM2 return mail deadline; reconciliation required".into());}
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/return-mail-fence")?;
        let Some(rows)=mm2_mail_list_once(stream,crypto,mailbox,"canary/return-mail")? else{continue;};
        let mut found=rows.into_iter().filter(|m|
            !baseline.records.iter().any(|b|b.id==m.id) && m.cod==0 &&
            m.item==item_id && u32::from(m.stack)==count
        ).collect::<Vec<_>>();
        if found.len()>1{return Err("MM2 return mail ambiguous; reconciliation required".into());}
        if let Some(m)=found.pop(){
            println!("[MM2-CANARY] RETURN_MAIL_FOUND mail_id={} item_id={} count={}",m.id,m.item,m.stack);
            return Ok(m);
        }
    }
}

fn mm2_canary_inventory_delta(before:&[Mm2ItemView],item_id:u32,delta:u32)->Result<Option<(Mm2ItemView,u32)>,String>{
    let after=mm2_inventory_items(item_id)?;
    let mut found=Vec::new();
    for a in after{
        let old=before.iter().find(|b|b.guid==a.guid).map(|b|b.count).unwrap_or(0);
        if a.count>=old && a.count-old==delta{found.push((a,old));}
    }
    if found.len()>1{return Err("MM2 inventory delta ambiguous after mail take".into());}
    Ok(found.pop())
}

fn mm2_canary_wait_inventory_delta(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    before:&[Mm2ItemView],
    item_id:u32,
    delta:u32,
)->Result<(Mm2ItemView,u32),String>{
    if let Some(v)=mm2_canary_inventory_delta(before,item_id,delta)?{return Ok(v);}
    let deadline=Mm2Instant::now()+Mm2Duration::from_secs(5);
    loop{
        if Mm2Instant::now()>=deadline{return Err("MM2 inventory delta timeout after mail take".into());}
        let step=std::cmp::min(deadline,Mm2Instant::now()+Mm2Duration::from_secs(1));
        let r=mm2_wait_for(stream,crypto,step,"canary/mail-inventory",|_,_|{
            match mm2_canary_inventory_delta(before,item_id,delta)?{
                Some(v)=>Ok(Some(v)),None=>Ok(None),
            }
        });
        match r{
            Ok(v)=>return Ok(v),
            Err(e) if e.contains("MM2_PRE_SEND_DEADLINE")=>{
                mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/mail-inventory-fence")?;
                if let Some(v)=mm2_canary_inventory_delta(before,item_id,delta)?{return Ok(v);}
            },
            Err(e)=>return Err(e),
        }
    }
}

fn mm2_canary_take_mail(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    mailbox:u64,
    mail:&Poc05MailRecord,
    item_id:u32,
    count:u32,
    saga:&mut crate::market_maker_v2_saga::Mm2SagaJournal,
    recovery:&mut crate::market_maker_v2_recovery::Mm2RecoveryJournal,
)->Result<(Mm2ItemView,u32),String>{
    let before_inventory=mm2_inventory_items(item_id)?;
    saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::MailTakeIntent{mail_id:mail.id,item_id,count})?;
    let mut recovered:Option<(Mm2ItemView,u32)>=None;
    let mail_id=mail.id;
    let tx=mutations::transaction(MutationKind::Mail,||{
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/mail-final-fence")?;
        let final_mail=mm2_mail_list_once(stream,crypto,mailbox,"canary/mail-final")?.ok_or("MM2 final mail list no response")?;
        let exact=final_mail.iter().filter(|m|m.id==mail_id&&m.item==item_id&&u32::from(m.stack)==count&&m.cod==0).count();
        if exact!=1{return Err("MM2 mail target changed before TAKE; no send".into());}
        let mut request=Vec::with_capacity(12);request.extend_from_slice(&mailbox.to_le_bytes());request.extend_from_slice(&mail_id.to_le_bytes());
        stream.set_write_timeout(Some(Mm2Duration::from_secs(4))).map_err(|e|format!("MM2 MAIL set write timeout: {e}"))?;
        write_encrypted_raw(stream,crypto.encrypter(),MM2_CANARY_TAKE_ITEM_OPCODE,&request)?;
        stream.set_write_timeout(Some(Mm2Duration::from_secs(20))).map_err(|e|format!("MM2 MAIL restore write timeout: {e}"))?;
        let deadline=Mm2Instant::now()+Mm2Duration::from_secs(4);
        mm2_wait_for(stream,crypto,deadline,"canary/mail-ack",|op,p|{
            if op!=MM2_CANARY_MAIL_RESULT_OPCODE{return Ok(None);}
            if p.len()<12{return Err("MM2 MAIL malformed result".into());}
            let rid=read_u32_at(p,0)?;let action=read_u32_at(p,4)?;let result=read_u32_at(p,8)?;
            if rid!=mail_id||action!=2{return Ok(None);}
            if result!=0{return Err(format!("MM2 MAIL server rejected mail_id={mail_id} result={result}"));}
            Ok(Some(()))
        })?;
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/mail-postack-fence")?;
        let after_mail=mm2_mail_list_once(stream,crypto,mailbox,"canary/mail-postcheck")?.ok_or("MM2 post-TAKE mail list no response")?;
        if after_mail.iter().find(|m|m.id==mail_id).is_some_and(|m|m.item!=0&&m.stack!=0){return Err("MM2 MAIL ACK not reconciled: item still present".into());}
        let inv=mm2_canary_wait_inventory_delta(stream,crypto,&before_inventory,item_id,count)?;
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::ItemTaken{item_id,count})?;
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::InventoryVerified{guid:inv.0.guid,item_id,count:inv.0.count,bag:inv.0.physical.bag,slot:inv.0.physical.slot})?;
        recovery.set(crate::market_maker_v2_recovery::Mm2Recovery::HoldingStack{item_id,guid:inv.0.guid,count:inv.0.count,bag:inv.0.physical.bag,slot:inv.0.physical.slot,cost_basis:0})?;
        println!("[MM2-CANARY] TAKE_CONFIRMED mail_id={mail_id} guid=0x{:016X} item_id={} stack={} old_stack={} bag={} slot={}",inv.0.guid,item_id,inv.0.count,inv.1,inv.0.physical.bag,inv.0.physical.slot);
        recovered=Some(inv);Ok(())
    });
    if let Err(e)=tx{
        let sent=mutations::sent_in_current_tx();let pending=mutations::pending_send_exists();
        let detail=format!("sent={sent} pending_send={pending}; {e}");
        if sent||pending{let _=saga.block_uncertain("MAIL",&detail);return Err(format!("MM2 MAIL BLOCKED_UNCERTAIN {detail}"));}
        let _=saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason:format!("MAIL_NOT_SENT {detail}")});
        return Err(format!("MM2 MAIL NOT_SENT {detail}"));
    }
    recovered.ok_or("MM2 MAIL transaction lost recovered inventory evidence".into())
}

fn mm2_canary_slot_guid(slot:Mm2PhysicalSlot)->Option<u64>{MM2_INV.with(|c|c.borrow().slots.get(&slot).copied())}

fn mm2_canary_split_returned_one(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    recovered:&Mm2ItemView,
    previous_count:u32,
    saga:&mut crate::market_maker_v2_saga::Mm2SagaJournal,
    recovery:&mut crate::market_maker_v2_recovery::Mm2RecoveryJournal,
)->Result<(Mm2ItemView,bool),String>{
    if recovered.count==1{
        println!("[MM2-CANARY] SPLIT_NOT_REQUIRED guid=0x{:016X} stack=1",recovered.guid);
        recovery.set(crate::market_maker_v2_recovery::Mm2Recovery::HoldingUnits{item_id:recovered.item_id,guids:vec![recovered.guid],cost_basis:0})?;
        return Ok((recovered.clone(),false));
    }
    if recovered.count!=previous_count.saturating_add(1){return Err("MM2 split precondition failed: recovered delta is not exactly one".into());}
    let dest=mm2_empty_backpack_slot()?;
    if dest==recovered.physical{return Err("MM2 split destination equals source".into());}
    saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::SplitIntent{
        source_guid:recovered.guid,source_bag:recovered.physical.bag,source_slot:recovered.physical.slot,
        split_count:1,dest_bag:dest.bag,dest_slot:dest.slot,
    })?;
    let source_guid=recovered.guid;let source_count=recovered.count;let item_id=recovered.item_id;
    let mut unit:Option<Mm2ItemView>=None;
    let tx=mutations::transaction(MutationKind::Split,||{
        let source=mm2_item_view(source_guid)?;
        if source.item_id!=item_id||source.count!=source_count||source.physical!=recovered.physical{return Err("MM2 SPLIT source changed before send".into());}
        if mm2_canary_slot_guid(dest).is_some(){return Err("MM2 SPLIT destination no longer empty".into());}
        let payload=[source.physical.bag,source.physical.slot,dest.bag,dest.slot,1u8];
        stream.set_write_timeout(Some(Mm2Duration::from_secs(4))).map_err(|e|format!("MM2 SPLIT set write timeout: {e}"))?;
        write_encrypted_raw(stream,crypto.encrypter(),MM2_CANARY_SPLIT_OPCODE,&payload)?;
        stream.set_write_timeout(Some(Mm2Duration::from_secs(20))).map_err(|e|format!("MM2 SPLIT restore write timeout: {e}"))?;
        let deadline=Mm2Instant::now()+Mm2Duration::from_secs(4);
        let v=mm2_wait_for(stream,crypto,deadline,"canary/split-reconcile",|op,_|{
            if op==0x0112{return Err("MM2 SPLIT inventory change failure".into());}
            let Some(g)=mm2_canary_slot_guid(dest) else{return Ok(None);};
            let d=mm2_item_view(g)?;let s=mm2_item_view(source_guid)?;
            if d.item_id==item_id&&d.count==1&&d.physical==dest&&s.item_id==item_id&&s.count==source_count-1{
                return Ok(Some(d));
            }
            Ok(None)
        })?;
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::SplitProgress{source_guid,remaining:source_count-1,units:vec![v.guid]})?;
        recovery.set(crate::market_maker_v2_recovery::Mm2Recovery::HoldingUnits{item_id,guids:vec![v.guid],cost_basis:0})?;
        println!("[MM2-CANARY] SPLIT_CONFIRMED source=0x{source_guid:016X} unit=0x{:016X} dest={}:{}",v.guid,dest.bag,dest.slot);
        unit=Some(v);Ok(())
    });
    if let Err(e)=tx{
        let sent=mutations::sent_in_current_tx();let pending=mutations::pending_send_exists();
        let detail=format!("sent={sent} pending_send={pending}; {e}");
        if sent||pending{let _=saga.block_uncertain("SPLIT",&detail);return Err(format!("MM2 SPLIT BLOCKED_UNCERTAIN {detail}"));}
        let _=saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason:format!("SPLIT_NOT_SENT {detail}")});
        return Err(format!("MM2 SPLIT NOT_SENT {detail}"));
    }
    Ok((unit.ok_or("MM2 SPLIT lost unit evidence")?,true))
}

fn mm2_canary_post_decision(
    depth:&Mm2DepthSnapshot,
    original:&LifecycleAuction,
    player:u64,
    floors:crate::market_maker_v2_policy::Floors,
    max_total:u32,
)->crate::market_maker_v2_policy::Decision{
    let mut view=mm2_depth_view(depth,original.row.auction_id);
    // The original row is intentionally absent after confirmed CANCEL. It remains the durable saga
    // reference price; fresh targeted rows below are the only live competition authority.
    view.own_row_seen=true;
    crate::market_maker_v2_policy::decide(
        mm2_canary_quote(original),player,&view,floors,
        crate::market_maker_v2_policy::Exposure{owned_units:1,acquired_units:0,acquired_spend:0},
        mm2_canary_limits(max_total),
    )
}

fn mm2_canary_post_one(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    auctioneer:u64,
    player:u64,
    unit:&Mm2ItemView,
    buyout:u32,
    depth:&Mm2DepthSnapshot,
    saga:&mut crate::market_maker_v2_saga::Mm2SagaJournal,
    recovery:&mut crate::market_maker_v2_recovery::Mm2RecoveryJournal,
)->Result<u32,String>{
    let bid=buyout;let minutes=120u32;
    saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::PostIntent{guid:unit.guid,bag:unit.physical.bag,slot:unit.physical.slot,bid,buyout,minutes})?;
    let mut posted_id=0u32;
    let tx=mutations::transaction(MutationKind::Post,||{
        let current=mm2_item_view(unit.guid)?;
        if current.item_id!=unit.item_id||current.count!=1||current.physical!=unit.physical{return Err("MM2 POST unit changed before send".into());}
        if depth.observed_at.elapsed()>Mm2Duration::from_secs(3){return Err("MM2 POST targeted depth freshness expired".into());}
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/post-final-fence")?;
        if depth.observed_at.elapsed()>Mm2Duration::from_secs(3){return Err("MM2 POST targeted depth stale after fence".into());}
        let before=mm2_owner_list(stream,crypto,auctioneer,player)?;
        if depth.observed_at.elapsed()>Mm2Duration::from_secs(3){return Err("MM2 POST targeted depth stale after owner proof".into());}
        stream.set_write_timeout(Some(Mm2Duration::from_secs(4))).map_err(|e|format!("MM2 POST set write timeout: {e}"))?;
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_SELL_ITEM{
            auctioneer:auctioneer.into(),item:unit.guid.into(),starting_bid:bid,buyout,auction_duration_in_minutes:minutes,
        })?;
        stream.set_write_timeout(Some(Mm2Duration::from_secs(20))).map_err(|e|format!("MM2 POST restore write timeout: {e}"))?;
        let deadline=Mm2Instant::now()+Mm2Duration::from_secs(4);
        let id=mm2_wait_for(stream,crypto,deadline,"canary/post-ack",|op,p|{
            if op!=POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE{return Ok(None);}
            if p.len()<12{return Err("MM2 POST malformed ACK".into());}
            let aid=read_u32_at(p,0)?;let action=read_u32_at(p,4)?;let result=read_u32_at(p,8)?;
            if action!=0{return Ok(None);}
            if result!=0{return Err(format!("MM2 POST server rejected result={result}"));}
            if aid==0{return Err("MM2 POST zero auction id".into());}
            Ok(Some(aid))
        })?;
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/post-reconcile-fence")?;
        let after=mm2_owner_list(stream,crypto,auctioneer,player)?;
        if before.iter().any(|r|r.row.auction_id==id){return Err("MM2 POST ACK reused pre-existing auction id".into());}
        let Some(row)=after.iter().find(|r|r.row.auction_id==id) else{return Err("MM2 POST ACK missing from My Auctions".into());};
        if row.row.owner_guid!=player||row.row.item_id!=unit.item_id||row.row.count!=1||row.row.start_bid!=bid||row.row.buyout!=buyout||row.signature!=[0,0,0]{return Err("MM2 POST My Auctions identity/price mismatch".into());}
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::PostProgress{posted:1,remaining:vec![]})?;
        recovery.clear()?;
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Done)?;
        println!("[MM2-CANARY] POST_CONFIRMED auction_id={id} item_id={} count=1 buyout={}c",unit.item_id,buyout);
        posted_id=id;Ok(())
    });
    if let Err(e)=tx{
        let sent=mutations::sent_in_current_tx();let pending=mutations::pending_send_exists();
        let detail=format!("sent={sent} pending_send={pending}; {e}");
        if sent||pending{let _=saga.block_uncertain("POST",&detail);return Err(format!("MM2 POST BLOCKED_UNCERTAIN {detail}"));}
        let _=saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason:format!("POST_NOT_SENT {detail}")});
        return Err(format!("MM2 POST NOT_SENT {detail}"));
    }
    Ok(posted_id)
}

fn market_maker_v2_undercut_canary(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String>{
    let max_total=mm2_canary_env_u32("WOW112_MM2_CANARY_MAX_TOTAL",10_000)?;
    if max_total==0{return Err("MM2 canary max total must be positive".into());}
    mm2_preflight_journals(player)?;
    let(server,realm)=mm2_bound_identity(player)?;
    if let Some(p)=mutations::inspect_pending(&server,realm,player)?{return Err(format!("MM2_CANARY_PENDING_BLOCK {}",p.trim()));}
    mm2_warm_tracker(stream,crypto)?;
    let(generation,objects,slots,player_seen)=mm2_tracker_snapshot()?;
    if generation==0||objects==0||!player_seen{return Err("MM2 canary inventory/world tracker lacks authoritative player evidence".into());}
    println!("[MM2-CANARY] INVENTORY_PASS generation={generation} objects={objects} physical_slots={slots}");

    let targets=mm2_resolve_targets(stream,crypto,player)?;
    let mine=mm2_owner_list(stream,crypto,targets.auctioneer,player)?;
    println!("[MM2-CANARY] CAPABILITY_PASS auctioneer=0x{:016X} house={} mailbox=0x{:016X} own={}",targets.auctioneer,targets.auction_house,targets.mailbox,mine.len());
    let mailbox_before=mm2_mail_baseline(stream,crypto,targets.mailbox)?;
    if !mm2_mail_proof_fresh(&mailbox_before){return Err("MM2 canary mailbox proof stale".into());}
    println!("[MM2-CANARY] MAILBOX_PASS guid=0x{:016X} mails={}",targets.mailbox,mailbox_before.records.len());

    let floors=mm2_canary_floors()?;
    let Some(choice)=mm2_canary_choose(stream,crypto,targets.auctioneer,player,&mine,max_total,floors)? else{
        println!("[MM2-CANARY] BLOCKED_NO_SAFE_TARGET mutations=0 pending=NO READY_FOR_PROMPT_3=NO");
        return Ok(());
    };
    // Refresh mailbox immediately before starting the durable saga. No mutation has happened yet.
    let mailbox_before=mm2_mail_baseline(stream,crypto,targets.mailbox)?;
    if !mm2_mail_proof_fresh(&mailbox_before){return Err("MM2 canary final mailbox baseline stale".into());}

    let mut recovery=crate::market_maker_v2_recovery::Mm2RecoveryJournal::open(&server,realm,player)?;
    let mut saga=crate::market_maker_v2_saga::Mm2SagaJournal::open(&server,realm,player)?;
    if !recovery.is_idle()||!saga.can_start_new(){return Err("MM2 canary durable state changed after preflight".into());}
    let saga_id=saga.start(crate::market_maker_v2_saga::Mm2SagaKind::Undercut,choice.own.row.item_id,choice.own.signature,Some(choice.own.row.auction_id))?;
    saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::MailboxVerified{mailbox:targets.mailbox})?;
    println!("[MM2-CANARY] SAGA_PLANNED id={saga_id} auction_id={} item_id={} pre_target={}c witness={}",choice.own.row.auction_id,choice.own.row.item_id,choice.pre_target_unit,choice.witness_auction_id);

    let mut mutations_confirmed=0u32;
    mm2_guarded_cancel(stream,crypto,targets.auctioneer,player,&choice.own,&mut saga,&mut recovery)?;
    mutations_confirmed+=1;
    let returned=mm2_canary_return_mail(stream,crypto,targets.mailbox,&mailbox_before,choice.own.row.item_id,1)?;
    saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::ReturnMailFound{mail_id:returned.id})?;
    let(recovered,previous_count)=mm2_canary_take_mail(stream,crypto,targets.mailbox,&returned,choice.own.row.item_id,1,&mut saga,&mut recovery)?;
    mutations_confirmed+=1;
    let(unit,did_split)=mm2_canary_split_returned_one(stream,crypto,&recovered,previous_count,&mut saga,&mut recovery)?;
    if did_split{mutations_confirmed+=1;}

    mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/pre-post-depth")?;
    let depth=mm2_targeted_depth(stream,crypto,targets.auctioneer,choice.own.row.item_id,choice.own.signature,16)?;
    if !depth.complete||!depth.coherent||depth.observed_at.elapsed()>Mm2Duration::from_secs(3){
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason:"POST_DEPTH_NOT_FRESH".into()})?;
        println!("[MM2-CANARY] UNDERCUT_PASS state=HOLD reason=POST_DEPTH_NOT_FRESH mutations={mutations_confirmed} pending=NO READY_FOR_PROMPT_3=NO");
        return Ok(());
    }
    let decision=mm2_canary_post_decision(&depth,&choice.own,player,floors,max_total);
    let buyout=match decision{
        crate::market_maker_v2_policy::Decision::Undercut{target_unit,..} if target_unit>0=>target_unit,
        other=>{
            let reason=format!("POST_POLICY_HOLD {other:?}");
            saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason:reason.clone()})?;
            println!("[MM2-CANARY] UNDERCUT_PASS state=HOLD reason={reason:?} mutations={mutations_confirmed} pending=NO READY_FOR_PROMPT_3=NO");
            return Ok(());
        }
    };
    if buyout<floors.explicit_unit.max(floors.economic_unit).max(1)||buyout>=choice.own.row.buyout{
        saga.advance(crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason:"POST_PRICE_GUARD".into()})?;
        println!("[MM2-CANARY] UNDERCUT_PASS state=HOLD reason=POST_PRICE_GUARD mutations={mutations_confirmed} pending=NO READY_FOR_PROMPT_3=NO");
        return Ok(());
    }
    let posted_id=mm2_canary_post_one(stream,crypto,targets.auctioneer,player,&unit,buyout,&depth,&mut saga,&mut recovery)?;
    mutations_confirmed+=1;
    let pending=mutations::pending_send_exists();
    if pending{return Err("MM2 canary invariant violation: .pending after successful lifecycle".into());}
    println!("[MM2-CANARY] UNDERCUT_PASS state=DONE mutations={mutations_confirmed} posted_auction_id={posted_id} pending=NO READY_FOR_PROMPT_3=YES");
    Ok(())
}

#[cfg(test)]
mod mm2_canary_tests{
    use super::*;
    #[test]fn canary_defaults_are_mutation_bounded(){assert_eq!(MM2_CANARY_TAKE_ITEM_OPCODE,0x246);assert_eq!(MM2_CANARY_SPLIT_OPCODE,0x10e);assert_eq!(mm2_canary_limits(10_000).max_depth_age_ms,3000);}
}
