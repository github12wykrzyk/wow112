use std::env;
use std::net::TcpStream;

mod auth;
mod wire_build;
mod world;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "10.0.2.2:3724";

fn main() {
    if let Err(error) = run() {
        eprintln!("[WOW112-ANDROID-PROBE] ERROR: {error}");
        std::process::exit(2);
    }
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

    println!(
        "[WOW112-ANDROID-PROBE] binary-build=5875 wire-build={} protocol=vanilla target=headless",
        OCTOWOW_WIRE_BUILD
    );
    println!("[AUTH] connecting to {auth_addr}");

    let mut auth_stream = TcpStream::connect(&auth_addr)
        .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, &username, &password)?;

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
        &username,
        character_name.as_deref(),
    )?;

    println!("[WOW112-ANDROID-PROBE] PASS: entered world session");
    Ok(())
}
