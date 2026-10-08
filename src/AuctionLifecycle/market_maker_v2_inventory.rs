//! Stateful Vanilla 1.12 object/inventory tracker for Market Maker V2.
//! It deliberately does not depend on stateless UpdateMask type inference.
use std::cell::RefCell as Mm2RefCell;

const MM2_SMSG_UPDATE_OBJECT:u16=0x00A9;
const MM2_SMSG_COMPRESSED_UPDATE_OBJECT:u16=0x01F6;
const MM2_SMSG_DESTROY_OBJECT:u16=0x00AA;
const MM2_SMSG_ITEM_PUSH_RESULT:u16=0x0166;
const MM2_OBJECT_FIELD_ENTRY:u16=3;
const MM2_ITEM_FIELD_OWNER:u16=6;
const MM2_ITEM_FIELD_CONTAINED:u16=8;
const MM2_ITEM_FIELD_STACK_COUNT:u16=14;
const MM2_CONTAINER_FIELD_NUM_SLOTS:u16=48;
const MM2_CONTAINER_FIELD_SLOT_1:u16=50;
const MM2_PLAYER_FIELD_INV_SLOT_HEAD:u16=486;
const MM2_PLAYER_FIELD_PACK_SLOT_1:u16=532;
const MM2_BACKPACK_BAG:u8=255;
const MM2_BACKPACK_FIRST_SLOT:u8=23;
const MM2_BACKPACK_SLOTS:u8=16;
const MM2_EQUIPPED_BAG_FIRST_SLOT:u8=19;
const MM2_EQUIPPED_BAG_COUNT:u8=4;

#[derive(Clone,Copy,Debug,PartialEq,Eq)]
struct Mm2PhysicalSlot { bag:u8, slot:u8 }
#[derive(Clone,Debug,Default)]
struct Mm2ObjectState { object_type:Option<u8>, fields:std::collections::HashMap<u16,u32> }
#[derive(Clone,Debug,PartialEq,Eq)]
struct Mm2ItemView { guid:u64,item_id:u32,count:u32,owner:u64,contained:u64,physical:Mm2PhysicalSlot }
#[derive(Clone,Debug,Default)]
struct Mm2PushEvidence { seq:u64,receiver:u64,bag:u8,slot:u32,item_id:u32,count:u32 }
#[derive(Clone,Debug,Default)]
struct Mm2InventoryState {
    player:u64,
    objects:std::collections::HashMap<u64,Mm2ObjectState>,
    slots:std::collections::HashMap<Mm2PhysicalSlot,u64>,
    reverse:std::collections::HashMap<u64,Mm2PhysicalSlot>,
    pushes:Vec<Mm2PushEvidence>,
    push_seq:u64,
    generation:u64,
    degraded:Option<String>,
}
thread_local! { static MM2_INV:Mm2RefCell<Mm2InventoryState>=Mm2RefCell::new(Mm2InventoryState::default()); }

fn mm2_inv_enabled()->bool{std::env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default()=="marketmaker2"}
fn market_maker_v2_inventory_bind(player:u64){MM2_INV.with(|s|*s.borrow_mut()=Mm2InventoryState{player,..Default::default()});}
fn mm2_need(buf:&[u8],p:usize,n:usize)->Result<(),String>{if p.checked_add(n).is_some_and(|e|e<=buf.len()){Ok(())}else{Err("MM2 inventory packet truncated".into())}}
fn mm2_u8(buf:&[u8],p:&mut usize)->Result<u8,String>{mm2_need(buf,*p,1)?;let v=buf[*p];*p+=1;Ok(v)}
fn mm2_u32(buf:&[u8],p:&mut usize)->Result<u32,String>{mm2_need(buf,*p,4)?;let v=u32::from_le_bytes(buf[*p..*p+4].try_into().unwrap());*p+=4;Ok(v)}
fn mm2_skip(buf:&[u8],p:&mut usize,n:usize)->Result<(),String>{mm2_need(buf,*p,n)?;*p+=n;Ok(())}
fn mm2_packed_guid(buf:&[u8],p:&mut usize)->Result<u64,String>{let mask=mm2_u8(buf,p)?;let mut g=0u64;for i in 0..8{if mask&(1<<i)!=0{g|=u64::from(mm2_u8(buf,p)?)<<(8*i);}}Ok(g)}
fn mm2_guid_field(fields:&std::collections::HashMap<u16,u32>,base:u16)->u64{u64::from(fields.get(&base).copied().unwrap_or(0))|(u64::from(fields.get(&(base+1)).copied().unwrap_or(0))<<32)}

