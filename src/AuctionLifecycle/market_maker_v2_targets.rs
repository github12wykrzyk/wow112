//! Deterministic read-only interaction target resolution for Market Maker V2.

#[derive(Clone,Debug)]
struct Mm2Targets { auctioneer:u64, auction_house:u32, mailbox:u64 }
#[derive(Clone,Debug)]
struct Mm2MailProof { mailbox:u64, observed_at:Mm2Instant, records:Vec<Poc05MailRecord> }

fn mm2_collect_candidates(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64,window:Mm2Duration)->Result<(Vec<u64>,Vec<u64>),String>{
    let mut ah=HashSet::new();let mut mail=HashSet::new();let mut snap=Poc05Snapshot::default();
    if let Ok(v)=env::var("WOW112_AH_GUID"){ah.insert(parse_guid_override("WOW112_AH_GUID",&v)?);}if let Ok(v)=env::var("WOW112_MAILBOX_GUID"){mail.insert(parse_guid_override("WOW112_MAILBOX_GUID",&v)?);}
    let deadline=Mm2Instant::now()+window;
    loop{
        if Mm2Instant::now()>=deadline{break;}
        match mm2_read_encrypted_raw_until(stream,crypto.decrypter(),deadline,"targets/discovery"){
            Ok((op,p))=>poc05_inspect_update_packet(op,&p,player,&mut snap,&mut ah,&mut mail),
            Err(Mm2IoError::DeadlineNoBytes{..})=>break,
            Err(e)=>return Err(e.to_string()),
        }
    }
    mm2_set_normal_timeout(stream)?;let mut av=ah.into_iter().collect::<Vec<_>>();let mut mv=mail.into_iter().collect::<Vec<_>>();av.sort_unstable();mv.sort_unstable();av.dedup();mv.dedup();
    if av.is_empty(){return Err("MM2 no auctioneer candidates".into());}if mv.is_empty(){return Err("MM2 no mailbox candidates".into());}
    println!("[MM2-TARGETS] discovered auctioneers={} mailboxes={}",av.len(),mv.len());for(g_i,g)in av.iter().enumerate(){println!("[MM2-TARGETS] auctioneer[{g_i}]=0x{g:016X}");}for(g_i,g)in mv.iter().enumerate(){println!("[MM2-TARGETS] mailbox[{g_i}]=0x{g:016X}");}Ok((av,mv))
}
fn mm2_fence_after_probe(stream:&mut TcpStream,crypto:&mut HeaderCrypto,label:&str)->Result<(),String>{mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),label)}
fn mm2_resolve_auctioneer(stream:&mut TcpStream,crypto:&mut HeaderCrypto,candidates:&[u64])->Result<(u64,u32),String>{
    let mut list=candidates.to_vec();if let Ok(v)=env::var("WOW112_AH_GUID"){let g=parse_guid_override("WOW112_AH_GUID",&v)?;list.retain(|x|*x==g);}if list.is_empty(){return Err("MM2 configured auctioneer not discovered".into());}
    for guid in list{
        // A pre-probe fence makes the hello proof belong to this exact probe rather than
        // accepting a delayed response from earlier AH traffic on the same connection.
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"targets/ah-preprobe-fence")?;
        println!("[MM2-TARGETS] AH_PROBE guid=0x{guid:016X}");write_encrypted_raw(stream,crypto.encrypter(),u32::from(MSG_AUCTION_HELLO_OPCODE),&guid.to_le_bytes())?;let deadline=Mm2Instant::now()+Mm2Duration::from_secs(2);let mut timeout=false;
        loop{if Mm2Instant::now()>=deadline{timeout=true;break;}match mm2_read_encrypted_raw_until(stream,crypto.decrypter(),deadline,"targets/ah-probe"){
            Ok((op,p)) if op==MSG_AUCTION_HELLO_OPCODE=>{if p.len()<12{return Err("MM2 short AH hello".into());}let response=u64::from_le_bytes(p[0..8].try_into().unwrap());let house=u32::from_le_bytes(p[8..12].try_into().unwrap());if response!=guid{return Err(format!("MM2 mismatched AH hello 0x{response:016X} expected 0x{guid:016X}"));}mm2_set_normal_timeout(stream)?;println!("[MM2-TARGETS] AH_BOUND guid=0x{guid:016X} house={house}");return Ok((guid,house));},
            Ok(_)=>{},Err(Mm2IoError::DeadlineNoBytes{..})=>{timeout=true;break;},Err(e)=>return Err(e.to_string()),}}
        if timeout{mm2_set_normal_timeout(stream)?;mm2_fence_after_probe(stream,crypto,"targets/ah-probe-timeout")?;println!("[MM2-TARGETS] AH_REJECT no-response guid=0x{guid:016X}");}
    }Err("MM2 no proven auctioneer responder".into())
}
fn mm2_mail_list_once(stream:&mut TcpStream,crypto:&mut HeaderCrypto,mailbox:u64,label:&str)->Result<Option<Vec<Poc05MailRecord>>,String>{
    write_encrypted_raw(stream,crypto.encrypter(),CMSG_GET_MAIL_LIST_OPCODE,&mailbox.to_le_bytes())?;let deadline=Mm2Instant::now()+Mm2Duration::from_secs(2);
    loop{if Mm2Instant::now()>=deadline{mm2_set_normal_timeout(stream)?;mm2_fence_after_probe(stream,crypto,&format!("{label}/expired"))?;return Ok(None);}match mm2_read_encrypted_raw_until(stream,crypto.decrypter(),deadline,label){
        Ok((op,p)) if op==SMSG_MAIL_LIST_RESULT_OPCODE=>{let rows=poc05_parse_mail_list(&p)?;mm2_set_normal_timeout(stream)?;return Ok(Some(rows));},
        Ok(_)=>{},
        Err(Mm2IoError::DeadlineNoBytes{..})=>{mm2_set_normal_timeout(stream)?;mm2_fence_after_probe(stream,crypto,&format!("{label}/timeout"))?;return Ok(None);},
        Err(e)=>return Err(e.to_string()),
    }}
}
fn mm2_resolve_mailbox(stream:&mut TcpStream,crypto:&mut HeaderCrypto,candidates:&[u64])->Result<u64,String>{
    let mut list=candidates.to_vec();if let Ok(v)=env::var("WOW112_MAILBOX_GUID"){let g=parse_guid_override("WOW112_MAILBOX_GUID",&v)?;list.retain(|x|*x==g);}if list.is_empty(){return Err("MM2 configured mailbox not discovered".into());}
    for mailbox in list{
        // Fences make each proof independent: no response from discovery, another mailbox, or
        // probe 1 can be mistaken for probe 2.
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"targets/mailbox-preprobe-fence")?;
        println!("[MM2-TARGETS] MAIL_PROBE1 guid=0x{mailbox:016X}");if mm2_mail_list_once(stream,crypto,mailbox,"targets/mail-probe1")?.is_none(){println!("[MM2-TARGETS] MAIL_REJECT guid=0x{mailbox:016X} probe=1");continue;}
        mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"targets/mailbox-between-probes-fence")?;
        println!("[MM2-TARGETS] MAIL_PROBE2 guid=0x{mailbox:016X}");if mm2_mail_list_once(stream,crypto,mailbox,"targets/mail-probe2")?.is_none(){println!("[MM2-TARGETS] MAIL_REJECT guid=0x{mailbox:016X} probe=2");continue;}
        println!("[MM2-TARGETS] MAIL_BOUND guid=0x{mailbox:016X}");return Ok(mailbox);
    }Err("MM2 no proven mailbox responder".into())
}
fn mm2_resolve_targets(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<Mm2Targets,String>{
    let(ah,mail)=mm2_collect_candidates(stream,crypto,player,Mm2Duration::from_millis(1500))?;let(auctioneer,auction_house)=mm2_resolve_auctioneer(stream,crypto,&ah)?;let mailbox=mm2_resolve_mailbox(stream,crypto,&mail)?;Ok(Mm2Targets{auctioneer,auction_house,mailbox})
}
fn mm2_mail_baseline(stream:&mut TcpStream,crypto:&mut HeaderCrypto,mailbox:u64)->Result<Mm2MailProof,String>{
    mm2_order_fence(stream,crypto,Mm2Duration::from_secs(2),"mail-baseline-prefence")?;let records=mm2_mail_list_once(stream,crypto,mailbox,"mail-baseline")?.ok_or("MM2 mailbox baseline no response")?;Ok(Mm2MailProof{mailbox,observed_at:Mm2Instant::now(),records})
}
fn mm2_mail_proof_fresh(p:&Mm2MailProof)->bool{p.observed_at.elapsed()<=Mm2Duration::from_secs(5)}
