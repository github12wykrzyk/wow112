// Inventory/mail helpers for Market Maker V1. Included in the same module as Lifecycle.
// Fail closed if a mail attachment merges into an already existing stack: without an
// exact source slot we will not guess and will not split/post the wrong inventory.

#[derive(Clone, Debug)]
struct MmPush {
    seq: u64,
    bag: u8,
    slot: u32,
    item: u32,
    count: u32,
}

#[derive(Default)]
struct MmPushState { seq: u64, pushes: Vec<MmPush> }
thread_local! { static MM_PUSH: RefCell<MmPushState> = RefCell::new(MmPushState::default()); }

fn market_maker_observe_raw(op: u16, payload: &[u8]) {
    if env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default() != "marketmaker" { return; }
    // Vanilla SMSG_ITEM_PUSH_RESULT body: guid(8), source(4), creation(4), alert(4),
    // bag_slot(1), item_slot(4), item(4), suffix(4), random(4), item_count(4) = 41.
    if op == 0x0166 && payload.len() == 41 {
        let bag = payload[20];
        let slot = u32::from_le_bytes(payload[21..25].try_into().unwrap());
        let item = u32::from_le_bytes(payload[25..29].try_into().unwrap());
        let count = u32::from_le_bytes(payload[37..41].try_into().unwrap());
        MM_PUSH.with(|s| {
            let mut s=s.borrow_mut(); s.seq=s.seq.saturating_add(1); let seq=s.seq;
            s.pushes.push(MmPush{seq,bag,slot,item,count});
            if s.pushes.len()>128 {let n=s.pushes.len()-128;s.pushes.drain(..n);}
        });
    }
}
fn mm_push_seq()->u64 { MM_PUSH.with(|s|s.borrow().seq) }
fn mm_push_after(seq:u64,item:u32)->Option<MmPush> {
    MM_PUSH.with(|s|s.borrow().pushes.iter().rev().find(|p|p.seq>seq&&p.item==item).cloned())
}

#[derive(Clone,Debug)]
struct MmOwnedStack { guid:u64, item:u32, count:u32, bag:u8, slot:u8 }

fn mm_item_count(inv:&std::collections::HashMap<u64,Poc05InventoryEntry>,item:u32)->u64 {
    inv.values().filter(|x|x.entry>0&&x.entry as u32==item&&x.stack>0).map(|x|x.stack as u64).sum()
}

fn mm_take_mail_stack(stream:&mut TcpStream,crypto:&mut HeaderCrypto,mailbox:u64,mail:&Poc05MailRecord)->Result<MmOwnedStack,String>{
    if mail.cod!=0||mail.item==0||mail.stack==0{return Err("MARKET_MAKER invalid/COD item mail".into());}
    let item=mail.item;let amount=u32::from(mail.stack);let before=lifecycle_inventory()?;let before_total=mm_item_count(&before,item);let push_seq=mm_push_seq();
    lifecycle_mail(stream,crypto,mailbox,Poc05MailAction::TakeItem(mail.id))?;
    let after=lifecycle_inventory()?;let after_total=mm_item_count(&after,item);
    if after_total!=before_total.saturating_add(u64::from(amount)){return Err("MARKET_MAKER mail take inventory delta not exact; stop before split/post".into());}
    let changed:Vec<_>=after.iter().filter(|(g,x)|x.entry>0&&x.entry as u32==item&&x.stack>0&&before.get(g).map(|b|b.stack).unwrap_or(0)!=x.stack).collect();
    if changed.len()!=1{return Err("MARKET_MAKER mail attachment did not resolve to one exact inventory stack".into());}
    let(guid,entry)=changed[0];let old=before.get(guid).map(|x|x.stack.max(0) as u32).unwrap_or(0);
    if entry.stack as u32!=old.saturating_add(amount){return Err("MARKET_MAKER changed stack delta mismatched mail amount".into());}
    let push=mm_push_after(push_seq,item).ok_or("MARKET_MAKER missing item-push slot evidence after mail take")?;
    if push.count!=amount{return Err("MARKET_MAKER item-push amount mismatch".into());}
    // Mangos uses item_slot=0xFFFFFFFF when an item was merged into an existing stack.
    // V1 refuses to guess that stack's physical slot.
    if push.slot==u32::MAX||push.slot>u32::from(u8::MAX){return Err("MARKET_MAKER mail merged into existing stack; exact slot unavailable, no split/post performed".into());}
    Ok(MmOwnedStack{guid:*guid,item,count:entry.stack as u32,bag:push.bag,slot:push.slot as u8})
}