fn mm2_skip_movement(buf:&[u8],p:&mut usize)->Result<(),String>{
    let uf=mm2_u8(buf,p)?;
    if uf&0x20!=0 {
        let flags=mm2_u32(buf,p)?;mm2_skip(buf,p,4+16)?;
        if flags&0x00000200!=0{let _=mm2_packed_guid(buf,p)?;mm2_skip(buf,p,16)?;}
        if flags&0x00200000!=0{mm2_skip(buf,p,4)?;}
        mm2_skip(buf,p,4)?;
        if flags&0x00002000!=0{mm2_skip(buf,p,16)?;}
        if flags&0x04000000!=0{mm2_skip(buf,p,4)?;}
        mm2_skip(buf,p,24)?;
        if flags&0x00400000!=0{
            let sf=mm2_u32(buf,p)?;
            if sf&0x00040000!=0{mm2_skip(buf,p,4)?;}else if sf&0x00020000!=0{mm2_skip(buf,p,8)?;}else if sf&0x00010000!=0{mm2_skip(buf,p,12)?;}
            mm2_skip(buf,p,12)?;let nodes=mm2_u32(buf,p)?;if nodes>4096{return Err("MM2 spline node cap".into());}mm2_skip(buf,p,(nodes as usize).checked_mul(12).ok_or("MM2 spline overflow")?)?;mm2_skip(buf,p,12)?;
        }
    } else if uf&0x40!=0 {mm2_skip(buf,p,16)?;}
    if uf&0x08!=0{mm2_skip(buf,p,4)?;}if uf&0x10!=0{mm2_skip(buf,p,4)?;}if uf&0x04!=0{let _=mm2_packed_guid(buf,p)?;}if uf&0x02!=0{mm2_skip(buf,p,4)?;}Ok(())
}
fn mm2_update_mask(buf:&[u8],p:&mut usize)->Result<Vec<(u16,u32)>,String>{
    let blocks=usize::from(mm2_u8(buf,p)?);if blocks>64{return Err("MM2 update-mask block cap".into());}
    let mut masks=Vec::with_capacity(blocks);for _ in 0..blocks{masks.push(mm2_u32(buf,p)?);}let mut out=Vec::new();
    for (bi,m) in masks.into_iter().enumerate(){for bit in 0..32{if m&(1u32<<bit)!=0{let idx=bi.checked_mul(32).and_then(|x|x.checked_add(bit)).ok_or("MM2 field overflow")?;if idx>u16::MAX as usize{return Err("MM2 field index cap".into());}out.push((idx as u16,mm2_u32(buf,p)?));}}}Ok(out)
}
fn mm2_apply_fields(state:&mut Mm2InventoryState,guid:u64,object_type:Option<u8>,fields:Vec<(u16,u32)>,replace:bool){
    let o=state.objects.entry(guid).or_default();if replace{o.fields.clear();}if object_type.is_some(){o.object_type=object_type;}for(k,v)in fields{o.fields.insert(k,v);}state.generation=state.generation.saturating_add(1);
}
fn mm2_remove(state:&mut Mm2InventoryState,guid:u64){state.objects.remove(&guid);if let Some(slot)=state.reverse.remove(&guid){state.slots.remove(&slot);}state.generation=state.generation.saturating_add(1);}
fn mm2_rebuild_slots(state:&mut Mm2InventoryState){
    state.slots.clear();state.reverse.clear();let Some(player)=state.objects.get(&state.player) else{return;};
    for i in 0..MM2_BACKPACK_SLOTS{let base=MM2_PLAYER_FIELD_PACK_SLOT_1+u16::from(i)*2;let g=mm2_guid_field(&player.fields,base);if g!=0{let s=Mm2PhysicalSlot{bag:MM2_BACKPACK_BAG,slot:MM2_BACKPACK_FIRST_SLOT+i};state.slots.insert(s,g);state.reverse.insert(g,s);}}
    let mut bags=Vec::new();for i in 0..MM2_EQUIPPED_BAG_COUNT{let inv_slot=MM2_EQUIPPED_BAG_FIRST_SLOT+i;let base=MM2_PLAYER_FIELD_INV_SLOT_HEAD+u16::from(inv_slot)*2;let g=mm2_guid_field(&player.fields,base);if g!=0{bags.push((inv_slot,g));}}
    for(bag_slot,bag_guid)in bags{if let Some(bag)=state.objects.get(&bag_guid){let n=bag.fields.get(&MM2_CONTAINER_FIELD_NUM_SLOTS).copied().unwrap_or(0).min(36);for i in 0..n{let base=MM2_CONTAINER_FIELD_SLOT_1+(i as u16)*2;let g=mm2_guid_field(&bag.fields,base);if g!=0{let s=Mm2PhysicalSlot{bag:bag_slot,slot:i as u8};state.slots.insert(s,g);state.reverse.insert(g,s);}}}}
}
fn mm2_parse_update_body(state:&mut Mm2InventoryState,buf:&[u8])->Result<(),String>{
    let mut p=0usize;let count=mm2_u32(buf,&mut p)?;if count>10000{return Err("MM2 update object count cap".into());}let _has_transport=mm2_u8(buf,&mut p)?;
    for _ in 0..count{match mm2_u8(buf,&mut p)?{
        0=>{let g=mm2_packed_guid(buf,&mut p)?;let f=mm2_update_mask(buf,&mut p)?;mm2_apply_fields(state,g,None,f,false);},
        1=>{let _=mm2_packed_guid(buf,&mut p)?;mm2_skip_movement(buf,&mut p)?;},
        2|3=>{let g=mm2_packed_guid(buf,&mut p)?;let typ=mm2_u8(buf,&mut p)?;mm2_skip_movement(buf,&mut p)?;let f=mm2_update_mask(buf,&mut p)?;mm2_apply_fields(state,g,Some(typ),f,true);},
        // OUT_OF_RANGE invalidates object authority. NEAR_OBJECTS is only a proximity hint and
        // must never delete state; confusing the two can erase valid inventory/world evidence.
        4=>{let n=mm2_u32(buf,&mut p)?;if n>10000{return Err("MM2 guid list cap".into());}for _ in 0..n{let g=mm2_packed_guid(buf,&mut p)?;if g!=0{mm2_remove(state,g);}}},
        5=>{let n=mm2_u32(buf,&mut p)?;if n>10000{return Err("MM2 guid list cap".into());}for _ in 0..n{let _=mm2_packed_guid(buf,&mut p)?;}},
        x=>return Err(format!("MM2 unknown update type {x}")),
    }}
    if p!=buf.len(){return Err(format!("MM2 update trailing bytes {}",buf.len()-p));}mm2_rebuild_slots(state);Ok(())
}
fn mm2_decompress_update(payload:&[u8])->Result<Vec<u8>,String>{
    if payload.len()<5{return Err("MM2 compressed update short".into());}let expected=u32::from_le_bytes(payload[..4].try_into().unwrap()) as usize;if expected<5||expected>4*1024*1024{return Err("MM2 compressed size cap".into());}
    let mut z=flate2::read::ZlibDecoder::new(&payload[4..]);let mut out=Vec::with_capacity(expected);std::io::Read::read_to_end(&mut z,&mut out).map_err(|e|format!("MM2 zlib: {e}"))?;if out.len()!=expected{return Err(format!("MM2 decompressed size mismatch {} != {expected}",out.len()));}Ok(out)
}
fn market_maker_v2_observe_raw(op:u16,payload:&[u8]){
    if !mm2_inv_enabled(){return;}MM2_INV.with(|cell|{let mut s=cell.borrow_mut();let r=match op{
        MM2_SMSG_UPDATE_OBJECT=>mm2_parse_update_body(&mut s,payload),
        MM2_SMSG_COMPRESSED_UPDATE_OBJECT=>mm2_decompress_update(payload).and_then(|b|mm2_parse_update_body(&mut s,&b)),
        MM2_SMSG_DESTROY_OBJECT=>{if payload.len()>=8{let g=u64::from_le_bytes(payload[..8].try_into().unwrap());mm2_remove(&mut s,g);mm2_rebuild_slots(&mut s);Ok(())}else{Err("MM2 destroy short".into())}},
        MM2_SMSG_ITEM_PUSH_RESULT=>{if payload.len()==41{let receiver=u64::from_le_bytes(payload[0..8].try_into().unwrap());let bag=payload[20];let slot=u32::from_le_bytes(payload[21..25].try_into().unwrap());let item_id=u32::from_le_bytes(payload[25..29].try_into().unwrap());let count=u32::from_le_bytes(payload[37..41].try_into().unwrap());s.push_seq=s.push_seq.saturating_add(1);let seq=s.push_seq;s.pushes.push(Mm2PushEvidence{seq,receiver,bag,slot,item_id,count});if s.pushes.len()>128{s.pushes.drain(..s.pushes.len()-128);}Ok(())}else{Ok(())}},
        _=>Ok(()),};if let Err(e)=r{if matches!(op,MM2_SMSG_UPDATE_OBJECT|MM2_SMSG_COMPRESSED_UPDATE_OBJECT){s.degraded=Some(e.clone());println!("[MM2-INVENTORY] DEGRADED {e}");}}});
}
fn mm2_inventory_healthy()->Result<(),String>{MM2_INV.with(|s|s.borrow().degraded.clone().map_or(Ok(()),|e|Err(format!("MM2 inventory degraded: {e}"))))}
fn mm2_item_view(guid:u64)->Result<Mm2ItemView,String>{MM2_INV.with(|cell|{let s=cell.borrow();if let Some(e)=&s.degraded{return Err(format!("MM2 inventory degraded: {e}"));}let o=s.objects.get(&guid).ok_or("MM2 item GUID unknown")?;if !matches!(o.object_type,Some(1|2)){return Err("MM2 GUID is not item/container".into());}let item_id=o.fields.get(&MM2_OBJECT_FIELD_ENTRY).copied().unwrap_or(0);let count=o.fields.get(&MM2_ITEM_FIELD_STACK_COUNT).copied().unwrap_or(0);let owner=mm2_guid_field(&o.fields,MM2_ITEM_FIELD_OWNER);let contained=mm2_guid_field(&o.fields,MM2_ITEM_FIELD_CONTAINED);let physical=*s.reverse.get(&guid).ok_or("MM2 item has no proven physical slot")?;if item_id==0||count==0||owner!=s.player{return Err("MM2 item identity/owner/stack incomplete".into());}Ok(Mm2ItemView{guid,item_id,count,owner,contained,physical})})}
fn mm2_inventory_items(item_id:u32)->Result<Vec<Mm2ItemView>,String>{MM2_INV.with(|cell|{let s=cell.borrow();if let Some(e)=&s.degraded{return Err(format!("MM2 inventory degraded: {e}"));}let guids=s.reverse.keys().copied().collect::<Vec<_>>();drop(s);let mut out=Vec::new();for g in guids{if let Ok(v)=mm2_item_view(g){if v.item_id==item_id{out.push(v);}}}out.sort_by_key(|x|(x.physical.bag,x.physical.slot,x.guid));Ok(out)})}
fn mm2_empty_backpack_slot()->Result<Mm2PhysicalSlot,String>{MM2_INV.with(|cell|{let s=cell.borrow();if let Some(e)=&s.degraded{return Err(format!("MM2 inventory degraded: {e}"));}for i in 0..MM2_BACKPACK_SLOTS{let slot=Mm2PhysicalSlot{bag:MM2_BACKPACK_BAG,slot:MM2_BACKPACK_FIRST_SLOT+i};if !s.slots.contains_key(&slot){return Ok(slot);}}Err("MM2 no proven empty backpack slot".into())})}
fn mm2_inventory_generation()->u64{MM2_INV.with(|s|s.borrow().generation)}
fn mm2_push_seq()->u64{MM2_INV.with(|s|s.borrow().push_seq)}
fn mm2_push_after(seq:u64,item_id:u32)->Vec<Mm2PushEvidence>{MM2_INV.with(|s|s.borrow().pushes.iter().filter(|p|p.seq>seq&&p.item_id==item_id).cloned().collect())}

