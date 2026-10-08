//! Durable multi-step lifecycle saga for Market Maker V2.
//! Separate from MutationCoordinator `.pending`; this journal never authorizes replay of
//! an uncertain SEND. HOLD and BLOCKED_UNCERTAIN are terminal until manual reconciliation.
use std::{fs::{self,File,OpenOptions},io::{BufRead,BufReader,Write},path::{Path,PathBuf}};

#[derive(Clone,Copy,Debug,PartialEq,Eq)] pub enum Mm2SagaKind{Undercut,Clear}
#[derive(Clone,Debug,PartialEq,Eq)] pub enum Mm2SagaPhase{
    Planned,MailboxVerified{mailbox:u64},CancelIntent{auction_id:u32},CancelConfirmed{auction_id:u32},
    ReturnMailFound{mail_id:u32},ItemTaken{item_id:u32,count:u32},
    InventoryVerified{guid:u64,item_id:u32,count:u32,bag:u8,slot:u8},
    SplitProgress{source_guid:u64,remaining:u32,units:Vec<u64>},PostProgress{posted:u32,remaining:Vec<u64>},
    ClearBuyIntent{auction_id:u32,spend:u32,units:u32},ClearBuyConfirmed{auction_id:u32,spend:u32,units:u32},
    Done,Hold{reason:String},BlockedUncertain{mutation:String,detail:String},
}
#[derive(Clone,Debug,PartialEq,Eq)] pub struct Mm2SagaState{pub saga_id:u64,pub kind:Mm2SagaKind,pub item_id:u32,pub signature:[u32;3],pub own_auction_id:Option<u32>,pub phase:Mm2SagaPhase}
pub struct Mm2SagaJournal{path:PathBuf,file:File,seq:u64,state:Option<Mm2SagaState>}

