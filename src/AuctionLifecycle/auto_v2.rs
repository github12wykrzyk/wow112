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
            lifecycle_mail(stream,crypto,mailbox,Poc05MailAction::TakeItem(returned[0].id))?;
            let fresh=lifecycle_inventory()?;
            let items:Vec<_>=fresh.iter().filter(|(guid,i)|
                !old_inventory.contains_key(guid) && i.entry as u32==target.row.item_id && i.stack as u32==target.row.count
            ).collect();
            if items.len()!=1 { return Err("AUTO returned full-stack GUID not uniquely observed; reconciliation required".into()); }

            lifecycle_post(stream,crypto,npc,player,*items[0].0,target.row.item_id,target.row.count,buyout,buyout,floor,minutes)
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
    #[test] fn strict_ratio_price_respects_floor() {
        let own=a(1,7,1,50); let w=a(2,8,1,45);
        assert_eq!(lifecycle_auto_price(&own,&w,40),Some(44));
        assert_eq!(lifecycle_auto_price(&own,&w,45),None);
    }
    #[test] fn stack_ratio_price_is_strict() {
        let own=a(1,7,3,120); let w=a(2,8,2,67);
        assert_eq!(lifecycle_auto_price(&own,&w,1),Some(100));
    }
}