#[cfg(test)]mod mm2_inv_tests{
    use super::*;
    fn mask(fields:&[(u16,u32)])->Vec<u8>{let blocks=fields.iter().map(|x|x.0 as usize/32+1).max().unwrap_or(1);let mut masks=vec![0u32;blocks];for(i,_)in fields{masks[*i as usize/32]|=1u32<<(*i as usize%32);}let mut v=vec![blocks as u8];for m in &masks{v.extend_from_slice(&m.to_le_bytes());}for bi in 0..blocks{for bit in 0..32{let idx=(bi*32+bit)as u16;if masks[bi]&(1<<bit)!=0{v.extend_from_slice(&fields.iter().find(|x|x.0==idx).unwrap().1.to_le_bytes());}}}v}
    fn pg(g:u64)->Vec<u8>{let mut m=0u8;let mut b=Vec::new();for i in 0..8{let x=((g>>(8*i))&0xff)as u8;if x!=0{m|=1<<i;b.push(x);}}let mut v=vec![m];v.extend(b);v}
    #[test]fn tracks_backpack_item_from_create_and_incremental_values(){let player=0x11u64;market_maker_v2_inventory_bind(player);let item=0x22u64;let mut body=Vec::new();body.extend_from_slice(&2u32.to_le_bytes());body.push(0);
        body.push(3);body.extend(pg(player));body.push(4);body.push(0);let pf=vec![(MM2_PLAYER_FIELD_PACK_SLOT_1,item as u32),(MM2_PLAYER_FIELD_PACK_SLOT_1+1,(item>>32)as u32)];body.extend(mask(&pf));
        body.push(2);body.extend(pg(item));body.push(1);body.push(0);let f=vec![(MM2_OBJECT_FIELD_ENTRY,777),(MM2_ITEM_FIELD_OWNER,player as u32),(MM2_ITEM_FIELD_OWNER+1,(player>>32)as u32),(MM2_ITEM_FIELD_STACK_COUNT,3)];body.extend(mask(&f));
        MM2_INV.with(|s|{let mut st=s.borrow_mut();mm2_parse_update_body(&mut st,&body).unwrap();});let v=mm2_item_view(item).unwrap();assert_eq!(v.item_id,777);assert_eq!(v.count,3);assert_eq!(v.physical,Mm2PhysicalSlot{bag:255,slot:23});
        let mut upd=Vec::new();upd.extend_from_slice(&1u32.to_le_bytes());upd.push(0);upd.push(0);upd.extend(pg(item));upd.extend(mask(&[(MM2_ITEM_FIELD_STACK_COUNT,2)]));MM2_INV.with(|s|mm2_parse_update_body(&mut s.borrow_mut(),&upd).unwrap());assert_eq!(mm2_item_view(item).unwrap().count,2);}
    #[test]fn near_objects_does_not_delete_authoritative_state(){let guid=0x1122u64;let mut s=Mm2InventoryState::default();s.objects.insert(guid,Mm2ObjectState{object_type:Some(1),fields:std::collections::HashMap::new()});let mut body=Vec::new();body.extend_from_slice(&1u32.to_le_bytes());body.push(0);body.push(5);body.extend_from_slice(&1u32.to_le_bytes());body.extend(pg(guid));mm2_parse_update_body(&mut s,&body).unwrap();assert!(s.objects.contains_key(&guid));}
    #[test]fn out_of_range_deletes_authoritative_state(){let guid=0x1122u64;let mut s=Mm2InventoryState::default();s.objects.insert(guid,Mm2ObjectState{object_type:Some(1),fields:std::collections::HashMap::new()});let mut body=Vec::new();body.extend_from_slice(&1u32.to_le_bytes());body.push(0);body.push(4);body.extend_from_slice(&1u32.to_le_bytes());body.extend(pg(guid));mm2_parse_update_body(&mut s,&body).unwrap();assert!(!s.objects.contains_key(&guid));}
}
