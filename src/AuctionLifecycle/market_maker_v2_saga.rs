//! Durable lifecycle saga for Market Maker V2.
//! This journal records the multi-step operation state. It is deliberately separate from
//! MutationCoordinator `.pending`: a saga state can authorize only the next *confirmed*
//! phase; it can never authorize replay of an uncertain SEND.
use std::{
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mm2SagaKind { Undercut, Clear }

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mm2SagaPhase {
    Planned,
    MailboxVerified { mailbox:u64 },
    CancelIntent { auction_id:u32 },
    CancelConfirmed { auction_id:u32 },
    ReturnMailFound { mail_id:u32 },
    ItemTaken { item_id:u32, count:u32 },
    InventoryVerified { guid:u64, item_id:u32, count:u32, bag:u8, slot:u8 },
    SplitProgress { source_guid:u64, remaining:u32, units:Vec<u64> },
    PostProgress { posted:u32, remaining:Vec<u64> },
    ClearBuyIntent { auction_id:u32, spend:u32, units:u32 },
    ClearBuyConfirmed { auction_id:u32, spend:u32, units:u32 },
    Done,
    Hold { reason:String },
    BlockedUncertain { mutation:String, detail:String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mm2SagaState {
    pub saga_id:u64,
    pub kind:Mm2SagaKind,
    pub item_id:u32,
    pub signature:[u32;3],
    pub own_auction_id:Option<u32>,
    pub phase:Mm2SagaPhase,
}

pub struct Mm2SagaJournal { path:PathBuf, file:File, seq:u64, state:Option<Mm2SagaState> }

fn fail(e:impl std::fmt::Display)->String{format!("MM2_SAGA_HARD_STOP: {e}")}
fn fnv64(bytes:&[u8])->u64{let mut h=0xcbf29ce484222325u64;for b in bytes{h^=u64::from(*b);h=h.wrapping_mul(0x100000001b3);}h}
fn esc(s:&str)->String{s.bytes().map(|b|match b{b'%'|b'|'|b','=>format!("%{b:02X}"),32..=126=>(b as char).to_string(),_=>format!("%{b:02X}")}).collect()}
fn unesc(s:&str)->Result<String,String>{let b=s.as_bytes();let mut out=Vec::with_capacity(b.len());let mut i=0;while i<b.len(){if b[i]==b'%' {if i+2>=b.len(){return Err(fail("bad escape"));}let h=std::str::from_utf8(&b[i+1..i+3]).map_err(fail)?;out.push(u8::from_str_radix(h,16).map_err(fail)?);i+=3;}else{out.push(b[i]);i+=1;}}String::from_utf8(out).map_err(fail)}
fn guids(v:&[u64])->String{v.iter().map(|g|format!("{g:016x}")).collect::<Vec<_>>().join(",")}
fn parse_guids(v:&str)->Result<Vec<u64>,String>{if v.is_empty(){return Ok(Vec::new());}v.split(',').map(|x|u64::from_str_radix(x,16).map_err(fail)).collect()}
fn kind(k:Mm2SagaKind)->&'static str{match k{Mm2SagaKind::Undercut=>"UNDERCUT",Mm2SagaKind::Clear=>"CLEAR"}}
fn parse_kind(s:&str)->Result<Mm2SagaKind,String>{match s{"UNDERCUT"=>Ok(Mm2SagaKind::Undercut),"CLEAR"=>Ok(Mm2SagaKind::Clear),_=>Err(fail("unknown saga kind"))}}

fn phase(p:&Mm2SagaPhase)->String{match p{
    Mm2SagaPhase::Planned=>"PLANNED".into(),
    Mm2SagaPhase::MailboxVerified{mailbox}=>format!("MAILBOX_VERIFIED,{mailbox:016x}"),
    Mm2SagaPhase::CancelIntent{auction_id}=>format!("CANCEL_INTENT,{auction_id}"),
    Mm2SagaPhase::CancelConfirmed{auction_id}=>format!("CANCEL_CONFIRMED,{auction_id}"),
    Mm2SagaPhase::ReturnMailFound{mail_id}=>format!("RETURN_MAIL_FOUND,{mail_id}"),
    Mm2SagaPhase::ItemTaken{item_id,count}=>format!("ITEM_TAKEN,{item_id},{count}"),
    Mm2SagaPhase::InventoryVerified{guid,item_id,count,bag,slot}=>format!("INVENTORY_VERIFIED,{guid:016x},{item_id},{count},{bag},{slot}"),
    Mm2SagaPhase::SplitProgress{source_guid,remaining,units}=>format!("SPLIT_PROGRESS,{source_guid:016x},{remaining},{}",guids(units)),
    Mm2SagaPhase::PostProgress{posted,remaining}=>format!("POST_PROGRESS,{posted},{}",guids(remaining)),
    Mm2SagaPhase::ClearBuyIntent{auction_id,spend,units}=>format!("CLEAR_BUY_INTENT,{auction_id},{spend},{units}"),
    Mm2SagaPhase::ClearBuyConfirmed{auction_id,spend,units}=>format!("CLEAR_BUY_CONFIRMED,{auction_id},{spend},{units}"),
    Mm2SagaPhase::Done=>"DONE".into(),
    Mm2SagaPhase::Hold{reason}=>format!("HOLD,{}",esc(reason)),
    Mm2SagaPhase::BlockedUncertain{mutation,detail}=>format!("BLOCKED_UNCERTAIN,{},{}",esc(mutation),esc(detail)),
}}
fn p32(s:&str)->Result<u32,String>{s.parse().map_err(fail)}
fn p8(s:&str)->Result<u8,String>{s.parse().map_err(fail)}
fn parse_phase(s:&str)->Result<Mm2SagaPhase,String>{let p=s.split(',').collect::<Vec<_>>();match p.as_slice(){
    ["PLANNED"]=>Ok(Mm2SagaPhase::Planned),
    ["MAILBOX_VERIFIED",g]=>Ok(Mm2SagaPhase::MailboxVerified{mailbox:u64::from_str_radix(g,16).map_err(fail)?}),
    ["CANCEL_INTENT",a]=>Ok(Mm2SagaPhase::CancelIntent{auction_id:p32(a)?}),
    ["CANCEL_CONFIRMED",a]=>Ok(Mm2SagaPhase::CancelConfirmed{auction_id:p32(a)?}),
    ["RETURN_MAIL_FOUND",m]=>Ok(Mm2SagaPhase::ReturnMailFound{mail_id:p32(m)?}),
    ["ITEM_TAKEN",i,c]=>Ok(Mm2SagaPhase::ItemTaken{item_id:p32(i)?,count:p32(c)?}),
    ["INVENTORY_VERIFIED",g,i,c,b,sl]=>Ok(Mm2SagaPhase::InventoryVerified{guid:u64::from_str_radix(g,16).map_err(fail)?,item_id:p32(i)?,count:p32(c)?,bag:p8(b)?,slot:p8(sl)?}),
    ["SPLIT_PROGRESS",g,r,u]=>Ok(Mm2SagaPhase::SplitProgress{source_guid:u64::from_str_radix(g,16).map_err(fail)?,remaining:p32(r)?,units:parse_guids(u)?}),
    ["POST_PROGRESS",n,u]=>Ok(Mm2SagaPhase::PostProgress{posted:p32(n)?,remaining:parse_guids(u)?}),
    ["CLEAR_BUY_INTENT",a,s,u]=>Ok(Mm2SagaPhase::ClearBuyIntent{auction_id:p32(a)?,spend:p32(s)?,units:p32(u)?}),
    ["CLEAR_BUY_CONFIRMED",a,s,u]=>Ok(Mm2SagaPhase::ClearBuyConfirmed{auction_id:p32(a)?,spend:p32(s)?,units:p32(u)?}),
    ["DONE"]=>Ok(Mm2SagaPhase::Done),
    ["HOLD",r]=>Ok(Mm2SagaPhase::Hold{reason:unesc(r)?}),
    ["BLOCKED_UNCERTAIN",m,d]=>Ok(Mm2SagaPhase::BlockedUncertain{mutation:unesc(m)?,detail:unesc(d)?}),
    _=>Err(fail("unknown/malformed saga phase")),
}}
fn terminal(p:&Mm2SagaPhase)->bool{matches!(p,Mm2SagaPhase::Done|Mm2SagaPhase::Hold{..}|Mm2SagaPhase::BlockedUncertain{..})}
fn transition_ok(from:&Mm2SagaPhase,to:&Mm2SagaPhase)->bool{
    if matches!(to,Mm2SagaPhase::BlockedUncertain{..}|Mm2SagaPhase::Hold{..}){return !terminal(from);}
    matches!((from,to),
        (Mm2SagaPhase::Planned,Mm2SagaPhase::MailboxVerified{..})|
        (Mm2SagaPhase::MailboxVerified{..},Mm2SagaPhase::CancelIntent{..})|
        (Mm2SagaPhase::CancelIntent{..},Mm2SagaPhase::CancelConfirmed{..})|
        (Mm2SagaPhase::CancelConfirmed{..},Mm2SagaPhase::ReturnMailFound{..})|
        (Mm2SagaPhase::ReturnMailFound{..},Mm2SagaPhase::ItemTaken{..})|
        (Mm2SagaPhase::ItemTaken{..},Mm2SagaPhase::InventoryVerified{..})|
        (Mm2SagaPhase::InventoryVerified{..},Mm2SagaPhase::SplitProgress{..})|
        (Mm2SagaPhase::SplitProgress{..},Mm2SagaPhase::SplitProgress{..})|
        (Mm2SagaPhase::SplitProgress{..},Mm2SagaPhase::PostProgress{..})|
        (Mm2SagaPhase::PostProgress{..},Mm2SagaPhase::PostProgress{..})|
        (Mm2SagaPhase::PostProgress{..},Mm2SagaPhase::Done)|
        (Mm2SagaPhase::Planned,Mm2SagaPhase::ClearBuyIntent{..})|
        (Mm2SagaPhase::MailboxVerified{..},Mm2SagaPhase::ClearBuyIntent{..})|
        (Mm2SagaPhase::ClearBuyIntent{..},Mm2SagaPhase::ClearBuyConfirmed{..})|
        (Mm2SagaPhase::ClearBuyConfirmed{..},Mm2SagaPhase::ReturnMailFound{..})|
        (Mm2SagaPhase::ClearBuyConfirmed{..},Mm2SagaPhase::ClearBuyIntent{..})|
        (Mm2SagaPhase::ClearBuyConfirmed{..},Mm2SagaPhase::Done)|
        (Mm2SagaPhase::InventoryVerified{..},Mm2SagaPhase::Done)
    )
}
fn body(seq:u64,s:&Mm2SagaState)->String{format!("{seq}|{}|{}|{}|{}|{}|{}|{}",s.saga_id,kind(s.kind),s.item_id,s.signature[0],s.signature[1],s.signature[2],s.own_auction_id.map(|x|x.to_string()).unwrap_or_else(||"-".into()))+"|"+&phase(&s.phase)}
fn encode(seq:u64,s:&Mm2SagaState)->String{let b=body(seq,s);format!("{b}|{:016x}",fnv64(b.as_bytes()))}
fn decode(line:&str)->Result<(u64,Mm2SagaState),String>{let(body,hash)=line.rsplit_once('|').ok_or_else(||fail("malformed record"))?;if fnv64(body.as_bytes())!=u64::from_str_radix(hash,16).map_err(fail)?{return Err(fail("checksum mismatch"));}let mut p=body.splitn(9,'|');let seq=p.next().ok_or_else(||fail("seq"))?.parse::<u64>().map_err(fail)?;let saga_id=p.next().ok_or_else(||fail("saga id"))?.parse::<u64>().map_err(fail)?;let k=parse_kind(p.next().ok_or_else(||fail("kind"))?)?;let item_id=p32(p.next().ok_or_else(||fail("item"))?)?;let s0=p32(p.next().ok_or_else(||fail("sig0"))?)?;let s1=p32(p.next().ok_or_else(||fail("sig1"))?)?;let s2=p32(p.next().ok_or_else(||fail("sig2"))?)?;let own=p.next().ok_or_else(||fail("own"))?;let own_auction_id=if own=="-"{None}else{Some(p32(own)?)};let ph=parse_phase(p.next().ok_or_else(||fail("phase"))?)?;Ok((seq,Mm2SagaState{saga_id,kind:k,item_id,signature:[s0,s1,s2],own_auction_id,phase:ph}))}

fn root()->Result<PathBuf,String>{Ok(if cfg!(windows){PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(||fail("LOCALAPPDATA unavailable"))?)}else{PathBuf::from(std::env::var_os("HOME").ok_or_else(||fail("HOME unavailable"))?).join(".local/share")}.join("WoW112/MarketMakerV2Saga"))}
fn key(server:&str,realm:u32,guid:u64)->Result<String,String>{let enc=server.to_ascii_lowercase().bytes().map(|b|format!("{b:02x}")).collect::<String>();if enc.is_empty()||enc.len()>160||guid==0{return Err(fail("invalid identity"));}Ok(format!("{enc}-{realm}-{guid:016x}"))}

impl Mm2SagaJournal{
    pub fn open(server:&str,realm:u32,guid:u64)->Result<Self,String>{Self::open_at(&root()?,&key(server,realm,guid)?) }
    fn open_at(root:&Path,key:&str)->Result<Self,String>{fs::create_dir_all(root).map_err(fail)?;let path=root.join(format!("{key}.saga"));let mut seq=0;let mut state=None;if path.exists(){for line in BufReader::new(File::open(&path).map_err(fail)?).lines(){let line=line.map_err(fail)?;let(n,s)=decode(&line)?;if n<=seq{return Err(fail("non-monotonic sequence"));}if let Some(prev)=&state{if prev.saga_id==s.saga_id&&!transition_ok(&prev.phase,&s.phase){return Err(fail("illegal persisted transition"));}}seq=n;state=Some(s);}}let file=OpenOptions::new().create(true).append(true).open(&path).map_err(fail)?;Ok(Self{path,file,seq,state})}
    pub fn state(&self)->Option<&Mm2SagaState>{self.state.as_ref()}
    pub fn has_unfinished(&self)->bool{self.state.as_ref().is_some_and(|s|!terminal(&s.phase))}
    pub fn can_start_new(&self)->bool{self.state.as_ref().map_or(true,|s|matches!(s.phase,Mm2SagaPhase::Done))}
    pub fn start(&mut self,kind:Mm2SagaKind,item_id:u32,signature:[u32;3],own_auction_id:Option<u32>)->Result<u64,String>{if !self.can_start_new(){return Err(fail("existing saga requires reconciliation"));}if item_id==0{return Err(fail("zero item"));}let id=self.seq.saturating_add(1).max(1);let state=Mm2SagaState{saga_id:id,kind,item_id,signature,own_auction_id,phase:Mm2SagaPhase::Planned};self.append(state)?;Ok(id)}
    pub fn advance(&mut self,phase:Mm2SagaPhase)->Result<(),String>{let old=self.state.clone().ok_or_else(||fail("no active saga"))?;if terminal(&old.phase){return Err(fail("terminal saga cannot advance"));}if !transition_ok(&old.phase,&phase){return Err(fail(format!("illegal transition {:?} -> {:?}",old.phase,phase)));}let mut next=old;next.phase=phase;self.append(next)}
    pub fn block_uncertain(&mut self,mutation:&str,detail:&str)->Result<(),String>{self.advance(Mm2SagaPhase::BlockedUncertain{mutation:mutation.into(),detail:detail.into()})}
    fn append(&mut self,state:Mm2SagaState)->Result<(),String>{self.seq=self.seq.checked_add(1).ok_or_else(||fail("sequence overflow"))?;let line=encode(self.seq,&state);writeln!(self.file,"{line}").and_then(|_|self.file.sync_all()).map_err(fail)?;self.state=Some(state);Ok(())}
    pub fn path(&self)->&Path{&self.path}
}

#[cfg(test)]mod tests{
    use super::*;use std::sync::atomic::{AtomicU64,Ordering};
    fn temp()->PathBuf{static N:AtomicU64=AtomicU64::new(0);std::env::temp_dir().join(format!("mm2-saga-{}-{}",std::process::id(),N.fetch_add(1,Ordering::Relaxed)))}
    #[test]fn undercut_path_survives_restart(){let r=temp();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Undercut,10940,[0,0,0],Some(7)).unwrap();j.advance(Mm2SagaPhase::MailboxVerified{mailbox:9}).unwrap();j.advance(Mm2SagaPhase::CancelIntent{auction_id:7}).unwrap();j.advance(Mm2SagaPhase::CancelConfirmed{auction_id:7}).unwrap();drop(j);let j=Mm2SagaJournal::open_at(&r,"x").unwrap();assert!(matches!(j.state().unwrap().phase,Mm2SagaPhase::CancelConfirmed{auction_id:7}));assert!(j.has_unfinished());fs::remove_dir_all(r).unwrap();}
    #[test]fn uncertain_is_permanent_terminal(){let r=temp();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Clear,1,[0,0,0],None).unwrap();j.block_uncertain("BUY","socket timeout").unwrap();assert!(!j.can_start_new());assert!(j.advance(Mm2SagaPhase::Done).is_err());drop(j);let j=Mm2SagaJournal::open_at(&r,"x").unwrap();assert!(matches!(j.state().unwrap().phase,Mm2SagaPhase::BlockedUncertain{..}));fs::remove_dir_all(r).unwrap();}
    #[test]fn illegal_skip_is_rejected(){let r=temp();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Undercut,1,[0,0,0],Some(2)).unwrap();assert!(j.advance(Mm2SagaPhase::CancelConfirmed{auction_id:2}).is_err());fs::remove_dir_all(r).unwrap();}
    #[test]fn hold_blocks_new_saga(){let r=temp();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Clear,1,[0,0,0],None).unwrap();j.advance(Mm2SagaPhase::Hold{reason:"economics changed".into()}).unwrap();assert!(!j.can_start_new());fs::remove_dir_all(r).unwrap();}
}