fn fail(e:impl std::fmt::Display)->String{format!("MM2_SAGA_HARD_STOP: {e}")}
fn terminal(p:&Mm2SagaPhase)->bool{matches!(p,Mm2SagaPhase::Done|Mm2SagaPhase::Hold{..}|Mm2SagaPhase::BlockedUncertain{..})}
fn transition_ok(a:&Mm2SagaPhase,b:&Mm2SagaPhase)->bool{
    if matches!(b,Mm2SagaPhase::BlockedUncertain{..}|Mm2SagaPhase::Hold{..}){return !terminal(a)}
    matches!((a,b),
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
      (Mm2SagaPhase::MailboxVerified{..},Mm2SagaPhase::ClearBuyIntent{..})|
      (Mm2SagaPhase::ClearBuyIntent{..},Mm2SagaPhase::ClearBuyConfirmed{..})|
      (Mm2SagaPhase::ClearBuyConfirmed{..},Mm2SagaPhase::ReturnMailFound{..})|
      (Mm2SagaPhase::InventoryVerified{..},Mm2SagaPhase::ClearBuyIntent{..})|
      (Mm2SagaPhase::InventoryVerified{..},Mm2SagaPhase::Done))
}
fn h(bytes:&[u8])->u64{let mut v=0xcbf29ce484222325u64;for b in bytes{v^=u64::from(*b);v=v.wrapping_mul(0x100000001b3)}v}
fn esc(s:&str)->String{s.bytes().map(|b|if b==b'%'||b==b'|'||b==b','||!(32..=126).contains(&b){format!("%{b:02X}")}else{(b as char).to_string()}).collect()}
fn unesc(s:&str)->Result<String,String>{let x=s.as_bytes();let mut o=Vec::new();let mut i=0;while i<x.len(){if x[i]==b'%' {if i+2>=x.len(){return Err(fail("bad escape"))}o.push(u8::from_str_radix(std::str::from_utf8(&x[i+1..i+3]).map_err(fail)?,16).map_err(fail)?);i+=3}else{o.push(x[i]);i+=1}}String::from_utf8(o).map_err(fail)}
fn gl(v:&[u64])->String{v.iter().map(|x|format!("{x:016x}")).collect::<Vec<_>>().join(",")}
fn pg(s:&str)->Result<Vec<u64>,String>{if s.is_empty(){Ok(vec![])}else{s.split(',').map(|x|u64::from_str_radix(x,16).map_err(fail)).collect()}}
fn k(k:Mm2SagaKind)->&'static str{match k{Mm2SagaKind::Undercut=>"UNDERCUT",Mm2SagaKind::Clear=>"CLEAR"}}
fn pk(s:&str)->Result<Mm2SagaKind,String>{match s{"UNDERCUT"=>Ok(Mm2SagaKind::Undercut),"CLEAR"=>Ok(Mm2SagaKind::Clear),_=>Err(fail("kind"))}}
fn p32(s:&str)->Result<u32,String>{s.parse().map_err(fail)} fn p8(s:&str)->Result<u8,String>{s.parse().map_err(fail)}
fn ph(p:&Mm2SagaPhase)->String{match p{
 Mm2SagaPhase::Planned=>"PLANNED".into(),Mm2SagaPhase::MailboxVerified{mailbox}=>format!("MAILBOX_VERIFIED,{mailbox:016x}"),
 Mm2SagaPhase::CancelIntent{auction_id}=>format!("CANCEL_INTENT,{auction_id}"),Mm2SagaPhase::CancelConfirmed{auction_id}=>format!("CANCEL_CONFIRMED,{auction_id}"),
 Mm2SagaPhase::ReturnMailFound{mail_id}=>format!("RETURN_MAIL_FOUND,{mail_id}"),Mm2SagaPhase::ItemTaken{item_id,count}=>format!("ITEM_TAKEN,{item_id},{count}"),
 Mm2SagaPhase::InventoryVerified{guid,item_id,count,bag,slot}=>format!("INVENTORY_VERIFIED,{guid:016x},{item_id},{count},{bag},{slot}"),
 Mm2SagaPhase::SplitProgress{source_guid,remaining,units}=>format!("SPLIT_PROGRESS,{source_guid:016x},{remaining},{}",gl(units)),
 Mm2SagaPhase::PostProgress{posted,remaining}=>format!("POST_PROGRESS,{posted},{}",gl(remaining)),
 Mm2SagaPhase::ClearBuyIntent{auction_id,spend,units}=>format!("CLEAR_BUY_INTENT,{auction_id},{spend},{units}"),
 Mm2SagaPhase::ClearBuyConfirmed{auction_id,spend,units}=>format!("CLEAR_BUY_CONFIRMED,{auction_id},{spend},{units}"),Mm2SagaPhase::Done=>"DONE".into(),
 Mm2SagaPhase::Hold{reason}=>format!("HOLD,{}",esc(reason)),Mm2SagaPhase::BlockedUncertain{mutation,detail}=>format!("BLOCKED_UNCERTAIN,{},{}",esc(mutation),esc(detail))}}
fn pph(s:&str)->Result<Mm2SagaPhase,String>{let p=s.split(',').collect::<Vec<_>>();match p.as_slice(){
 ["PLANNED"]=>Ok(Mm2SagaPhase::Planned),["MAILBOX_VERIFIED",g]=>Ok(Mm2SagaPhase::MailboxVerified{mailbox:u64::from_str_radix(g,16).map_err(fail)?}),
 ["CANCEL_INTENT",a]=>Ok(Mm2SagaPhase::CancelIntent{auction_id:p32(a)?}),["CANCEL_CONFIRMED",a]=>Ok(Mm2SagaPhase::CancelConfirmed{auction_id:p32(a)?}),
 ["RETURN_MAIL_FOUND",m]=>Ok(Mm2SagaPhase::ReturnMailFound{mail_id:p32(m)?}),["ITEM_TAKEN",i,c]=>Ok(Mm2SagaPhase::ItemTaken{item_id:p32(i)?,count:p32(c)?}),
 ["INVENTORY_VERIFIED",g,i,c,b,s]=>Ok(Mm2SagaPhase::InventoryVerified{guid:u64::from_str_radix(g,16).map_err(fail)?,item_id:p32(i)?,count:p32(c)?,bag:p8(b)?,slot:p8(s)?}),
 ["SPLIT_PROGRESS",g,r,u]=>Ok(Mm2SagaPhase::SplitProgress{source_guid:u64::from_str_radix(g,16).map_err(fail)?,remaining:p32(r)?,units:pg(u)?}),
 ["POST_PROGRESS",n,u]=>Ok(Mm2SagaPhase::PostProgress{posted:p32(n)?,remaining:pg(u)?}),
 ["CLEAR_BUY_INTENT",a,s,u]=>Ok(Mm2SagaPhase::ClearBuyIntent{auction_id:p32(a)?,spend:p32(s)?,units:p32(u)?}),
 ["CLEAR_BUY_CONFIRMED",a,s,u]=>Ok(Mm2SagaPhase::ClearBuyConfirmed{auction_id:p32(a)?,spend:p32(s)?,units:p32(u)?}),["DONE"]=>Ok(Mm2SagaPhase::Done),
 ["HOLD",r]=>Ok(Mm2SagaPhase::Hold{reason:unesc(r)?}),["BLOCKED_UNCERTAIN",m,d]=>Ok(Mm2SagaPhase::BlockedUncertain{mutation:unesc(m)?,detail:unesc(d)?}),_=>Err(fail("phase"))}}
