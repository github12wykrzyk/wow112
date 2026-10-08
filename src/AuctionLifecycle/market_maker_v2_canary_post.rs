//! Prompt-2 POST primitive: the caller captures My Auctions before the final targeted depth,
//! then performs no further market read before SEND. The exact targeted snapshot is therefore the
//! final market authority for the posted price.

fn mm2_canary_post_one_final_depth_authority(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    auctioneer:u64,
    player:u64,
    unit:&Mm2ItemView,
    buyout:u32,
    depth:&Mm2DepthSnapshot,
    pre_post_ids:&std::collections::HashSet<u32>,
    saga:&mut crate::market_maker_v2_saga::Mm2SagaJournal,
    recovery:&mut crate::market_maker_v2_recovery::Mm2RecoveryJournal,
)->Result<u32,String>{
    use crate::market_maker_v2_saga::Mm2SagaPhase;
    let bid=buyout;
    let minutes=120u32;
    if buyout==0{return Err("MM2 CANARY POST zero price".into());}
    if !depth.complete||!depth.coherent||depth.item_id!=unit.item_id{return Err("MM2 CANARY POST invalid final targeted depth".into());}
    if depth.observed_at.elapsed()>Mm2Duration::from_secs(3){return Err("MM2 CANARY POST final targeted depth stale before intent".into());}
    let current=mm2_item_view(unit.guid)?;
    if current.item_id!=unit.item_id||current.count!=1||current.physical!=unit.physical{return Err("MM2 CANARY POST unit changed before intent".into());}

    // Persist the exact final price/GUID/slot plan before coordinator mutation authority exists.
    saga.advance(Mm2SagaPhase::PostIntent{
        guid:unit.guid,bag:unit.physical.bag,slot:unit.physical.slot,bid,buyout,minutes,
    })?;
    let mut posted_id=0u32;
    let tx=mutations::transaction(MutationKind::Post,||{
        // Inventory identity may be rechecked; no AH/market read is allowed here before SEND.
        let current=mm2_item_view(unit.guid)?;
        if current.item_id!=unit.item_id||current.count!=1||current.physical!=unit.physical{return Err("MM2 CANARY POST unit changed before send".into());}
        if depth.observed_at.elapsed()>Mm2Duration::from_secs(3){return Err("MM2 CANARY POST final targeted depth freshness expired".into());}

        stream.set_write_timeout(Some(Mm2Duration::from_secs(4))).map_err(|e|format!("MM2 CANARY POST set write timeout: {e}"))?;
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_SELL_ITEM{
            auctioneer:auctioneer.into(),item:unit.guid.into(),starting_bid:bid,buyout,auction_duration_in_minutes:minutes,
        })?;
        stream.set_write_timeout(Some(Mm2Duration::from_secs(20))).map_err(|e|format!("MM2 CANARY POST restore write timeout: {e}"))?;

        let deadline=Mm2Instant::now()+Mm2Duration::from_secs(4);
        let id=mm2_wait_for(stream,crypto,deadline,"canary/post-ack-final-depth",|op,p|{
            if op!=POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE{return Ok(None);}
            if p.len()<12{return Err("MM2 CANARY POST malformed ACK".into());}
            let aid=read_u32_at(p,0)?;
            let action=read_u32_at(p,4)?;
            let result=read_u32_at(p,8)?;
            if action!=0{return Ok(None);}
            if result!=0{return Err(format!("MM2 CANARY POST server rejected result={result}"));}
            if aid==0{return Err("MM2 CANARY POST zero auction id".into());}
            Ok(Some(aid))
        })?;

        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/post-reconcile-fence")?;
        let after=mm2_owner_list(stream,crypto,auctioneer,player)?;
        if pre_post_ids.contains(&id){return Err("MM2 CANARY POST ACK reused pre-existing auction id".into());}
        let Some(row)=after.iter().find(|r|r.row.auction_id==id) else{return Err("MM2 CANARY POST ACK missing from My Auctions".into());};
        if row.row.owner_guid!=player||row.row.item_id!=unit.item_id||row.row.count!=1||row.row.start_bid!=bid||row.row.buyout!=buyout||row.signature!=depth.signature{
            return Err("MM2 CANARY POST My Auctions identity/signature/price mismatch".into());
        }

        saga.advance(Mm2SagaPhase::PostProgress{posted:1,remaining:vec![]})?;
        recovery.clear()?;
        saga.advance(Mm2SagaPhase::Done)?;
        println!("[MM2-CANARY] POST_CONFIRMED auction_id={id} item_id={} count=1 buyout={}c final_depth_age_ms={}",unit.item_id,buyout,depth.observed_at.elapsed().as_millis());
        posted_id=id;
        Ok(())
    });

    if let Err(e)=tx{
        let sent=mutations::sent_in_current_tx();
        let pending=mutations::pending_send_exists();
        let detail=format!("sent={sent} pending_send={pending}; {e}");
        if sent||pending{
            let _=saga.block_uncertain("POST",&detail);
            return Err(format!("MM2 CANARY POST BLOCKED_UNCERTAIN {detail}"));
        }
        let _=saga.advance(Mm2SagaPhase::Hold{reason:format!("POST_NOT_SENT {detail}")});
        return Err(format!("MM2 CANARY POST NOT_SENT {detail}"));
    }
    if posted_id==0{return Err("MM2 CANARY POST lost confirmed auction id".into());}
    Ok(posted_id)
}
