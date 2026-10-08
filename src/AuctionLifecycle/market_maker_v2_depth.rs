//! Wire-targeted exact-item depth for Market Maker V2.
//! Vanilla auction browse targets by item name, not entry id. Resolve the item name read-only,
//! issue a name-filtered query, then filter every returned row by item_id + signature.
use crate::market_maker_v2_policy as mm2_policy;

const MM2_CMSG_ITEM_QUERY_SINGLE:u32=0x0056;
const MM2_SMSG_ITEM_QUERY_SINGLE_RESPONSE:u16=0x0058;
const MM2_TARGETED_DEPTH_TOTAL:Mm2Duration=Mm2Duration::from_secs(8);

#[derive(Clone,Debug)]
struct Mm2DepthSnapshot {
    item_id:u32,
    signature:[u32;3],
    item_name:String,
    observed_at:Mm2Instant,
    rows:Vec<LifecycleAuction>,
    complete:bool,
    coherent:bool,
    raw_total:u32,
}

fn mm2_item_name_from_response(payload:&[u8],expected:u32)->Result<Option<String>,String>{
    if payload.len()<4{return Err("MM2 item-query response short".into());}
    let wire=u32::from_le_bytes(payload[0..4].try_into().unwrap());
    if wire&0x7fff_ffff!=expected{return Ok(None);}
    if wire&0x8000_0000!=0{return Err(format!("MM2 item {expected} not found"));}
    if payload.len()<13{return Err("MM2 item-query found body short".into());}
    let rest=&payload[12..];
    let end=rest.iter().position(|b|*b==0).ok_or("MM2 item name missing terminator")?;
    if end==0||end>255{return Err("MM2 item name empty/oversized".into());}
    let name=std::str::from_utf8(&rest[..end]).map_err(|_|"MM2 item name non-utf8")?.to_string();
    Ok(Some(name))
}

fn mm2_resolve_item_name(stream:&mut TcpStream,crypto:&mut HeaderCrypto,item_id:u32)->Result<String,String>{
    if item_id==0{return Err("MM2 zero item id".into());}
    let mut payload=Vec::with_capacity(12);
    payload.extend_from_slice(&item_id.to_le_bytes());
    payload.extend_from_slice(&0u64.to_le_bytes());
    write_encrypted_raw(stream,crypto.encrypter(),MM2_CMSG_ITEM_QUERY_SINGLE,&payload)?;
    let deadline=Mm2Instant::now()+Mm2Duration::from_secs(3);
    mm2_wait_for(stream,crypto,deadline,"depth/item-name",|op,p|{
        if op!=MM2_SMSG_ITEM_QUERY_SINGLE_RESPONSE{return Ok(None);}
        mm2_item_name_from_response(p,item_id)
    })
}

fn mm2_build_named_auction_query(auctioneer:u64,list_from:u32,name:&str)->Result<Vec<u8>,String>{
    if name.is_empty()||name.as_bytes().contains(&0){return Err("MM2 invalid auction item name".into());}
    let mut q=Vec::with_capacity(32+name.len());
    q.extend_from_slice(&auctioneer.to_le_bytes());
    q.extend_from_slice(&list_from.to_le_bytes());
    q.extend_from_slice(name.as_bytes());q.push(0);
    q.push(0);q.push(0);
    q.extend_from_slice(&u32::MAX.to_le_bytes());q.extend_from_slice(&u32::MAX.to_le_bytes());
    q.extend_from_slice(&u32::MAX.to_le_bytes());q.extend_from_slice(&u32::MAX.to_le_bytes());
    q.push(0);
    Ok(q)
}

fn mm2_targeted_page(stream:&mut TcpStream,crypto:&mut HeaderCrypto,auctioneer:u64,page:u32,name:&str,total_deadline:Mm2Instant)->Result<(Vec<LifecycleAuction>,u32),String>{
    if Mm2Instant::now()>=total_deadline{return Err("MM2 targeted depth wall-clock deadline before page".into());}
    let list_from=page.checked_mul(50).ok_or("MM2 targeted page overflow")?;
    let q=mm2_build_named_auction_query(auctioneer,list_from,name)?;
    write_encrypted_raw(stream,crypto.encrypter(),CMSG_AUCTION_LIST_ITEMS_OPCODE,&q)?;
    let deadline=std::cmp::min(total_deadline,Mm2Instant::now()+Mm2Duration::from_secs(4));
    mm2_wait_for(stream,crypto,deadline,&format!("depth/page-{page}"),|op,p|{
        if op!=SMSG_AUCTION_LIST_RESULT_OPCODE{return Ok(None);}
        let(rows,total)=lifecycle_rows(p)?;
        Ok(Some((rows,total)))
    })
}

