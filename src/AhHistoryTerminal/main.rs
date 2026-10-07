#[path = "../../probes/Wow112HeadlessAndroid/src/auth.rs"]
mod auth;
#[path = "../../probes/Wow112HeadlessAndroid/src/wire_build.rs"]
mod wire_build;
mod capture;
mod world_history;

use std::{env, net::TcpStream, time::Duration};

fn main() {
    if let Err(e) = run() {
        eprintln!("[AH-HISTORY] ERROR: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() == 2 && args[1] == "--version" {
        println!("wow112-ah-history 0.1.0 source=f78d4305a4c12fde33767cad85d94f755c1e120a mutation=DISABLED");
        return Ok(());
    }
    if args.len() < 2 || args[1] == "--help" {
        println!("Usage: wow112-ah-history live OUTPUT_DIR | fixture-wire LOOPBACK_ADDR OUTPUT_DIR [MAX_PAGES]\nLive requires WOW112_ACCOUNT, WOW112_PASSWORD, WOW112_CHARACTER, WOW112_MARKET_ID, WOW112_PRODUCER_ID, WOW112_OWNER_HMAC_KEY. No BUY mode exists.");
        return Ok(());
    }
    match args[1].as_str() {
        "fixture-wire" if (4..=5).contains(&args.len()) => {
            let addr: std::net::SocketAddr = args[2].parse().map_err(|_| "fixture address must be a numeric loopback socket address")?;
            if !addr.ip().is_loopback() { return Err("fixture-wire only permits loopback".into()); }
            let max_pages = if args.len() == 5 { args[4].parse::<u32>().map_err(|_| "invalid max pages")? } else { 4096 };
            let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(5)).map_err(|e| e.to_string())?;
            s.set_read_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
            let mut capture = capture::Capture::new(&args[3], "fixture", "full_market")?;
            world_history::fixture_scan(&mut s, &mut capture, max_pages)
        }
        "live" if args.len() == 3 => {
            // Validate capture configuration before authenticating. One run = one full scan.
            capture::validate_config()?;
            let username = required("WOW112_ACCOUNT")?.to_ascii_uppercase();
            let password = required("WOW112_PASSWORD")?;
            let character = required("WOW112_CHARACTER")?;
            let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| "play.octowow.st:3724".into());
            let mut auth_stream = TcpStream::connect(&auth_addr).map_err(|e| format!("auth connect failed: {e}"))?;
            auth_stream.set_read_timeout(Some(Duration::from_secs(20))).map_err(|e| e.to_string())?;
            let (key, realms) = auth::authenticate(&mut auth_stream, &username, &password)?;
            let realm_index: usize = env::var("WOW112_REALM_INDEX").unwrap_or_else(|_| "1".into()).parse().map_err(|_| "invalid realm index")?;
            let realm = realms.realms.get(realm_index).ok_or("realm index out of range")?;
            let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
            let mut world = TcpStream::connect(&world_addr).map_err(|e| format!("world connect failed: {e}"))?;
            let mut capture = capture::Capture::new(&args[2], "live", "full_market")?;
            world_history::login_history(&mut world, key, realm.realm_id, &username, Some(&character), &mut capture)
        }
        _ => Err("invalid command; use --help".into()),
    }
}

fn required(name: &str) -> Result<String, String> {
    let s = env::var(name).map_err(|_| format!("missing {name}"))?;
    if s.trim().is_empty() { return Err(format!("empty {name}")); }
    Ok(s)
}

