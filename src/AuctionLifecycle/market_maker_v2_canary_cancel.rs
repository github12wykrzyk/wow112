//! Prompt-2 CANCEL primitive: targeted exact-item depth is the final market authority before SEND.
//! This intentionally shadows neither canonical BUY nor generic lifecycle CANCEL.

fn mm2_canary_guarded_cancel_fresh(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    auctioneer:u64,
    player:u64,
    target:&LifecycleAuction,
    saga:&mut crate::market_maker_v2_saga::Mm2SagaJournal,
    recovery:&mut crate::market_maker_v2_recovery::Mm2RecoveryJournal,
)->Result<(),String>{
    use crate::market_maker_v2_recovery::Mm2Recovery;
    use crate::market_maker_v2_saga::Mm2SagaPhase;

    if !recovery.is_idle(){return Err("MM2 CANARY CANCEL recovery not idle".into());}
    let state=saga.state().ok_or("MM2 CANARY CANCEL saga missing")?;
    if !matches!(state.phase,Mm2SagaPhase::MailboxVerified{..}){return Err("MM2 CANARY CANCEL saga not mailbox-verified".into());}
    if state.own_auction_id!=Some(target.row.auction_id)||state.item_id!=target.row.item_id||state.signature!=target.signature{
        return Err("MM2 CANARY CANCEL saga/target identity mismatch".into());
    }
    if target.row.highest_bid!=0{return Err("MM2 CANARY CANCEL target has active bid".into());}

    // Durable logical intent first. A pre-SEND failure after this becomes HOLD, never a retry.
    saga.advance(Mm2SagaPhase::CancelIntent{auction_id:target.row.auction_id})?;
    let auction_id=target.row.auction_id;
    let item_id=target.row.item_id;
    let count=target.row.count;

    let tx=mutations::transaction(MutationKind::Cancel,||{
        // 1) Final exact My Auctions identity / active-bid proof.
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/cancel-final-owner-fence")?;
        let owners=mm2_owner_list(stream,crypto,auctioneer,player)?;
        let own=owners.iter().find(|r|r.row.auction_id==auction_id).ok_or("MM2 CANARY CANCEL final target absent")?;
        if !lifecycle_same(own,target)||own.row.owner_guid!=player{return Err("MM2 CANARY CANCEL final owner identity changed".into());}
        if own.row.highest_bid!=0{return Err("MM2 CANARY CANCEL final guard blocked: active bid".into());}

        // 2) FINAL market authority immediately before SEND: exact item+signature targeted depth.
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/cancel-final-depth-fence")?;
        let depth=mm2_targeted_depth(stream,crypto,auctioneer,item_id,target.signature,16)?;
        if !depth.complete||!depth.coherent{return Err("MM2 CANARY CANCEL final targeted depth incomplete/incoherent".into());}
        let depth_own=mm2_exact_auction(&depth,auction_id).ok_or("MM2 CANARY CANCEL own auction absent from final targeted depth")?;
        if !lifecycle_same(depth_own,target)||depth_own.row.owner_guid!=player{return Err("MM2 CANARY CANCEL final targeted identity/owner changed".into());}
        if depth_own.row.highest_bid!=0{return Err("MM2 CANARY CANCEL final targeted active bid".into());}
        let external_cheaper=depth.rows.iter().any(|r|lifecycle_cheaper(depth_own,r));
        if !external_cheaper{return Err("MM2 CANARY CANCEL no longer undercut by real external competition".into());}
        if depth.observed_at.elapsed()>Mm2Duration::from_secs(3){return Err("MM2 CANARY CANCEL final targeted depth stale".into());}

        // No read-only scan is allowed between this point and mutation bytes.
        stream.set_write_timeout(Some(Mm2Duration::from_secs(4))).map_err(|e|format!("MM2 CANARY CANCEL set write timeout: {e}"))?;
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_REMOVE_ITEM{auctioneer:auctioneer.into(),auction_id})?;
        stream.set_write_timeout(Some(Mm2Duration::from_secs(20))).map_err(|e|format!("MM2 CANARY CANCEL restore write timeout: {e}"))?;

        let deadline=Mm2Instant::now()+Mm2Duration::from_secs(4);
        mm2_wait_for(stream,crypto,deadline,"canary/cancel-ack",|op,p|{
            if op!=POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE{return Ok(None);}
            mm2_cancel_ack_payload(p,auction_id)?;
            Ok(Some(()))
        })?;
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"canary/cancel-post-ack-fence")?;
        let after=mm2_owner_list(stream,crypto,auctioneer,player)?;
        if after.iter().any(|r|r.row.auction_id==auction_id){return Err("MM2 CANARY CANCEL ACK not reconciled: auction still owned".into());}

        // Persist confirmed effect before coordinator is allowed to remove .pending.
        recovery.set(Mm2Recovery::CancelledAwaitingMail{auction_id,item_id,count})?;
        saga.advance(Mm2SagaPhase::CancelConfirmed{auction_id})?;
        println!("[MM2-CANARY] CANCEL_CONFIRMED auction_id={auction_id} item_id={item_id} count={count}");
        Ok(())
    });

    if let Err(e)=tx{
        let sent=mutations::sent_in_current_tx();
        let pending=mutations::pending_send_exists();
        let detail=format!("sent={sent} pending_send={pending}; {e}");
        if sent||pending{
            let _=saga.block_uncertain("CANCEL",&detail);
            return Err(format!("MM2 CANARY CANCEL BLOCKED_UNCERTAIN {detail}"));
        }
        let _=saga.advance(Mm2SagaPhase::Hold{reason:format!("CANCEL_NOT_SENT {detail}")});
        return Err(format!("MM2 CANARY CANCEL NOT_SENT {detail}"));
    }
    Ok(())
}
