// Guarded multi-auction AUTO Lifecycle V2.
// Included after adapter.rs so all proven lifecycle primitives remain unchanged.

fn lifecycle_auto_floors()->Result<std::collections::HashMap<u32,u32>,String> {
    let raw=env::var("WOW112_LIFECYCLE_AUTO_FLOORS").map_err(|_|"missing WOW112_LIFECYCLE_AUTO_FLOORS")?;
    let mut out=std::collections::HashMap::new();
    for part in raw.split(',').filter(|x|!x.trim().is_empty()) {
        let mut it=part.trim().split(':');
        let item:u32=it.next().ok_or("AUTO floor item missing")?.parse().map_err(|_|"AUTO invalid floor item")?;
        let floor:u32=it.next().ok_or("AUTO floor value missing")?.parse().map_err(|_|"AUTO invalid floor value")?;
        if it.next().is_some() || item==0 || floor==0 || out.insert(item,floor).is_some() {
            return Err("AUTO invalid/duplicate floor map".into());
        }
    }
    if out.is_empty() { return Err("AUTO floor map empty".into()); }
    Ok(out)
}

fn lifecycle_auto_price(own:&LifecycleAuction,w:&LifecycleAuction,floor:u32)->Option<u32> {
    if own.row.count==0 || w.row.count==0 || w.row.buyout==0 { return None; }
    let num=u64::from(w.row.buyout).checked_mul(u64::from(own.row.count))?;
    if num==0 { return None; }
    let strict=(num-1)/u64::from(w.row.count);
    let buyout=u32::try_from(strict).ok()?;
    if buyout<floor || buyout>=own.row.buyout || buyout==0 { None } else { Some(buyout) }
}

