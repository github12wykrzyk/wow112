//! Absolute-deadline world I/O for Market Maker V2.
//! A timeout after consuming any part of a packet is session-fatal; V2 never resumes a
//! partially consumed encrypted packet. Header crypto advances only after all 4 encrypted
//! server-header bytes have been read.
use std::time::{Duration as Mm2Duration,Instant as Mm2Instant};

#[derive(Clone,Debug,PartialEq,Eq)]
enum Mm2IoError {
    DeadlineNoBytes{label:String},
    SessionAbort{label:String,detail:String},
    Protocol{label:String,detail:String},
}
impl std::fmt::Display for Mm2IoError{fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result{match self{Self::DeadlineNoBytes{label}=>write!(f,"MM2_IO_DEADLINE_NO_BYTES {label}"),Self::SessionAbort{label,detail}=>write!(f,"MM2_IO_SESSION_ABORT {label}: {detail}"),Self::Protocol{label,detail}=>write!(f,"MM2_IO_PROTOCOL {label}: {detail}")}}}

fn mm2_remaining(deadline:Mm2Instant)->Result<Mm2Duration,Mm2IoError>{deadline.checked_duration_since(Mm2Instant::now()).filter(|d|!d.is_zero()).ok_or_else(||Mm2IoError::DeadlineNoBytes{label:"deadline".into()})}
fn mm2_read_exact_until(stream:&mut TcpStream,buf:&mut[u8],deadline:Mm2Instant,label:&str)->Result<(),Mm2IoError>{
    let mut off=0usize;
    while off<buf.len(){
        let remaining=match deadline.checked_duration_since(Mm2Instant::now()).filter(|d|!d.is_zero()){Some(x)=>x,None=>return Err(if off==0{Mm2IoError::DeadlineNoBytes{label:label.into()}}else{Mm2IoError::SessionAbort{label:label.into(),detail:format!("deadline after {off}/{} bytes",buf.len())}})};
        stream.set_read_timeout(Some(remaining)).map_err(|e|Mm2IoError::SessionAbort{label:label.into(),detail:format!("set timeout: {e}")})?;
        match std::io::Read::read(stream,&mut buf[off..]){
            Ok(0)=>return Err(Mm2IoError::SessionAbort{label:label.into(),detail:"EOF".into()}),
            Ok(n)=>off+=n,
            Err(e) if matches!(e.kind(),std::io::ErrorKind::WouldBlock|std::io::ErrorKind::TimedOut)=>return Err(if off==0{Mm2IoError::DeadlineNoBytes{label:label.into()}}else{Mm2IoError::SessionAbort{label:label.into(),detail:format!("timeout after {off}/{} bytes",buf.len())}}),
            Err(e)=>return Err(Mm2IoError::SessionAbort{label:label.into(),detail:e.to_string()}),
        }
    }Ok(())
}
fn mm2_read_encrypted_raw_until(stream:&mut TcpStream,decrypter:&mut DecrypterHalf,deadline:Mm2Instant,label:&str)->Result<(u16,Vec<u8>),Mm2IoError>{
    let mut raw=[0u8;4];mm2_read_exact_until(stream,&mut raw,deadline,&format!("{label}/header"))?;
    let header=decrypter.decrypt_server_header(raw);
    if header.size<2{return Err(Mm2IoError::Protocol{label:label.into(),detail:format!("invalid size {} opcode=0x{:04X}",header.size,header.opcode)});}
    let len=usize::from(header.size-2);let mut payload=vec![0u8;len];if len>0{mm2_read_exact_until(stream,&mut payload,deadline,&format!("{label}/payload"))?;} 
    // Keep all existing observational hooks authoritative for packets read through V2.
    if lifecycle_enabled(){lifecycle_observe_raw(header.opcode,&payload);market_maker_observe_raw(header.opcode,&payload);}market_maker_v2_observe_raw(header.opcode,&payload);
    Ok((header.opcode,payload))
}
fn mm2_set_normal_timeout(stream:&TcpStream)->Result<(),String>{stream.set_read_timeout(Some(Mm2Duration::from_secs(20))).map_err(|e|format!("MM2 restore read timeout: {e}"))}
fn mm2_wait_for<T>(stream:&mut TcpStream,crypto:&mut HeaderCrypto,deadline:Mm2Instant,label:&str,mut accept:impl FnMut(u16,&[u8])->Result<Option<T>,String>)->Result<T,String>{
    loop{if Mm2Instant::now()>=deadline{return Err(format!("MM2_PRE_SEND_DEADLINE {label}"));}match mm2_read_encrypted_raw_until(stream,crypto.decrypter(),deadline,label){
        Ok((op,p))=>if let Some(v)=accept(op,&p)?{mm2_set_normal_timeout(stream)?;return Ok(v)},
        Err(Mm2IoError::DeadlineNoBytes{..})=>{let _=mm2_set_normal_timeout(stream);return Err(format!("MM2_PRE_SEND_DEADLINE {label}"));},
        Err(e)=>{let _=mm2_set_normal_timeout(stream);return Err(e.to_string());}
    }}
}
const MM2_CMSG_QUERY_TIME:u32=0x01CE;
const MM2_SMSG_QUERY_TIME_RESPONSE:u16=0x01CF;
fn mm2_order_fence(stream:&mut TcpStream,crypto:&mut HeaderCrypto,timeout:Mm2Duration,label:&str)->Result<(),String>{
    write_encrypted_raw(stream,crypto.encrypter(),MM2_CMSG_QUERY_TIME,&[])?;let deadline=Mm2Instant::now()+timeout;
    mm2_wait_for(stream,crypto,deadline,&format!("{label}/fence"),|op,_|Ok((op==MM2_SMSG_QUERY_TIME_RESPONSE).then_some(())))
}

#[cfg(test)]mod mm2_io_tests{use super::*;#[test]fn io_error_strings_are_typed(){assert!(Mm2IoError::DeadlineNoBytes{label:"x".into()}.to_string().contains("DEADLINE_NO_BYTES"));assert!(Mm2IoError::SessionAbort{label:"x".into(),detail:"partial".into()}.to_string().contains("SESSION_ABORT"));}}