fn mm2_targeted_depth(stream:&mut TcpStream,crypto:&mut HeaderCrypto,auctioneer:u64,item_id:u32,signature:[u32;3],max_pages:u32)->Result<Mm2DepthSnapshot,String>{
    if max_pages==0||max_pages>128{return Err("MM2 targeted max_pages outside 1..=128".into());}
    let started=Mm2Instant::now();
    let total_deadline=started+MM2_TARGETED_DEPTH_TOTAL;
    let name=mm2_resolve_item_name(stream,crypto,item_id)?;
    if Mm2Instant::now()>=total_deadline{return Err("MM2 targeted depth wall-clock deadline after item name".into());}
    let mut rows=std::collections::HashMap::<u32,LifecycleAuction>::new();
    let mut expected_total=None;let mut complete=false;let mut coherent=true;let mut raw_total=0;
    for page in 0..max_pages{
        let(page_rows,total)=mm2_targeted_page(stream,crypto,auctioneer,page,&name,total_deadline)?;
        raw_total=raw_total.max(total);
        if expected_total.is_some_and(|x|x!=total){coherent=false;}else if expected_total.is_none(){expected_total=Some(total);}
        for r in page_rows{
            if r.row.auction_id==0||r.row.count==0{continue;}
            if r.row.item_id!=item_id||r.signature!=signature{continue;}
            match rows.get(&r.row.auction_id){
                Some(old) if !lifecycle_same(old,&r)=>return Err("MM2 targeted conflicting duplicate auction".into()),
                Some(_)=>{},None=>{rows.insert(r.row.auction_id,r);}
            }
        }
        if (page+1).saturating_mul(50)>=total{complete=true;break;}
        if Mm2Instant::now()>=total_deadline{return Err("MM2 targeted depth wall-clock deadline during pagination".into());}
    }
    let mut rows=rows.into_values().collect::<Vec<_>>();rows.sort_by_key(|r|r.row.auction_id);
    println!("[MM2-DEPTH] item={item_id} name={name:?} sig={signature:?} exact_rows={} raw_total={raw_total} complete={} coherent={} ms={}",rows.len(),complete,coherent,started.elapsed().as_millis());
    Ok(Mm2DepthSnapshot{item_id,signature,item_name:name,observed_at:started,rows,complete,coherent,raw_total})
}

fn mm2_depth_view(snapshot:&Mm2DepthSnapshot,own_auction_id:u32)->mm2_policy::DepthView{
    mm2_policy::DepthView{
        source:mm2_policy::DepthSource::Targeted,
        complete:snapshot.complete,
        coherent:snapshot.coherent,
        age_ms:snapshot.observed_at.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
        own_row_seen:snapshot.rows.iter().any(|r|r.row.auction_id==own_auction_id),
        rows:snapshot.rows.iter().map(|r|mm2_policy::Quote{auction_id:r.row.auction_id,owner_guid:r.row.owner_guid,buyout:r.row.buyout,count:r.row.count}).collect(),
    }
}
fn mm2_exact_auction(snapshot:&Mm2DepthSnapshot,auction_id:u32)->Option<&LifecycleAuction>{snapshot.rows.iter().find(|r|r.row.auction_id==auction_id)}

#[cfg(test)]mod tests{
    use super::*;
    #[test]fn named_query_is_not_any_query(){
        let name="Greater Eternal Essence";
        let q=mm2_build_named_auction_query(0x1122,50,name).unwrap();
        assert_eq!(&q[..8],&0x1122u64.to_le_bytes());assert_eq!(&q[8..12],&50u32.to_le_bytes());
        assert_eq!(&q[12..12+name.len()],name.as_bytes());assert_eq!(q[12+name.len()],0);
    }
    #[test]fn parses_vanilla_item_name(){let mut p=Vec::new();p.extend_from_slice(&10940u32.to_le_bytes());p.extend_from_slice(&0u64.to_le_bytes());p.extend_from_slice(b"Strange Dust\0rest");assert_eq!(mm2_item_name_from_response(&p,10940).unwrap().as_deref(),Some("Strange Dust"));}
    #[test]fn unrelated_item_response_is_ignored(){let mut p=Vec::new();p.extend_from_slice(&1u32.to_le_bytes());p.extend_from_slice(&[0;9]);assert!(mm2_item_name_from_response(&p,2).unwrap().is_none());}
    #[test]fn not_found_fails(){let p=(10940u32|0x8000_0000).to_le_bytes();assert!(mm2_item_name_from_response(&p,10940).is_err());}
    #[test]fn total_depth_budget_is_tighter_than_page_product(){assert!(MM2_TARGETED_DEPTH_TOTAL<Mm2Duration::from_secs(16*4));}
}