fn mm_inventory_delta_unit(before:&std::collections::HashMap<u64,Poc05InventoryEntry>,after:&std::collections::HashMap<u64,Poc05InventoryEntry>,source:u64,item:u32,old_source_count:u32)->Result<Option<u64>,String>{
    let src=after.get(&source).ok_or("MARKET_MAKER split source disappeared")?;
    if src.entry<=0||src.entry as u32!=item||src.stack<=0||src.stack as u32+1!=old_source_count{return Err("MARKET_MAKER split source count not reconciled".into());}
    if mm_item_count(before,item)!=mm_item_count(after,item){return Err("MARKET_MAKER split changed total item count".into());}
    let mut changed=Vec::new();
    for(g,a) in after {
        if *g==source||a.entry<=0||a.entry as u32!=item||a.stack<=0{continue;}
        let old=before.get(g).map(|x|x.stack.max(0) as u32).unwrap_or(0);
        if a.stack as u32==old.saturating_add(1){changed.push((*g,a.stack as u32,old));}
        else if a.stack as u32!=old{return Err("MARKET_MAKER split produced ambiguous multi-stack inventory delta".into());}
    }
    if changed.len()!=1{return Err("MARKET_MAKER split destination not uniquely reconciled".into());}
    let(g,new_count,old)=changed[0];
    Ok(if old==0&&new_count==1{Some(g)}else{None})
}

fn mm_split_one(stream:&mut TcpStream,crypto:&mut HeaderCrypto,source:&MmOwnedStack)->Result<u64,String>{
    if source.count<=1{return Ok(source.guid);}
    let before=lifecycle_inventory()?;
    let current=before.get(&source.guid).ok_or("MARKET_MAKER split source GUID missing")?;
    if current.entry<=0||current.entry as u32!=source.item||current.stack<=1||current.stack as u32!=source.count{return Err("MARKET_MAKER split source stale".into());}
    let mut unit_guid=None;
    mutations::transaction(MutationKind::Split,||{
        lifecycle_send(stream,crypto,wow_world_messages::vanilla::CMSG_SPLIT_ITEM{source_bag:source.bag,source_slot:source.slot,destination_bag:0,destination_slot:255,amount:1})?;
        for _ in 0..256 {
            let(op,_)=read_encrypted_raw(stream,crypto.decrypter())?;
            if op==0x0112{return Err("MARKET_MAKER split server inventory failure".into());}
            let after=lifecycle_inventory()?;
            if let Ok(v)=mm_inventory_delta_unit(&before,&after,source.guid,source.item,source.count){unit_guid=v;return Ok(());}
        }
        Err("MARKET_MAKER split sent but inventory reconciliation timed out".into())
    })?;
    unit_guid.ok_or("MARKET_MAKER split reconciled by merge, not isolated unit; stop without posting wrong stack".into())
}

fn mm_split_all_to_units(stream:&mut TcpStream,crypto:&mut HeaderCrypto,mut source:MmOwnedStack,max_units:u32)->Result<Vec<u64>,String>{
    if source.count==0||source.count>max_units{return Err("MARKET_MAKER stack exceeds guarded single-post limit".into());}
    let mut units=Vec::new();
    while source.count>1 {
        let guid=mm_split_one(stream,crypto,&source)?;units.push(guid);source.count-=1;
    }
    units.push(source.guid);
    Ok(units)
}
