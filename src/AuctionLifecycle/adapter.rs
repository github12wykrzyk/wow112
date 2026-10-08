// Included into the canonical terminal module; all transport/login/BUY remain canonical.
use crate::auction_mutations::{self as mutations, Kind as MutationKind};
use std::cell::RefCell;

#[derive(Default)]
struct LifecycleObserved {
    player: u64, inventory: Poc05Snapshot,
    last_market: Option<Vec<u8>>, verified_items: HashSet<u64>,
}
thread_local! { static LIFE_OBSERVED: RefCell<LifecycleObserved> = RefCell::new(LifecycleObserved::default()); }
fn lifecycle_enabled()->bool { env::var("WOW112_LIFECYCLE_ACTION").map(|x| !x.is_empty() && x!="off").unwrap_or(false) }
fn lifecycle_bind(player:u64,realm:u32)->Result<mutations::Session,String> {
    let server=env::var("WOW112_SERVER_ID").unwrap_or_else(|_|"octowow".into());
    let session=mutations::bind(&server,realm,player)?;
    LIFE_OBSERVED.with(|s| *s.borrow_mut()=LifecycleObserved {player,..Default::default()});
    Ok(session)
}
fn lifecycle_observe_message(message:&ServerOpcodeMessage) {
    if !lifecycle_enabled() {return;}
    LIFE_OBSERVED.with(|s| {
        let mut s=s.borrow_mut(); let player=s.player;
        match message {
            ServerOpcodeMessage::SMSG_UPDATE_OBJECT(m)=>poc05_capture_objects(&m.objects,player,&mut s.inventory,&mut HashSet::new(),&mut HashSet::new()),
            ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(m)=>poc05_capture_objects(&m.objects,player,&mut s.inventory,&mut HashSet::new(),&mut HashSet::new()),
            _=>{}
        }
    });
    // Canonical snapshots deliberately tolerate partial fields; POST requires explicit ownership,
    // entry and stack evidence, and revokes it on ownership change / zero stack.
    let objects = match message {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(m) => Some(&m.objects),
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(m) => Some(&m.objects),
        _ => None,
    };
    if let Some(objects)=objects { LIFE_OBSERVED.with(|s| {
        let mut s=s.borrow_mut();
        for object in objects {
            let (guid,mask)=match object {
                Object::Values{guid1,mask1} => (guid1.guid(),mask1),
                Object::CreateObject{guid3,mask2,..}|Object::CreateObject2{guid3,mask2,..} => (guid3.guid(),mask2),
                _=>continue,
            };
            if let UpdateMask::Item(item)=mask {
                let owner=poc05_guarded_owner_guid(guid,"lifecycle-item",||item.item_owner().map(|g|g.guid()));
                if owner.is_some_and(|o|o!=s.player)||item.item_stack_count().is_some_and(|n|n<=0) {
                    s.verified_items.remove(&guid);s.inventory.items.remove(&guid);
                } else if owner==Some(s.player)&&item.object_entry().is_some_and(|n|n>0)&&item.item_stack_count().is_some_and(|n|n>0) {
                    s.verified_items.insert(guid);
                }
            }
        }
    }); }
}
fn lifecycle_observe_raw(op:u16,payload:&[u8]) {
    if !lifecycle_enabled() {return;}
    if op==SMSG_AUCTION_LIST_RESULT_OPCODE {
        LIFE_OBSERVED.with(|s|s.borrow_mut().last_market=Some(payload.to_vec()));
    }
    if op==0x00aa && payload.len()>=8 {
        let guid=u64::from_le_bytes(payload[..8].try_into().unwrap());
        LIFE_OBSERVED.with(|s| {let mut s=s.borrow_mut();s.inventory.items.remove(&guid);s.verified_items.remove(&guid);});
    }
    if matches!(op,SMSG_UPDATE_OBJECT_OPCODE|SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE) {
        match parse_raw_server_message(op,payload) {
            Ok(m)=>lifecycle_observe_message(&m),
            Err(e)=>println!("[LIFECYCLE-DIAG] object update parse skipped opcode=0x{op:04X} payload={} reason={e}",payload.len()),
        }
    }
}
#[derive(Clone,Debug)]
struct LifecycleAuction { row:Poc06AuctionRecord, signature:[u32;3] }
fn lifecycle_rows(payload:&[u8])->Result<(Vec<LifecycleAuction>,u32),String> {
    let rows=poc06_parse_auction_list_result(payload)?;
    let expected=8+rows.len()*AUCTION_RECORD_SIZE;
    if payload.len()!=expected {return Err("LIFECYCLE unsupported/trailing auction layout".into());}
    let total=read_u32_at(payload,expected-4)?;
    let enriched=rows.into_iter().enumerate().map(|(i,row)| {
        let base=4+i*AUCTION_RECORD_SIZE;
        Ok(LifecycleAuction{row,signature:[read_u32_at(payload,base+8)?,read_u32_at(payload,base+12)?,read_u32_at(payload,base+16)?]})
    }).collect::<Result<Vec<_>,String>>()?;
    Ok((enriched,total))
}
fn lifecycle_send<M:ClientMessage>(stream:&mut TcpStream,crypto:&mut HeaderCrypto,message:M)->Result<(),String> {
    // Delegate serialization to pinned wow_world_messages 0.3.0 vanilla, then reuse encrypted transport.
    let mut bytes=Vec::new(); message.write_unencrypted_client(&mut bytes).map_err(|e|format!("LIFECYCLE serialize: {e:?}"))?;
    if bytes.len()<6 {return Err("LIFECYCLE short serialized request".into());}
    let opcode=u32::from_le_bytes(bytes[2..6].try_into().unwrap());
    write_encrypted_raw(stream,crypto.encrypter(),opcode,&bytes[6..])
}
fn lifecycle_owner_list(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,player:u64)->Result<Vec<LifecycleAuction>,String> {
    let mut all=Vec::new();let mut seen=HashSet::new();let mut expected=None;
    for _ in 0..128 {
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_LIST_OWNER_ITEMS {auctioneer:npc.into(),list_from:all.len() as u32})?;
        let mut received=None;
        for _ in 0..256 {
            let(op,p)=read_encrypted_raw(stream,crypto.decrypter())?;
            if op==0x025d {received=Some(lifecycle_rows(&p)?);break;}
        }
        let(rows,total)=received.ok_or("LIFECYCLE owner response missing")?;
        if expected.is_some_and(|v|v!=total) {return Err("LIFECYCLE owner list changed during pagination".into());}
        expected=Some(total);
        for r in &rows {if r.row.owner_guid!=player || r.row.auction_id==0 || r.row.count==0 || !seen.insert(r.row.auction_id) {return Err("LIFECYCLE owner/duplicate/invalid row".into());}}
        let empty=rows.is_empty();all.extend(rows);
        if all.len()==total as usize {return Ok(all);}
        if empty || all.len()>total as usize {return Err("LIFECYCLE incomplete owner list".into());}
    }
    Err("LIFECYCLE owner page limit".into())
}
fn lifecycle_market_page(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,page:u32)->Result<(Vec<LifecycleAuction>,u32),String> {
    LIFE_OBSERVED.with(|s|s.borrow_mut().last_market=None);
    poc07_request_auction_page(stream,crypto,npc,house,page,"lifecycle-buybox")?;
    LIFE_OBSERVED.with(|s| lifecycle_rows(s.borrow().last_market.as_deref().ok_or("LIFECYCLE missing raw page")?))
}
fn lifecycle_same(a:&LifecycleAuction,b:&LifecycleAuction)->bool {
    a.row.auction_id==b.row.auction_id && a.row.item_id==b.row.item_id && a.row.count==b.row.count &&
    a.row.owner_guid==b.row.owner_guid && a.row.buyout==b.row.buyout && a.row.start_bid==b.row.start_bid &&
    a.row.highest_bid==b.row.highest_bid && a.signature==b.signature
}
fn lifecycle_cheaper(own:&LifecycleAuction,other:&LifecycleAuction)->bool {
    own.row.buyout>0 && other.row.buyout>0 && own.row.count>0 && other.row.count>0 &&
    own.row.owner_guid!=other.row.owner_guid && own.row.item_id==other.row.item_id && own.signature==other.signature &&
    u64::from(other.row.buyout)*u64::from(own.row.count)<u64::from(own.row.buyout)*u64::from(other.row.count)
}
fn lifecycle_lost(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,own:&LifecycleAuction,max_pages:u32)->Result<Option<(u32,LifecycleAuction)>,String> {
    for page in 0..max_pages {
        let(rows,total)=lifecycle_market_page(stream,crypto,npc,house,page)?;
        if let Some(r)=rows.iter().find(|r|lifecycle_cheaper(own,r)) {return Ok(Some((page,r.clone())));}
        if (page+1)*50>=total {return Ok(None);}
    }
    // Absence in a partial scan is never proof of winning the buybox.
    Err("LIFECYCLE BUYBOX_UNKNOWN scan page limit".into())
}
fn lifecycle_ack(stream:&mut TcpStream,crypto:&mut HeaderCrypto,action:u32,id:Option<u32>)->Result<u32,String> {
    for _ in 0..256 {
        let(op,p)=read_encrypted_raw(stream,crypto.decrypter())?;
        if op!=POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE {continue;}
        if p.len()<12 {return Err("LIFECYCLE malformed auction ACK".into());}
        let aid=read_u32_at(&p,0)?;let act=read_u32_at(&p,4)?;let result=read_u32_at(&p,8)?;
        if act!=action || id.is_some_and(|id|id!=aid) {return Err("LIFECYCLE mismatched ACK; channel not trusted".into());}
        if result!=0 {return Err(format!("LIFECYCLE server rejected action={act} id={aid} result={result}"));}
        if aid==0 {return Err("LIFECYCLE zero auction id in success ACK".into());}
        return Ok(aid);
    }
    Err("LIFECYCLE missing auction ACK".into())
}
fn lifecycle_mail(stream:&mut TcpStream,crypto:&mut HeaderCrypto,mailbox:u64,action:Poc05MailAction)->Result<(),String> {
    let before=poc05_request_mail_list(stream,crypto,mailbox)?;
    mutations::transaction(MutationKind::Mail,|| {
        let mut confirmed=false;
        poc05_perform_mail_action(stream,crypto,mailbox,action,&before,&mut confirmed)
    })
}
fn lifecycle_cancel(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,house:u32,player:u64,target:&LifecycleAuction,witness:(u32,LifecycleAuction))->Result<(),String> {
    // Revalidate both exact own auction and competitor just before the exclusive SEND.
    mutations::transaction(MutationKind::Cancel,|| {
        let started=Instant::now();
        let fresh=lifecycle_owner_list(stream,crypto,npc,player)?;
        let own=fresh.iter().find(|x|lifecycle_same(x,target)).ok_or("LIFECYCLE stale cancel target")?;
        if own.row.highest_bid!=0 {return Err("LIFECYCLE cancel blocked: active bid".into());}
        let(rows,_)=lifecycle_market_page(stream,crypto,npc,house,witness.0)?;
        if !rows.iter().any(|r|lifecycle_same(r,&witness.1)&&lifecycle_cheaper(own,r)) || started.elapsed()>Duration::from_secs(15) {return Err("LIFECYCLE stale buybox witness".into());}
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_REMOVE_ITEM {auctioneer:npc.into(),auction_id:own.row.auction_id})?;
        lifecycle_ack(stream,crypto,1,Some(own.row.auction_id))?;
        let after=lifecycle_owner_list(stream,crypto,npc,player)?;
        if after.iter().any(|r|r.row.auction_id==own.row.auction_id) {return Err("LIFECYCLE cancel ACK but auction still listed".into());}
        println!("[LIFECYCLE] CANCEL_CONFIRMED auction_id={}",own.row.auction_id);Ok(())
    })
}
fn lifecycle_inventory()->Result<std::collections::HashMap<u64,Poc05InventoryEntry>,String> {
    LIFE_OBSERVED.with(|s| {let s=s.borrow();Ok(s.inventory.items.iter().filter(|(g,_)|s.verified_items.contains(g)).map(|(g,i)|(*g,i.clone())).collect())})
}
fn lifecycle_post(stream:&mut TcpStream,crypto:&mut HeaderCrypto,npc:u64,player:u64,guid:u64,item:u32,count:u32,bid:u32,buyout:u32,floor:u32,minutes:u32)->Result<(),String> {
    if guid==0||item==0||count==0||floor==0||bid==0||bid>buyout||buyout<floor||!matches!(minutes,120|480|1440) {return Err("LIFECYCLE post price/identity/duration guard".into());}
    mutations::transaction(MutationKind::Post,|| {
        let before=lifecycle_owner_list(stream,crypto,npc,player)?;
        let inventory=lifecycle_inventory()?;
        let owned=inventory.get(&guid).ok_or("LIFECYCLE item GUID not observed as owned in this session")?;
        if owned.entry<=0||owned.entry as u32!=item||owned.stack<=0||owned.stack as u32!=count {return Err("LIFECYCLE exact full-stack inventory guard".into());}
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_AUCTION_SELL_ITEM {auctioneer:npc.into(),item:guid.into(),starting_bid:bid,buyout,auction_duration_in_minutes:minutes})?;
        let id=lifecycle_ack(stream,crypto,0,None)?;
        let after=lifecycle_owner_list(stream,crypto,npc,player)?;
        if before.iter().any(|r|r.row.auction_id==id) || !after.iter().any(|r|r.row.auction_id==id&&r.row.item_id==item&&r.row.count==count&&r.row.start_bid==bid&&r.row.buyout==buyout) {return Err("LIFECYCLE post ACK not reconciled to exact new owner auction".into());}
        // Invalidate the consumed GUID even if server omitted a destroy notification.
        LIFE_OBSERVED.with(|s|{let mut s=s.borrow_mut();s.inventory.items.remove(&guid);s.verified_items.remove(&guid);});
        println!("[LIFECYCLE] POST_CONFIRMED auction_id={id} item_id={item} count={count}");Ok(())
    })
}
fn lifecycle_u32(name:&str)->Result<u32,String> {env::var(name).map_err(|_|format!("missing {name}"))?.parse().map_err(|_|format!("invalid {name}"))}
fn lifecycle_u64(name:&str)->Result<u64,String> {let v=env::var(name).map_err(|_|format!("missing {name}"))?;if let Some(v)=v.strip_prefix("0x"){u64::from_str_radix(v,16)}else{v.parse()}.map_err(|_|format!("invalid {name}"))}
fn lifecycle_run(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String> {
    let action=env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default();
    if !matches!(action.as_str(),"inspect"|"settle"|"cancel"|"post"|"repost") {return Err("LIFECYCLE unknown action".into());}
    if action!="inspect" && env::var("WOW112_LIFECYCLE_CONFIRM").unwrap_or_default()!="YES" {return Err("LIFECYCLE explicit confirm required".into());}
    let(npcs,mailbox)=discover_poc05_context_retry(stream,crypto,player)?;
    let(npc,house)=poc05_send_auction_hello_candidates(stream,crypto,npcs)?;
    let max_pages=poc07_env_u32_default("WOW112_LIFECYCLE_MAX_PAGES",4096)?;
    if max_pages==0||max_pages>4096 {return Err("LIFECYCLE invalid max pages".into());}
    if action=="settle" {
        let limit=poc07_env_u32_default("WOW112_LIFECYCLE_MAIL_LIMIT",20)?;
        if limit==0||limit>100 {return Err("LIFECYCLE invalid mail limit".into());}
        for _ in 0..limit {
            let mails=poc05_request_mail_list(stream,crypto,mailbox)?;
            // No delete, COD, send-mail or return-mail operation exists in this module.
            let next=mails.iter().filter(|m|m.cod==0).find_map(|m|if m.money>0 {Some(Poc05MailAction::TakeMoney(m.id))}else if m.item>0&&m.stack>0 {Some(Poc05MailAction::TakeItem(m.id))}else{None});
            match next {Some(a)=>lifecycle_mail(stream,crypto,mailbox,a)?,None=>return Ok(())}
        }
        println!("[LIFECYCLE] MAIL_LIMIT_REACHED no_retry=YES");return Ok(());
    }
    if action=="post" {return lifecycle_post(stream,crypto,npc,player,lifecycle_u64("WOW112_LIFECYCLE_ITEM_GUID")?,lifecycle_u32("WOW112_LIFECYCLE_ITEM_ID")?,lifecycle_u32("WOW112_LIFECYCLE_COUNT")?,lifecycle_u32("WOW112_LIFECYCLE_BID")?,lifecycle_u32("WOW112_LIFECYCLE_BUYOUT")?,lifecycle_u32("WOW112_LIFECYCLE_FLOOR")?,poc07_env_u32_default("WOW112_LIFECYCLE_MINUTES",120)?);}
    let mine=lifecycle_owner_list(stream,crypto,npc,player)?;
    if action=="inspect" {
        // A positive cheaper-competitor witness is useful even while the live market count moves.
        // Count drift only prevents proving the negative claim that no cheaper auction exists.
        let mut witnesses:Vec<Option<(u32,LifecycleAuction)>>=vec![None;mine.len()];
        let mut max_total=0u32;
        let mut previous_total:Option<u32>=None;
        let mut stable=true;
        let mut covered_to_end=false;
        let mut scan_error:Option<String>=None;
        if mine.is_empty() {covered_to_end=true;} else {
            for page in 0..max_pages {
                match lifecycle_market_page(stream,crypto,npc,house,page) {
                    Ok((rows,total)) => {
                        if previous_total.is_some_and(|v|v!=total) {stable=false;}
                        previous_total=Some(total);
                        max_total=max_total.max(total);
                        for (idx,own) in mine.iter().enumerate() {
                            if witnesses[idx].is_none() {
                                if let Some(r)=rows.iter().find(|r|lifecycle_cheaper(own,r)) {witnesses[idx]=Some((page,r.clone()));}
                            }
                        }
                        if witnesses.iter().all(|w|w.is_some()) {covered_to_end=true;break;}
                        if (page+1)*50>=max_total {covered_to_end=true;break;}
                    }
                    Err(e)=>{scan_error=Some(e);break;}
                }
            }
        }
        let complete=covered_to_end&&stable&&scan_error.is_none();
        for (idx,own) in mine.iter().enumerate() {
            let state=if witnesses[idx].is_some(){"LOST"}else if complete{"NO_LOWER_OBSERVED"}else{"UNKNOWN"};
            println!("[MY-AUCTIONS] id={} item={} count={} buyout={} highest_bid={} buybox={}",own.row.auction_id,own.row.item_id,own.row.count,own.row.buyout,own.row.highest_bid,state);
        }
        if !stable {println!("[LIFECYCLE] INSPECT_PARTIAL reason=market total changed during shared inspect; negative buybox claims suppressed");}
        if let Some(e)=scan_error {println!("[LIFECYCLE] INSPECT_PARTIAL reason={e}");}
        println!("[LIFECYCLE] MY_AUCTIONS count={} shared_market_scan=YES complete={}",mine.len(),if complete{"YES"}else{"NO"});return Ok(());
    }
    let id=lifecycle_u32("WOW112_LIFECYCLE_AUCTION_ID")?;
    let target=mine.iter().find(|x|x.row.auction_id==id).ok_or("LIFECYCLE requested auction not owned")?;
    if target.row.item_id!=lifecycle_u32("WOW112_LIFECYCLE_ITEM_ID")?||target.row.count!=lifecycle_u32("WOW112_LIFECYCLE_COUNT")?||target.row.buyout!=lifecycle_u32("WOW112_LIFECYCLE_EXPECT_BUYOUT")? {return Err("LIFECYCLE target differs from approved tuple".into());}
    let witness=lifecycle_lost(stream,crypto,npc,house,target,max_pages)?.ok_or("LIFECYCLE no proof of lost buybox")?;
    if action=="cancel" {return lifecycle_cancel(stream,crypto,npc,house,player,target,witness);}
    // Validate the repost plan BEFORE cancelling. V1 never splits stacks or guesses a returned GUID.
    if target.signature!=[0,0,0] {return Err("LIFECYCLE repost V1 supports plain items only".into());}
    let buyout=lifecycle_u32("WOW112_LIFECYCLE_BUYOUT")?;
    let floor=lifecycle_u32("WOW112_LIFECYCLE_FLOOR")?;
    let bid=lifecycle_u32("WOW112_LIFECYCLE_BID")?;
    let minutes=poc07_env_u32_default("WOW112_LIFECYCLE_MINUTES",120)?;
    if floor==0||buyout<floor||bid==0||bid>buyout||buyout>=target.row.buyout||!matches!(minutes,120|480|1440)||u64::from(buyout)*u64::from(witness.1.row.count)>=u64::from(witness.1.row.buyout)*u64::from(target.row.count) {return Err("LIFECYCLE invalid repost plan/floor/undercut".into());}
    let before=poc05_request_mail_list(stream,crypto,mailbox)?;
    lifecycle_cancel(stream,crypto,npc,house,player,target,witness)?;
    // Any failure after cancellation stops this lifecycle; never restart the chain automatically.
    let after_cancel=(||->Result<(),String>{
        let after=poc05_request_mail_list(stream,crypto,mailbox)?;
        let returned:Vec<_>=after.iter().filter(|m|!before.iter().any(|b|b.id==m.id)&&m.cod==0&&m.item==target.row.item_id&&u32::from(m.stack)==target.row.count).collect();
        if returned.len()!=1 {return Err("return mail not uniquely identified; reconciliation required".into());}
        let old_inventory=lifecycle_inventory()?;
        lifecycle_mail(stream,crypto,mailbox,Poc05MailAction::TakeItem(returned[0].id))?;
        let fresh=lifecycle_inventory()?;
        let items:Vec<_>=fresh.iter().filter(|(guid,i)|!old_inventory.contains_key(guid)&&i.entry as u32==target.row.item_id&&i.stack as u32==target.row.count).collect();
        if items.len()!=1 {return Err("returned full-stack GUID not uniquely observed (merge/delayed update); reconciliation required".into());}
        lifecycle_post(stream,crypto,npc,player,*items[0].0,target.row.item_id,target.row.count,bid,buyout,floor,minutes)
    })();
    after_cancel.map_err(|e|format!("AH_MUTATION_LIFECYCLE_STOP_AFTER_CANCEL: {e}"))
}
fn poc07_buy_exact_one(stream:&mut TcpStream,crypto:&mut HeaderCrypto,auctioneer_guid:u64,auction_house:u32,mailbox_guid:u64,candidate:Poc07Candidate,mutation_committed:&mut bool)->Result<(),String> {
    mutations::transaction(MutationKind::Buy,||poc07_buy_exact_one_canonical(stream,crypto,auctioneer_guid,auction_house,mailbox_guid,candidate,mutation_committed))
}

#[cfg(test)] mod lifecycle_tests {
    use super::*;
    fn auction(id:u32,owner:u64,count:u32,price:u32)->LifecycleAuction {LifecycleAuction{row:Poc06AuctionRecord{auction_id:id,item_id:10940,count,owner_guid:owner,start_bid:1,minimum_bid:0,buyout:price,time_left_ms:1000,highest_bid:0},signature:[0,0,0]}}
    #[test] fn buybox_rational_price_and_identity(){let own=auction(1,7,3,100);assert!(lifecycle_cheaper(&own,&auction(2,8,1,33)));assert!(!lifecycle_cheaper(&own,&auction(2,8,1,34)));assert!(!lifecycle_cheaper(&own,&auction(2,7,1,1)));let mut r=auction(2,8,1,1);r.signature[1]=4;assert!(!lifecycle_cheaper(&own,&r));assert!(!lifecycle_cheaper(&own,&auction(2,8,0,1)));}
    #[test] fn exact_tuple_ignores_only_time(){let a=auction(1,7,1,100);let mut b=a.clone();b.row.time_left_ms=1;assert!(lifecycle_same(&a,&b));b.row.highest_bid=1;assert!(!lifecycle_same(&a,&b));}
    #[test] fn malformed_owner_lists_fail_closed(){assert!(lifecycle_rows(&[]).is_err());let mut p=vec![0u8;8];p[0]=1;assert!(lifecycle_rows(&p).is_err());let mut p=vec![0u8;9];assert!(lifecycle_rows(&p).is_err());p.pop();assert!(lifecycle_rows(&p).is_ok());}
    #[test] fn protocol_serializers_match_vanilla(){use wow_world_messages::vanilla::*;let mut p=Vec::new();CMSG_AUCTION_SELL_ITEM{auctioneer:1u64.into(),item:2u64.into(),starting_bid:3,buyout:4,auction_duration_in_minutes:120}.write_unencrypted_client(&mut p).unwrap();assert_eq!(p.len(),34);assert_eq!(&p[2..6],&0x256u32.to_le_bytes());assert_eq!(&p[30..34],&120u32.to_le_bytes());p.clear();CMSG_AUCTION_REMOVE_ITEM{auctioneer:1u64.into(),auction_id:2}.write_unencrypted_client(&mut p).unwrap();assert_eq!(p.len(),18);p.clear();CMSG_AUCTION_LIST_OWNER_ITEMS{auctioneer:1u64.into(),list_from:50}.write_unencrypted_client(&mut p).unwrap();assert_eq!(p.len(),18);}
}
