//! Durable logical recovery state for Market Maker V2.
//! Separate from the mutation coordinator: it never authorizes resending a mutation.
use std::{fs::{self,File,OpenOptions},io::{BufRead,BufReader,Write},path::{Path,PathBuf}};

#[derive(Clone,Debug,PartialEq,Eq)]
pub enum Mm2Recovery {
    Idle,
    CancelledAwaitingMail { auction_id:u32,item_id:u32,count:u32 },
    BoughtAwaitingMail { auction_id:u32,item_id:u32,count:u32,spend:u32 },
    HoldingStack { item_id:u32,guid:u64,count:u32,bag:u8,slot:u8,cost_basis:u32 },
    HoldingUnits { item_id:u32,guids:Vec<u64>,cost_basis:u32 },
    PartiallyPosted { item_id:u32,remaining:Vec<u64>,posted:u32,cost_basis:u32 },
}
pub struct Mm2RecoveryJournal { path:PathBuf,file:File,seq:u64,state:Mm2Recovery }
fn fail(e:impl std::fmt::Display)->String{format!("MM2_RECOVERY_HARD_STOP: {e}")}
fn fnv64(bytes:&[u8])->u64{let mut h=0xcbf29ce484222325u64;for b in bytes{h^=u64::from(*b);h=h.wrapping_mul(0x100000001b3);}h}
fn gs(v:&[u64])->String{v.iter().map(|g|format!("{g:016x}")).collect::<Vec<_>>().join(",")}
fn pg(s:&str)->Result<Vec<u64>,String>{if s.is_empty(){Ok(vec![])}else{s.split(',').map(|x|u64::from_str_radix(x,16).map_err(fail)).collect()}}
fn body(n:u64,s:&Mm2Recovery)->String{match s{
 Mm2Recovery::Idle=>format!("{n}|IDLE"),
 Mm2Recovery::CancelledAwaitingMail{auction_id,item_id,count}=>format!("{n}|CANCELLED|{auction_id}|{item_id}|{count}"),
 Mm2Recovery::BoughtAwaitingMail{auction_id,item_id,count,spend}=>format!("{n}|BOUGHT|{auction_id}|{item_id}|{count}|{spend}"),
 Mm2Recovery::HoldingStack{item_id,guid,count,bag,slot,cost_basis}=>format!("{n}|STACK|{item_id}|{guid:016x}|{count}|{bag}|{slot}|{cost_basis}"),
 Mm2Recovery::HoldingUnits{item_id,guids,cost_basis}=>format!("{n}|UNITS|{item_id}|{}|{cost_basis}",gs(guids)),
 Mm2Recovery::PartiallyPosted{item_id,remaining,posted,cost_basis}=>format!("{n}|PARTIAL_POST|{item_id}|{}|{posted}|{cost_basis}",gs(remaining)),}}
fn enc(n:u64,s:&Mm2Recovery)->String{let b=body(n,s);format!("{b}|{:016x}",fnv64(b.as_bytes()))}
fn p32(s:&str)->Result<u32,String>{s.parse().map_err(fail)} fn p8(s:&str)->Result<u8,String>{s.parse().map_err(fail)}
fn dec(line:&str)->Result<(u64,Mm2Recovery),String>{let(b,h)=line.rsplit_once('|').ok_or_else(||fail("malformed journal"))?;if fnv64(b.as_bytes())!=u64::from_str_radix(h,16).map_err(fail)?{return Err(fail("checksum"));}let p=b.split('|').collect::<Vec<_>>();let n=p.first().ok_or_else(||fail("seq"))?.parse::<u64>().map_err(fail)?;let s=match p.as_slice(){
 [_,"IDLE"]=>Mm2Recovery::Idle,
 [_,"CANCELLED",a,i,c]=>Mm2Recovery::CancelledAwaitingMail{auction_id:p32(a)?,item_id:p32(i)?,count:p32(c)?},
 [_,"BOUGHT",a,i,c,s]=>Mm2Recovery::BoughtAwaitingMail{auction_id:p32(a)?,item_id:p32(i)?,count:p32(c)?,spend:p32(s)?},
 [_,"STACK",i,g,c,b,sl,cost]=>Mm2Recovery::HoldingStack{item_id:p32(i)?,guid:u64::from_str_radix(g,16).map_err(fail)?,count:p32(c)?,bag:p8(b)?,slot:p8(sl)?,cost_basis:p32(cost)?},
 [_,"UNITS",i,g,cost]=>Mm2Recovery::HoldingUnits{item_id:p32(i)?,guids:pg(g)?,cost_basis:p32(cost)?},
 [_,"PARTIAL_POST",i,g,p,cost]=>Mm2Recovery::PartiallyPosted{item_id:p32(i)?,remaining:pg(g)?,posted:p32(p)?,cost_basis:p32(cost)?},
 _=>return Err(fail("unsupported state")),};Ok((n,s))}
