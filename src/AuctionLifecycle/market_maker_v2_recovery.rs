//! Durable logical recovery state for Market Maker V2.
//! This is separate from the mutation coordinator: it never authorizes resending a mutation.
//! It records confirmed effects whose follow-up recovery has not completed yet.
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

pub struct Mm2RecoveryJournal { path:PathBuf, file:File, seq:u64, state:Mm2Recovery }

fn fail(e:impl std::fmt::Display)->String{format!("MM2_RECOVERY_HARD_STOP: {e}")}
fn fnv64(bytes:&[u8])->u64{let mut h=0xcbf29ce484222325u64;for b in bytes{h^=u64::from(*b);h=h.wrapping_mul(0x100000001b3);}h}
fn encode_guids(v:&[u64])->String{v.iter().map(|g|format!("{g:016x}")).collect::<Vec<_>>().join(",")}
fn decode_guids(s:&str)->Result<Vec<u64>,String>{if s.is_empty(){return Ok(Vec::new());}s.split(',').map(|x|u64::from_str_radix(x,16).map_err(fail)).collect()}
fn state_body(seq:u64,s:&Mm2Recovery)->String{
    match s {
        Mm2Recovery::Idle=>format!("{seq}|IDLE"),
        Mm2Recovery::CancelledAwaitingMail{auction_id,item_id,count}=>format!("{seq}|CANCELLED|{auction_id}|{item_id}|{count}"),
        Mm2Recovery::BoughtAwaitingMail{auction_id,item_id,count,spend}=>format!("{seq}|BOUGHT|{auction_id}|{item_id}|{count}|{spend}"),
        Mm2Recovery::HoldingStack{item_id,guid,count,bag,slot,cost_basis}=>format!("{seq}|STACK|{item_id}|{guid:016x}|{count}|{bag}|{slot}|{cost_basis}"),
        Mm2Recovery::HoldingUnits{item_id,guids,cost_basis}=>format!("{seq}|UNITS|{item_id}|{}|{cost_basis}",encode_guids(guids)),
        Mm2Recovery::PartiallyPosted{item_id,remaining,posted,cost_basis}=>format!("{seq}|PARTIAL_POST|{item_id}|{}|{posted}|{cost_basis}",encode_guids(remaining)),
    }
}
fn encode(seq:u64,s:&Mm2Recovery)->String{let b=state_body(seq,s);format!("{b}|{:016x}",fnv64(b.as_bytes()))}
fn p32(s:&str)->Result<u32,String>{s.parse::<u32>().map_err(fail)}
fn p8(s:&str)->Result<u8,String>{s.parse::<u8>().map_err(fail)}
fn decode(line:&str)->Result<(u64,Mm2Recovery),String>{
    let (body,hash)=line.rsplit_once('|').ok_or_else(||fail("malformed journal line"))?;
    let got=u64::from_str_radix(hash,16).map_err(fail)?;if fnv64(body.as_bytes())!=got{return Err(fail("journal checksum mismatch"));}
    let p=body.split('|').collect::<Vec<_>>();if p.len()<2{return Err(fail("short journal line"));}
    let seq=p[0].parse::<u64>().map_err(fail)?;
    let s=match p[1] {
        "IDLE" if p.len()==2=>Mm2Recovery::Idle,
        "CANCELLED" if p.len()==5=>Mm2Recovery::CancelledAwaitingMail{auction_id:p32(p[2])?,item_id:p32(p[3])?,count:p32(p[4])?},
        "BOUGHT" if p.len()==6=>Mm2Recovery::BoughtAwaitingMail{auction_id:p32(p[2])?,item_id:p32(p[3])?,count:p32(p[4])?,spend:p32(p[5])?},
        "STACK" if p.len()==8=>Mm2Recovery::HoldingStack{item_id:p32(p[2])?,guid:u64::from_str_radix(p[3],16).map_err(fail)?,count:p32(p[4])?,bag:p8(p[5])?,slot:p8(p[6])?,cost_basis:p32(p[7])?},
        "UNITS" if p.len()==5=>Mm2Recovery::HoldingUnits{item_id:p32(p[2])?,guids:decode_guids(p[3])?,cost_basis:p32(p[4])?},
        "PARTIAL_POST" if p.len()==6=>Mm2Recovery::PartiallyPosted{item_id:p32(p[2])?,remaining:decode_guids(p[3])?,posted:p32(p[4])?,cost_basis:p32(p[5])?},
        _=>return Err(fail(format!("unsupported journal state {}",p[1]))),
    };Ok((seq,s))
}
fn key(server:&str,realm:u32,guid:u64)->Result<String,String>{
    let server=server.to_ascii_lowercase();let enc=server.bytes().map(|b|format!("{b:02x}")).collect::<String>();
    if enc.is_empty()||enc.len()>160||guid==0{return Err(fail("invalid identity"));}Ok(format!("{enc}-{realm}-{guid:016x}"))
}
fn root()->Result<PathBuf,String>{
    Ok(if cfg!(windows){PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(||fail("LOCALAPPDATA unavailable"))?)}else{PathBuf::from(std::env::var_os("HOME").ok_or_else(||fail("HOME unavailable"))?).join(".local/share")}.join("WoW112/MarketMakerV2"))
}
impl Mm2RecoveryJournal {
    pub fn open(server:&str,realm:u32,guid:u64)->Result<Self,String>{Self::open_at(&root()?,&key(server,realm,guid)?) }
    fn open_at(root:&Path,key:&str)->Result<Self,String>{
        fs::create_dir_all(root).map_err(fail)?;let path=root.join(format!("{key}.recovery"));let mut seq=0;let mut state=Mm2Recovery::Idle;
        if path.exists(){
            let f=File::open(&path).map_err(fail)?;for line in BufReader::new(f).lines(){let line=line.map_err(fail)?;if line.trim().is_empty(){return Err(fail("empty journal record"));}let(s,st)=decode(&line)?;if s<=seq{return Err(fail("non-monotonic recovery sequence"));}seq=s;state=st;}
        }
        let file=OpenOptions::new().create(true).append(true).open(&path).map_err(fail)?;Ok(Self{path,file,seq,state})
    }
    pub fn state(&self)->&Mm2Recovery{&self.state}
    pub fn is_idle(&self)->bool{matches!(self.state,Mm2Recovery::Idle)}
    pub fn set(&mut self,state:Mm2Recovery)->Result<(),String>{
        self.seq=self.seq.checked_add(1).ok_or_else(||fail("sequence overflow"))?;let line=encode(self.seq,&state);
        writeln!(self.file,"{line}").and_then(|_|self.file.sync_all()).map_err(fail)?;self.state=state;Ok(())
    }
    pub fn clear(&mut self)->Result<(),String>{self.set(Mm2Recovery::Idle)}
    pub fn path(&self)->&Path{&self.path}
}