#[derive(Debug,PartialEq,Eq)]
enum LifecycleAutoReturnedItemState {
    Pending,
    ExactNew(u64),
    Merged,
    Ambiguous(&'static str),
}

fn lifecycle_auto_is_item(e:&Poc05InventoryEntry,item:u32)->bool {
    e.entry>0 && e.entry as u32==item && e.stack>0
}
fn lifecycle_auto_stack(e:&Poc05InventoryEntry)->u32 {
    if e.stack>0 { e.stack as u32 } else { 0 }
}

fn lifecycle_auto_classify_returned(
    old:&std::collections::HashMap<u64,Poc05InventoryEntry>,
    fresh:&std::collections::HashMap<u64,Poc05InventoryEntry>,
    item:u32,
    count:u32,
)->LifecycleAutoReturnedItemState {
    let mut grown=false;
    let mut old_changed=false;
    for (guid,prev) in old.iter().filter(|(_,e)|lifecycle_auto_is_item(e,item)) {
        match fresh.get(guid) {
            Some(now) if lifecycle_auto_is_item(now,item) && lifecycle_auto_stack(now)>lifecycle_auto_stack(prev) => grown=true,
            Some(now) if lifecycle_auto_is_item(now,item) && lifecycle_auto_stack(now)==lifecycle_auto_stack(prev) => {},
            _ => old_changed=true,
        }
    }
    if grown { return LifecycleAutoReturnedItemState::Merged; }
    if old_changed { return LifecycleAutoReturnedItemState::Ambiguous("existing same-item stack changed"); }

    let new_same:Vec<_>=fresh.iter()
        .filter(|(guid,e)|!old.contains_key(*guid)&&lifecycle_auto_is_item(e,item))
        .collect();
    match new_same.as_slice() {
        []=>LifecycleAutoReturnedItemState::Pending,
        [(guid,e)] if lifecycle_auto_stack(e)==count=>LifecycleAutoReturnedItemState::ExactNew(**guid),
        [_]=>LifecycleAutoReturnedItemState::Ambiguous("new GUID stack != target count"),
        _=>LifecycleAutoReturnedItemState::Ambiguous("multiple new same-item GUIDs"),
    }
}

fn lifecycle_auto_inventory_risk()->Vec<(u64,i32,i32)> {
    LIFE_OBSERVED.with(|s| {
        let s=s.borrow();
        s.inventory.items.iter().map(|(guid,e)|(*guid,e.entry,e.stack)).collect()
    })
}

fn lifecycle_auto_merge_risk(item:u32)->Option<String> {
    let all=lifecycle_auto_inventory_risk();
    if all.is_empty() { return Some("inventory baseline not established".into()); }
    let hit:Vec<_>=all.iter().filter(|(_,entry,_)|*entry<=0 || *entry as u32==item).collect();
    if hit.is_empty() { None } else { Some(format!("same/unknown item cached: {hit:?}")) }
}

fn lifecycle_auto_inventory_diag(
    old:&std::collections::HashMap<u64,Poc05InventoryEntry>,
    fresh:&std::collections::HashMap<u64,Poc05InventoryEntry>,
    item:u32,
    round:u32,
) {
    let old_rows:Vec<_>=old.iter().filter(|(_,e)|lifecycle_auto_is_item(e,item)).map(|(g,e)|(*g,e.stack)).collect();
    let fresh_rows:Vec<_>=fresh.iter().filter(|(_,e)|lifecycle_auto_is_item(e,item)).map(|(g,e)|(*g,e.stack)).collect();
    println!("[LIFECYCLE-AUTO] RETURN_DIAG item={} round={} old={:?} fresh={:?}",item,round,old_rows,fresh_rows);
}

fn lifecycle_auto_wait_returned_full_stack(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    mailbox:u64,
    old:&std::collections::HashMap<u64,Poc05InventoryEntry>,
    item:u32,
    count:u32,
)->Result<u64,String> {
    const SETTLE_ROUNDS:u32=8;
    for round in 0..SETTLE_ROUNDS {
        // Read-only mailbox barrier. Its receive loop drains intervening world packets,
        // and read_encrypted_raw feeds lifecycle_observe_raw, allowing delayed inventory
        // updates to enter the verified cache without any mutation retry.
        let _=poc05_request_mail_list(stream,crypto,mailbox)?;
        let fresh=lifecycle_inventory()?;
        lifecycle_auto_inventory_diag(old,&fresh,item,round);
        match lifecycle_auto_classify_returned(old,&fresh,item,count) {
            LifecycleAutoReturnedItemState::ExactNew(guid)=>{
                println!("[LIFECYCLE-AUTO] RETURN_GUID_CONFIRMED item={} count={} guid=0x{:016X} settle_round={}",item,count,guid,round);
                return Ok(guid);
            }
            LifecycleAutoReturnedItemState::Pending=>{
                if round+1<SETTLE_ROUNDS { std::thread::sleep(Duration::from_millis(250)); }
            }
            LifecycleAutoReturnedItemState::Merged=>{
                return Err(format!("AUTO returned item MERGED into existing stack at settle_round={round}; manual reconciliation required"));
            }
            LifecycleAutoReturnedItemState::Ambiguous(why)=>{
                return Err(format!("AUTO returned item ambiguous at settle_round={round}: {why}; reconciliation required"));
            }
        }
    }
    Err("AUTO exact returned full-stack GUID not observed within bounded read-only settle window; reconciliation required".into())
}

fn lifecycle_auto_run(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String> {
    if env::var("WOW112_LIFECYCLE_CONFIRM").unwrap_or_default()!="YES" {
        return Err("LIFECYCLE AUTO explicit confirm required".into());
    }
    let floors=lifecycle_auto_floors()?;
    let limit=poc07_env_u32_default("WOW112_LIFECYCLE_AUTO_LIMIT",1)?;
    if limit==0 || limit>20 { return Err("AUTO invalid limit 1..20".into()); }
    let minutes=poc07_env_u32_default("WOW112_LIFECYCLE_MINUTES",120)?;
    if !matches!(minutes,120|480|1440) { return Err("AUTO invalid duration".into()); }
    let max_pages=poc07_env_u32_default("WOW112_LIFECYCLE_MAX_PAGES",4096)?;
    if max_pages==0 || max_pages>4096 { return Err("AUTO invalid max pages".into()); }

    let (npcs,mailbox)=discover_poc05_context_retry(stream,crypto,player)?;
    let (npc,house)=poc05_send_auction_hello_candidates(stream,crypto,npcs)?;
    let mine=lifecycle_owner_list(stream,crypto,npc,player)?;

    let eligible:Vec<usize>=mine.iter().enumerate().filter_map(|(i,a)| {
        let floor=*floors.get(&a.row.item_id)?;
        if a.row.highest_bid==0 && a.signature==[0,0,0] && a.row.buyout>floor && a.row.count>0 { Some(i) } else { None }
    }).collect();
    if eligible.is_empty() {
        println!("[LIFECYCLE-AUTO] PASS eligible=0 candidates=0 reposted=0");
        return Ok(());
    }

    // One shared market scan finds positive LOST witnesses for all eligible auctions.
    // Negative absence is never treated as proof when the scan is incomplete.
    let mut witnesses:std::collections::HashMap<usize,(u32,LifecycleAuction)>=std::collections::HashMap::new();
    for page in 0..max_pages {
        let (rows,total)=lifecycle_market_page(stream,crypto,npc,house,page)?;
        for idx in &eligible {
            if witnesses.contains_key(idx) { continue; }
            let own=&mine[*idx];
            if let Some(w)=rows.iter().find(|r|lifecycle_cheaper(own,r)) {
                if let Some(price)=lifecycle_auto_price(own,w,*floors.get(&own.row.item_id).unwrap()) {
                    println!("[LIFECYCLE-AUTO] CANDIDATE id={} item={} count={} old_buyout={} witness_page={} witness_id={} witness_buyout={} witness_count={} planned_buyout={}",
                        own.row.auction_id,own.row.item_id,own.row.count,own.row.buyout,page,w.row.auction_id,w.row.buyout,w.row.count,price);
                    witnesses.insert(*idx,(page,w.clone()));
                }
            }
        }
        if witnesses.len()>=limit as usize || (page+1)*50>=total { break; }
    }

    if witnesses.is_empty() {
        println!("[LIFECYCLE-AUTO] PASS eligible={} candidates=0 reposted=0",eligible.len());
        return Ok(());
    }

    let candidate_count=witnesses.len();
    let mut order:Vec<usize>=witnesses.keys().copied().collect();
    order.sort_by_key(|idx|mine[*idx].row.auction_id);
    let mut reposted=0u32;

    for idx in order.into_iter().take(limit as usize) {
        let target=&mine[idx];
        let witness=witnesses.remove(&idx).ok_or("AUTO witness disappeared internally")?;
        let floor=*floors.get(&target.row.item_id).ok_or("AUTO floor disappeared internally")?;
        let buyout=lifecycle_auto_price(target,&witness.1,floor).ok_or("AUTO price invalid before cancel")?;

        // Read-only barrier first, then conservative risk cache. False positives only skip.
        let _=poc05_request_mail_list(stream,crypto,mailbox)?;
        if let Some(why)=lifecycle_auto_merge_risk(target.row.item_id) {
            println!("[LIFECYCLE-AUTO] SKIP_MERGE_RISK id={} item={} reason={}",target.row.auction_id,target.row.item_id,why);
            continue;
        }

        // Snapshot mailbox before cancellation so the exact new return mail can be identified.
        let before=poc05_request_mail_list(stream,crypto,mailbox)?;
        lifecycle_cancel(stream,crypto,npc,house,player,target,witness)?;

        // Any error from this point is a hard stop. Never continue to another auction.
        let after_cancel=(||->Result<(),String>{
            let after=poc05_request_mail_list(stream,crypto,mailbox)?;
            let returned:Vec<_>=after.iter().filter(|m|
                !before.iter().any(|b|b.id==m.id) && m.cod==0 &&
                m.item==target.row.item_id && u32::from(m.stack)==target.row.count
            ).collect();
            if returned.len()!=1 { return Err("AUTO return mail not uniquely identified; reconciliation required".into()); }

            let old_inventory=lifecycle_inventory()?;
            if old_inventory.values().any(|e|lifecycle_auto_is_item(e,target.row.item_id)) {
                return Err("AUTO same item appeared in bags before take; returned item left in mailbox; reconciliation required".into());
            }
            lifecycle_mail(stream,crypto,mailbox,Poc05MailAction::TakeItem(returned[0].id))?;
            let guid=lifecycle_auto_wait_returned_full_stack(stream,crypto,mailbox,&old_inventory,target.row.item_id,target.row.count)?;
            lifecycle_post(stream,crypto,npc,player,guid,target.row.item_id,target.row.count,buyout,buyout,floor,minutes)
        })();
        after_cancel.map_err(|e|format!("AH_MUTATION_LIFECYCLE_AUTO_STOP_AFTER_CANCEL auction_id={}: {e}",target.row.auction_id))?;

        reposted+=1;
        println!("[LIFECYCLE-AUTO] REPOST_CONFIRMED old_auction_id={} item={} new_buyout={} sequence={}/{}",
            target.row.auction_id,target.row.item_id,buyout,reposted,limit);
    }

    println!("[LIFECYCLE-AUTO] PASS eligible={} candidates={} reposted={}",eligible.len(),candidate_count,reposted);
    Ok(())
}

#[cfg(test)] mod lifecycle_auto_v2_tests {
    use super::*;
    fn a(id:u32,owner:u64,count:u32,price:u32)->LifecycleAuction {
        LifecycleAuction{row:Poc06AuctionRecord{auction_id:id,item_id:10998,count,owner_guid:owner,start_bid:1,minimum_bid:0,buyout:price,time_left_ms:1000,highest_bid:0},signature:[0,0,0]}
    }
    fn inv(entry:i32,stack:i32)->Poc05InventoryEntry { Poc05InventoryEntry{entry,stack} }
    #[test] fn strict_ratio_price_respects_floor() {
        let own=a(1,7,1,50); let w=a(2,8,1,45);
        assert_eq!(lifecycle_auto_price(&own,&w,40),Some(44));
        assert_eq!(lifecycle_auto_price(&own,&w,45),None);
    }
    #[test] fn stack_ratio_price_is_strict() {
        let own=a(1,7,3,120); let w=a(2,8,2,67);
        assert_eq!(lifecycle_auto_price(&own,&w,1),Some(100));
    }
    #[test] fn classifier_pending_without_inventory_change() {
        let old=std::collections::HashMap::new(); let fresh=std::collections::HashMap::new();
        assert_eq!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::Pending);
    }
    #[test] fn classifier_exact_new_return_guid() {
        let old=std::collections::HashMap::new();
        let mut fresh=std::collections::HashMap::new(); fresh.insert(77,inv(10998,1));
        assert_eq!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::ExactNew(77));
    }
    #[test] fn classifier_merge_into_existing_stack() {
        let mut old=std::collections::HashMap::new(); old.insert(77,inv(10998,3));
        let mut fresh=std::collections::HashMap::new(); fresh.insert(77,inv(10998,4));
        assert_eq!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::Merged);
    }
    #[test] fn classifier_multiple_new_is_ambiguous() {
        let old=std::collections::HashMap::new();
        let mut fresh=std::collections::HashMap::new();fresh.insert(77,inv(10998,1));fresh.insert(78,inv(10998,1));
        assert!(matches!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::Ambiguous(_)));
    }
    #[test] fn classifier_wrong_new_stack_is_ambiguous() {
        let old=std::collections::HashMap::new();
        let mut fresh=std::collections::HashMap::new();fresh.insert(77,inv(10998,2));
        assert!(matches!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::Ambiguous(_)));
    }
    #[test] fn classifier_unrelated_item_keeps_pending() {
        let old=std::collections::HashMap::new();
        let mut fresh=std::collections::HashMap::new(); fresh.insert(88,inv(11175,1));
        assert_eq!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::Pending);
    }
    #[test] fn classifier_existing_same_item_disappears_is_ambiguous() {
        let mut old=std::collections::HashMap::new();old.insert(77,inv(10998,2));
        let fresh=std::collections::HashMap::new();
        assert!(matches!(lifecycle_auto_classify_returned(&old,&fresh,10998,1),LifecycleAutoReturnedItemState::Ambiguous(_)));
    }
}