fn body(n:u64,s:&Mm2SagaState)->String{format!("{n}|{}|{}|{}|{}|{}|{}|{}|{}",s.saga_id,k(s.kind),s.item_id,s.signature[0],s.signature[1],s.signature[2],s.own_auction_id.map(|v|v.to_string()).unwrap_or_else(||"-".into()),ph(&s.phase))}
fn enc(n:u64,s:&Mm2SagaState)->String{let b=body(n,s);format!("{b}|{:016x}",h(b.as_bytes()))}
fn dec(line:&str)->Result<(u64,Mm2SagaState),String>{let(b,hh)=line.rsplit_once('|').ok_or_else(||fail("record"))?;if h(b.as_bytes())!=u64::from_str_radix(hh,16).map_err(fail)?{return Err(fail("checksum"))}let mut p=b.splitn(9,'|');let n=p.next().ok_or_else(||fail("seq"))?.parse().map_err(fail)?;let id=p.next().ok_or_else(||fail("id"))?.parse().map_err(fail)?;let kind=pk(p.next().ok_or_else(||fail("kind"))?)?;let item_id=p32(p.next().ok_or_else(||fail("item"))?)?;let a=p32(p.next().ok_or_else(||fail("s0"))?)?;let b=p32(p.next().ok_or_else(||fail("s1"))?)?;let c=p32(p.next().ok_or_else(||fail("s2"))?)?;let own=p.next().ok_or_else(||fail("own"))?;let own=if own=="-"{None}else{Some(p32(own)?)};let phase=pph(p.next().ok_or_else(||fail("phase"))?)?;Ok((n,Mm2SagaState{saga_id:id,kind,item_id,signature:[a,b,c],own_auction_id:own,phase}))}
fn root()->Result<PathBuf,String>{Ok(if cfg!(windows){PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(||fail("LOCALAPPDATA"))?)}else{PathBuf::from(std::env::var_os("HOME").ok_or_else(||fail("HOME"))?).join(".local/share")}.join("WoW112/MarketMakerV2Saga"))}
fn key(server:&str,realm:u32,guid:u64)->Result<String,String>{let x=server.to_ascii_lowercase().bytes().map(|b|format!("{b:02x}")).collect::<String>();if x.is_empty()||x.len()>160||guid==0{return Err(fail("identity"))}Ok(format!("{x}-{realm}-{guid:016x}"))}
impl Mm2SagaJournal{
 pub fn open(server:&str,realm:u32,guid:u64)->Result<Self,String>{Self::open_at(&root()?,&key(server,realm,guid)?) }
 fn open_at(root:&Path,key:&str)->Result<Self,String>{fs::create_dir_all(root).map_err(fail)?;let path=root.join(format!("{key}.saga"));let mut seq=0;let mut state:Option<Mm2SagaState>=None;if path.exists(){for l in BufReader::new(File::open(&path).map_err(fail)?).lines(){let(n,s)=dec(&l.map_err(fail)?)?;if n<=seq{return Err(fail("non-monotonic sequence"))}if let Some(a)=&state{if a.saga_id==s.saga_id&&!transition_ok(&a.phase,&s.phase){return Err(fail("illegal persisted transition"))}}seq=n;state=Some(s)}}let file=OpenOptions::new().create(true).append(true).open(&path).map_err(fail)?;Ok(Self{path,file,seq,state})}
 pub fn state(&self)->Option<&Mm2SagaState>{self.state.as_ref()} pub fn has_unfinished(&self)->bool{self.state.as_ref().is_some_and(|s|!terminal(&s.phase))} pub fn can_start_new(&self)->bool{self.state.as_ref().map_or(true,|s|matches!(s.phase,Mm2SagaPhase::Done))}
 pub fn start(&mut self,kind:Mm2SagaKind,item_id:u32,signature:[u32;3],own_auction_id:Option<u32>)->Result<u64,String>{if !self.can_start_new(){return Err(fail("existing saga requires reconciliation"))}if item_id==0{return Err(fail("zero item"))}let id=self.seq.saturating_add(1).max(1);self.append(Mm2SagaState{saga_id:id,kind,item_id,signature,own_auction_id,phase:Mm2SagaPhase::Planned})?;Ok(id)}
 pub fn advance(&mut self,phase:Mm2SagaPhase)->Result<(),String>{let mut s=self.state.clone().ok_or_else(||fail("no active saga"))?;if terminal(&s.phase)||!transition_ok(&s.phase,&phase){return Err(fail(format!("illegal transition {:?} -> {:?}",s.phase,phase)))}s.phase=phase;self.append(s)}
 pub fn block_uncertain(&mut self,m:&str,d:&str)->Result<(),String>{self.advance(Mm2SagaPhase::BlockedUncertain{mutation:m.into(),detail:d.into()})}
 fn append(&mut self,s:Mm2SagaState)->Result<(),String>{self.seq=self.seq.checked_add(1).ok_or_else(||fail("sequence overflow"))?;writeln!(self.file,"{}",enc(self.seq,&s)).and_then(|_|self.file.sync_all()).map_err(fail)?;self.state=Some(s);Ok(())}
 pub fn path(&self)->&Path{&self.path}
}
#[cfg(test)]mod tests{use super::*;use std::sync::atomic::{AtomicU64,Ordering};fn t()->PathBuf{static N:AtomicU64=AtomicU64::new(0);std::env::temp_dir().join(format!("mm2-saga-{}-{}",std::process::id(),N.fetch_add(1,Ordering::Relaxed)))}
 #[test]fn restart(){let r=t();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Undercut,1,[0;3],Some(7)).unwrap();j.advance(Mm2SagaPhase::MailboxVerified{mailbox:9}).unwrap();j.advance(Mm2SagaPhase::CancelIntent{auction_id:7}).unwrap();j.advance(Mm2SagaPhase::CancelConfirmed{auction_id:7}).unwrap();drop(j);assert!(Mm2SagaJournal::open_at(&r,"x").unwrap().has_unfinished());fs::remove_dir_all(r).unwrap()}
 #[test]fn uncertain_terminal(){let r=t();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Clear,1,[0;3],None).unwrap();j.block_uncertain("BUY","timeout").unwrap();assert!(!j.can_start_new());assert!(j.advance(Mm2SagaPhase::Done).is_err());drop(j);fs::remove_dir_all(r).unwrap()}
 #[test]fn clear_requires_mail_inventory_between_buys(){let r=t();let mut j=Mm2SagaJournal::open_at(&r,"x").unwrap();j.start(Mm2SagaKind::Clear,1,[0;3],None).unwrap();assert!(j.advance(Mm2SagaPhase::ClearBuyIntent{auction_id:1,spend:1,units:1}).is_err());j.advance(Mm2SagaPhase::MailboxVerified{mailbox:9}).unwrap();j.advance(Mm2SagaPhase::ClearBuyIntent{auction_id:10,spend:100,units:1}).unwrap();j.advance(Mm2SagaPhase::ClearBuyConfirmed{auction_id:10,spend:100,units:1}).unwrap();assert!(j.advance(Mm2SagaPhase::ClearBuyIntent{auction_id:11,spend:200,units:1}).is_err());j.advance(Mm2SagaPhase::ReturnMailFound{mail_id:8}).unwrap();j.advance(Mm2SagaPhase::ItemTaken{item_id:1,count:1}).unwrap();j.advance(Mm2SagaPhase::InventoryVerified{guid:20,item_id:1,count:1,bag:255,slot:23}).unwrap();j.advance(Mm2SagaPhase::ClearBuyIntent{auction_id:11,spend:200,units:1}).unwrap();drop(j);fs::remove_dir_all(r).unwrap()}
}