fn root()->Result<PathBuf,String>{Ok(if cfg!(windows){PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(||fail("LOCALAPPDATA"))?)}else{PathBuf::from(std::env::var_os("HOME").ok_or_else(||fail("HOME"))?).join(".local/share")}.join("WoW112/MarketMakerV2"))}
fn key(server:&str,realm:u32,guid:u64)->Result<String,String>{let x=server.to_ascii_lowercase().bytes().map(|b|format!("{b:02x}")).collect::<String>();if x.is_empty()||x.len()>160||guid==0{return Err(fail("identity"));}Ok(format!("{x}-{realm}-{guid:016x}"))}
impl Mm2RecoveryJournal{
 pub fn open(server:&str,realm:u32,guid:u64)->Result<Self,String>{Self::open_at(&root()?,&key(server,realm,guid)?) }
 fn open_at(root:&Path,key:&str)->Result<Self,String>{fs::create_dir_all(root).map_err(fail)?;let path=root.join(format!("{key}.recovery"));let mut seq=0;let mut state=Mm2Recovery::Idle;if path.exists(){for l in BufReader::new(File::open(&path).map_err(fail)?).lines(){let(n,s)=dec(&l.map_err(fail)?)?;if n<=seq{return Err(fail("non-monotonic sequence"));}seq=n;state=s;}}let file=OpenOptions::new().create(true).append(true).open(&path).map_err(fail)?;Ok(Self{path,file,seq,state})}
 pub fn state(&self)->&Mm2Recovery{&self.state} pub fn is_idle(&self)->bool{matches!(self.state,Mm2Recovery::Idle)}
 pub fn set(&mut self,state:Mm2Recovery)->Result<(),String>{self.seq=self.seq.checked_add(1).ok_or_else(||fail("seq overflow"))?;writeln!(self.file,"{}",enc(self.seq,&state)).and_then(|_|self.file.sync_all()).map_err(fail)?;self.state=state;Ok(())}
 pub fn clear(&mut self)->Result<(),String>{self.set(Mm2Recovery::Idle)} pub fn path(&self)->&Path{&self.path}
}
#[cfg(test)]mod tests{use super::*;use std::sync::atomic::{AtomicU64,Ordering};fn t()->PathBuf{static N:AtomicU64=AtomicU64::new(0);std::env::temp_dir().join(format!("mm2-recovery-{}-{}",std::process::id(),N.fetch_add(1,Ordering::Relaxed)))}
 #[test]fn survives_restart_and_clears(){let r=t();let mut j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();j.set(Mm2Recovery::CancelledAwaitingMail{auction_id:1,item_id:2,count:3}).unwrap();drop(j);let mut j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();assert!(matches!(j.state(),Mm2Recovery::CancelledAwaitingMail{auction_id:1,..}));j.clear().unwrap();drop(j);let j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();assert!(j.is_idle());drop(j);fs::remove_dir_all(r).unwrap();}
 #[test]fn corrupt_line_fails_closed(){let r=t();fs::create_dir_all(&r).unwrap();fs::write(r.join("x.recovery"),"1|BOUGHT|1|2|3|4|0000000000000000\n").unwrap();assert!(Mm2RecoveryJournal::open_at(&r,"x").is_err());fs::remove_dir_all(r).unwrap();}
 #[test]fn units_round_trip(){let r=t();let mut j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();j.set(Mm2Recovery::HoldingUnits{item_id:9,guids:vec![1,2,3],cost_basis:400}).unwrap();drop(j);let j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();assert_eq!(j.state(),&Mm2Recovery::HoldingUnits{item_id:9,guids:vec![1,2,3],cost_basis:400});drop(j);fs::remove_dir_all(r).unwrap();}}
