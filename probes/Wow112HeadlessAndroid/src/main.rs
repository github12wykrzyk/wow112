use std::env;
use std::net::TcpStream;
use std::thread;
use std::time::Duration;

mod auth;
mod wire_build;
mod world;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "127.0.0.1:3724";
const DEFAULT_SOAK_SECONDS: u64 = 0;
const DEFAULT_RECONNECT_LIMIT: u32 = 60;
const DEFAULT_RECONNECT_DELAY_MS: u64 = 2000;

fn main(){if let Err(e)=run(){eprintln!("[WOW112-HEADLESS] ERROR: {e}");std::process::exit(2);}}
fn parse_u64(name:&str,default:u64)->Result<u64,String>{match env::var(name){Ok(v)=>v.parse::<u64>().map_err(|e|format!("invalid {name}={v:?}: {e}")),Err(_)=>Ok(default)}}
fn parse_u32(name:&str,default:u32)->Result<u32,String>{match env::var(name){Ok(v)=>v.parse::<u32>().map_err(|e|format!("invalid {name}={v:?}: {e}")),Err(_)=>Ok(default)}}
fn transient(e:&str)->bool{["ConnectionReset","Connection reset by peer","BrokenPipe","UnexpectedEof","TimedOut","timed out","WouldBlock","ConnectionRefused","connection refused","world socket closed","world keepalive pong timeout","portal world peek failed"].iter().any(|n|e.contains(n))}

fn run()->Result<(),String>{
 let username=env::var("WOW112_ACCOUNT").map_err(|_|"missing WOW112_ACCOUNT".to_string())?.to_ascii_uppercase();
 let password=env::var("WOW112_PASSWORD").map_err(|_|"missing WOW112_PASSWORD".to_string())?;
 let auth_addr=env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_|DEFAULT_AUTH_ADDR.to_string());
 let character=env::var("WOW112_CHARACTER").ok();
 let realm_index=env::var("WOW112_REALM_INDEX").ok().and_then(|v|v.parse::<usize>().ok()).unwrap_or(0);
 let soak=parse_u64("WOW112_SOAK_SECONDS",DEFAULT_SOAK_SECONDS)?;
 let limit=parse_u32("WOW112_RECONNECT_LIMIT",DEFAULT_RECONNECT_LIMIT)?.max(1);
 let delay=parse_u64("WOW112_RECONNECT_DELAY_MS",DEFAULT_RECONNECT_DELAY_MS)?;
 let mode=env::var("WOW112_HEADLESS_MODE").unwrap_or_else(|_|"portal".to_string()).to_ascii_lowercase();
 println!("[WOW112-HEADLESS] binary-build=5875 wire-build={} mode={} reconnect-limit={} delay-ms={}",OCTOWOW_WIRE_BUILD,mode,limit,delay);
 for attempt in 1..=limit{
  println!("[RESILIENCE] session attempt={attempt}/{limit}");
  match session(&auth_addr,realm_index,&username,&password,character.as_deref(),soak,&mode){
   Ok(())=>return Ok(()),
   Err(e) if transient(&e)&&attempt<limit=>{println!("[RESILIENCE] transient failure: {e}");thread::sleep(Duration::from_millis(delay));}
   Err(e)=>return Err(e),
  }
 }
 Err(format!("reconnect limit exhausted after {limit} attempts"))
}

fn session(auth_addr:&str,realm_index:usize,username:&str,password:&str,character:Option<&str>,soak:u64,mode:&str)->Result<(),String>{
 println!("[AUTH] connecting {auth_addr}");
 let mut auth_stream=TcpStream::connect(auth_addr).map_err(|e|format!("auth connect {auth_addr} failed: {e}"))?;
 let (session_key,realms)=auth::authenticate(&mut auth_stream,username,password)?;
 if realms.realms.is_empty(){return Err("auth succeeded but realm list is empty".to_string());}
 let realm=realms.realms.get(realm_index).ok_or_else(||format!("WOW112_REALM_INDEX={realm_index} out of range"))?;
 let world_addr=env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_|realm.address.clone());
 println!("[WORLD] connecting realm={} address={}",realm.name,world_addr);
 let mut world_stream=TcpStream::connect(&world_addr).map_err(|e|format!("world connect {world_addr} failed: {e}"))?;
 if mode=="portal"||mode=="portal_clicker"{world::login_portal(&mut world_stream,session_key,realm.realm_id,username,character,soak)}else{world::login(&mut world_stream,session_key,realm.realm_id,username,character,soak)}
}