#[cfg(test)]mod tests{
    use super::*;use std::sync::atomic::{AtomicU64,Ordering};
    fn temp()->PathBuf{static N:AtomicU64=AtomicU64::new(0);std::env::temp_dir().join(format!("mm2-recovery-{}-{}",std::process::id(),N.fetch_add(1,Ordering::Relaxed)))}
    #[test]fn survives_restart_and_clears(){let r=temp();let mut j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();j.set(Mm2Recovery::CancelledAwaitingMail{auction_id:1,item_id:2,count:3}).unwrap();drop(j);let mut j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();assert!(matches!(j.state(),Mm2Recovery::CancelledAwaitingMail{auction_id:1,..}));j.clear().unwrap();drop(j);assert!(Mm2RecoveryJournal::open_at(&r,"x").unwrap().is_idle());fs::remove_dir_all(r).unwrap();}
    #[test]fn corrupt_line_fails_closed(){let r=temp();fs::create_dir_all(&r).unwrap();fs::write(r.join("x.recovery"),"1|BOUGHT|1|2|3|4|0000000000000000\n").unwrap();assert!(Mm2RecoveryJournal::open_at(&r,"x").is_err());fs::remove_dir_all(r).unwrap();}
    #[test]fn units_round_trip(){let r=temp();let mut j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();j.set(Mm2Recovery::HoldingUnits{item_id:9,guids:vec![1,2,3],cost_basis:400}).unwrap();drop(j);let j=Mm2RecoveryJournal::open_at(&r,"x").unwrap();assert_eq!(j.state(),&Mm2Recovery::HoldingUnits{item_id:9,guids:vec![1,2,3],cost_basis:400});fs::remove_dir_all(r).unwrap();}
}
