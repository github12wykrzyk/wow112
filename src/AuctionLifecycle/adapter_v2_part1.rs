// Included into the canonical terminal module; all transport/login/BUY remain canonical.
use crate::auction_mutations::{self as mutations, Kind as MutationKind};
use std::cell::RefCell;

#[derive(Default)]
struct LifecycleObserved {
    player: u64, inventory: Poc05Snapshot, inventory_bad: bool,
    last_market: Option<Vec<u8>>, verified_items: HashSet<u64>,
    base: LifecycleBaselineFacts,
    inv: LifecycleInvTracker,
    verified_containers: HashSet<u64>,
}
thread_local! { static LIFE_OBSERVED: RefCell<LifecycleObserved> = RefCell::new(LifecycleObserved::default()); }
fn lifecycle_enabled()->bool { env::var("WOW112_LIFECYCLE_ACTION").map(|x| !x.is_empty() && x!="off").unwrap_or(false) }
fn lifecycle_bind(player:u64,realm:u32)->Result<mutations::Session,String> {
    let server=env::var("WOW112_SERVER_ID").unwrap_or_else(|_|"octowow".into());
    let session=mutations::bind(&server,realm,player)?;
    LIFE_OBSERVED.with(|s| *s.borrow_mut()=LifecycleObserved {player,..Default::default()});
    Ok(session)
}
// Panic-guarded getter (partial GUID fields make the typed getters panic); Err = partial/garbled.
fn lifecycle_guarded<T>(f:impl FnOnce()->T)->Result<T,()> {
    let previous_hook=std::panic::take_hook();
    std::panic::set_hook(Box::new(|_|{}));
    let r=std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
    std::panic::set_hook(previous_hook);
    r.map_err(|_|())
}
// Typed path used by the login loop: object blocks are parsed but their raw bytes are not
// available, so container slot lists seen here are marked unknown (never assumed empty).
fn lifecycle_observe_message(message:&ServerOpcodeMessage) { lifecycle_observe_message_inner(message,false); }
fn lifecycle_observe_message_inner(message:&ServerOpcodeMessage,via_raw:bool) {
    if !lifecycle_enabled() {return;}
    LIFE_OBSERVED.with(|s| {
        let mut s=s.borrow_mut(); let player=s.player;
        match message {
            ServerOpcodeMessage::SMSG_UPDATE_OBJECT(m)=>poc05_capture_objects(&m.objects,player,&mut s.inventory,&mut HashSet::new(),&mut HashSet::new()),
            ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(m)=>poc05_capture_objects(&m.objects,player,&mut s.inventory,&mut HashSet::new(),&mut HashSet::new()),
            _=>{}
        }
    });
    let objects = match message {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(m) => Some(&m.objects),
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(m) => Some(&m.objects),
        _ => None,
    };
    if let Some(objects)=objects { LIFE_OBSERVED.with(|s| {
        let mut s=s.borrow_mut();
        s.base.parsed_updates=s.base.parsed_updates.saturating_add(1);
        for object in objects {
            let (guid,mask,is_create)=match object {
                Object::Values{guid1,mask1} => (guid1.guid(),mask1,false),
                Object::CreateObject{guid3,mask2,..}|Object::CreateObject2{guid3,mask2,..} => (guid3.guid(),mask2,true),
                _=>continue,
            };
            if let UpdateMask::Player(p)=mask { if guid==s.player {
                let mut slots=[None;LIFECYCLE_INV_SLOTS];
                let mut garbled=false;
                for i in 0..LIFECYCLE_INV_SLOTS {
                    if let Ok(slot)=wow_world_messages::vanilla::ItemSlot::try_from(i as u8) {
                        match lifecycle_guarded(||p.player_field_inv(slot).map(|g|g.guid())) { Ok(v)=>slots[i]=v, Err(())=>garbled=true }
                    }
                }
                if garbled { lifecycle_baseline_note_uncertain(&mut s.base,"player inventory slot GUID partially present".into()); }
                if is_create { s.inv.player_create(&slots); } else { s.inv.player_values(&slots); }
            } }
            if let UpdateMask::Container(c)=mask {
                let owner=poc05_guarded_owner_guid(guid,"lifecycle-container",||c.item_owner().map(|g|g.guid()));
                if owner.is_some_and(|o|o!=s.player) {
                    s.verified_containers.remove(&guid);s.inventory.items.remove(&guid);s.inv.remove(guid);
                } else if owner==Some(s.player)&&c.object_entry().is_some_and(|n|n>0) {
                    s.verified_containers.insert(guid);
                }
                if !via_raw { s.inv.container_unknown(guid); }
            }
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
        LIFE_OBSERVED.with(|s| {let mut s=s.borrow_mut();s.inventory.items.remove(&guid);s.verified_items.remove(&guid);s.verified_containers.remove(&guid);s.inv.remove(guid);});
    }
    if matches!(op,SMSG_UPDATE_OBJECT_OPCODE|SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE) {
        match parse_raw_server_message(op,payload) {
            Ok(m)=>{lifecycle_observe_message_inner(&m,true);lifecycle_observe_container_blocks(op,payload,&m);}
            Err(_)=>lifecycle_note_unparsed_update(op,payload),
        }
    }
}
fn lifecycle_note_unparsed_update(op:u16,payload:&[u8]) {
    let compressed=op==SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE;
    LIFE_OBSERVED.with(|s| {
        let mut s=s.borrow_mut();
        match lifecycle_classify_unparsed_update(compressed,payload,s.player) {
            LifecycleUnparsed::Irrelevant=>{s.base.irrelevant_unparsed=s.base.irrelevant_unparsed.saturating_add(1);}
            LifecycleUnparsed::Relevant(why)=>{
                s.inventory.items.clear();s.verified_items.clear();s.verified_containers.clear();s.inventory_bad=false;
                lifecycle_baseline_note_uncertain(&mut s.base,why);
            }
        }
    });
}
fn lifecycle_object_summaries(m:&ServerOpcodeMessage)->Vec<(Option<u64>,bool)> {
    let objects=match m {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(x)=>&x.objects,
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(x)=>&x.objects,
        _=>return Vec::new(),
    };
    objects.iter().map(|o| match o {
        Object::Values{guid1,mask1}=>(Some(guid1.guid()),matches!(mask1,UpdateMask::Container(_))),
        Object::CreateObject{guid3,mask2,..}|Object::CreateObject2{guid3,mask2,..}=>(Some(guid3.guid()),matches!(mask2,UpdateMask::Container(_))),
        _=>(None,false),
    }).collect()
}
fn lifecycle_observe_container_blocks(op:u16,payload:&[u8],m:&ServerOpcodeMessage) {
    if !lifecycle_enabled() {return;}
    let objs=lifecycle_object_summaries(m);
    let walk=lifecycle_walk_update_payload(op==SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE,payload);
    LIFE_OBSERVED.with(|s| {
        let mut s=s.borrow_mut();
        for ev in &walk.events { s.inv.apply_event(ev); }
        let hidden:Vec<u64>=match walk.stopped_at {
            Some(k)=>objs.iter().skip(k).filter_map(|(g,container_mask)|{
                let g=(*g)?;
                if g>>48==0x4000 && (*container_mask || s.inv.containers.contains_key(&g)) {Some(g)} else {None}
            }).collect(),
            None=>Vec::new(),
        };
        if !hidden.is_empty() {
            let why=format!("container block(s) {hidden:x?} beyond byte walker stop: {} [len={}]",walk.reason,payload.len());
            lifecycle_baseline_note_uncertain(&mut s.base,why);
        } else if walk.stopped_at.is_none() && walk.total!=objs.len() {
            lifecycle_baseline_note_uncertain(&mut s.base,format!("walker/typed block count mismatch {} != {}",walk.total,objs.len()));
        }
    });
}
fn lifecycle_baseline_cache()->(Vec<LifecycleBaselineItem>,LifecycleBaselineFacts,LifecycleInvTracker) {
    LIFE_OBSERVED.with(|s| {
        let s=s.borrow();
        let cache:Vec<LifecycleBaselineItem>=s.inventory.items.iter().map(|(g,e)|LifecycleBaselineItem{
            guid:*g,entry:e.entry,stack:e.stack,
            verified:s.verified_items.contains(g)||s.verified_containers.contains(g),
            container:e.kind=="container"||s.inv.containers.contains_key(g),
        }).collect();
        (cache,s.base.clone(),s.inv.clone())
    })
}
fn lifecycle_baseline_verdict_now(item:u32)->LifecycleBaselineVerdict {
    let (cache,facts,inv)=lifecycle_baseline_cache();
    lifecycle_baseline_verdict(&facts,&inv,&cache,item)
}
fn lifecycle_baseline_log() {
    let (cache,facts,inv)=lifecycle_baseline_cache();
    println!("[LIFECYCLE-AUTO] BASELINE {}",lifecycle_baseline_summary(&facts,&inv,&cache));
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
