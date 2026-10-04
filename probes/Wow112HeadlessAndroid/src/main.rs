use std::env;
use std::net::TcpStream;
use std::thread;
use std::time::Duration;

mod auth;
mod wire_build;
mod world;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "10.0.2.2:3724";
const DEFAULT_SOAK_SECONDS: u64 = 300;
const DEFAULT_RECONNECT_LIMIT: u32 = 60;

fn main() {
    if let Err(error) = run() {
        eprintln!("[WOW112-ANDROID-PROBE] ERROR: {error}");
        std::process::exit(2);
    }
}

fn parse_env_u64(name: &str, default_value: u64) -> Result<u64, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u64>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn parse_env_u32(name: &str, default_value: u32) -> Result<u32, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u32>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn is_transient_network_error(error: &str) -> bool {
    [
        "ConnectionReset",
        "Connection reset by peer",
        "BrokenPipe",
        "UnexpectedEof",
        "TimedOut",
        "timed out",
        "WouldBlock",
        "ConnectionRefused",
        "connection refused",
        "world socket closed",
        "world keepalive pong timeout",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR")
        .unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let character_name = env::var("WOW112_CHARACTER").ok();
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let soak_seconds = parse_env_u64("WOW112_SOAK_SECONDS", DEFAULT_SOAK_SECONDS)?;
    let reconnect_limit = parse_env_u32("WOW112_RECONNECT_LIMIT", DEFAULT_RECONNECT_LIMIT)?.max(1);
    let reconnect_delay_ms = parse_env_u64("WOW112_RECONNECT_DELAY_MS", 0)?;

    println!(
        "[WOW112-ANDROID-PROBE] binary-build=5875 wire-build={} protocol=vanilla target=headless",
        OCTOWOW_WIRE_BUILD
    );
    println!(
        "[RESILIENCE] POC-04 soak_seconds={} reconnect_limit={} reconnect_delay_ms={}",
        soak_seconds, reconnect_limit, reconnect_delay_ms
    );

    for attempt in 1..=reconnect_limit {
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        match run_session(
            &auth_addr,
            realm_index,
            &username,
            &password,
            character_name.as_deref(),
            soak_seconds,
        ) {
            Ok(()) => {
                println!("[RESILIENCE] POC-04 RECONNECT/KEEPALIVE PASS attempts={attempt}");
                println!("[WOW112-ANDROID-PROBE] PASS: persistent world session");
                return Ok(());
            }
            Err(error) if is_transient_network_error(&error) && attempt < reconnect_limit => {
                println!("[RESILIENCE] transient network failure: {error}");
                println!("[RESILIENCE] reconnecting with full auth + realm + character state rebuild");
                if reconnect_delay_ms != 0 {
                    thread::sleep(Duration::from_millis(reconnect_delay_ms));
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(format!(
        "POC-04 reconnect limit exhausted after {reconnect_limit} attempts"
    ))
}

fn run_session(
    auth_addr: &str,
    realm_index: usize,
    username: &str,
    password: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
) -> Result<(), String> {
    println!("[AUTH] connecting to {auth_addr}");

    let mut auth_stream = TcpStream::connect(auth_addr)
        .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, username, password)?;

    if realms.realms.is_empty() {
        return Err("auth succeeded but realm list is empty".to_string());
    }

    println!("[AUTH] realms={}", realms.realms.len());
    for (index, realm) in realms.realms.iter().enumerate() {
        println!(
            "[AUTH] realm[{index}] name={} address={} id={}",
            realm.name, realm.address, realm.realm_id
        );
    }

    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} is out of range"))?;

    let world_addr = env::var("WOW112_WORLD_ADDR")
        .unwrap_or_else(|_| realm.address.clone());
    println!(
        "[WORLD] connecting realm={} id={} address={}",
        realm.name, realm.realm_id, world_addr
    );

    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|e| format!("world connect {world_addr} failed: {e}"))?;

    world::login(
        &mut world_stream,
        session_key,
        realm.realm_id,
        username,
        character_name,
        soak_seconds,
    )?;

    Ok(())
}
