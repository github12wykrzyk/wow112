use std::env;
use std::net::{TcpStream, ToSocketAddrs};
use std::thread;
use std::time::Duration;

mod auth;
mod auth_endpoint;
mod wire_build;
mod world_endpoint;
mod world_poc05_retry;
mod world_portal;
mod world_tele;

use auth_endpoint::AuthEndpointSelector;
use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_SOAK_SECONDS: u64 = 60;
const DEFAULT_RECONNECT_LIMIT: u32 = 60;
const DEFAULT_REALM_INDEX: usize = 1;
const PORTAL_MIN_RECONNECT_LIMIT: u32 = 600;
const PORTAL_MIN_RECONNECT_DELAY_MS: u64 = 1000;
const WORLD_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

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

fn env_flag(name: &str, default_value: bool) -> bool {
    match env::var(name) {
        Ok(value) => match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => true,
            "0" | "false" | "no" | "off" => false,
            _ => default_value,
        },
        Err(_) => default_value,
    }
}

fn portal_direct_compat_enabled() -> bool {
    env_flag("WOW112_TERMINAL_WIN_DIRECT_COMPAT", cfg!(windows))
}

fn is_transient_network_error(error: &str) -> bool {
    if error.contains("MAIL_MUTATION_") {
        return false;
    }

    if error.starts_with("auth connect ") || error.starts_with("world connect ") {
        return true;
    }

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
        "NetworkUnreachable",
        "HostUnreachable",
        "world socket closed",
        "world keepalive pong timeout",
        "auth endpoint selection failed",
        "auth endpoint selected",
        "read auth challenge failed",
        "write auth challenge failed",
        "read auth proof failed",
        "write auth proof failed",
        "read realm-list failed",
        "write realm-list request failed",
        "read world auth challenge failed",
        "write world auth session failed",
        "read world pre-auth opcode failed",
        "write character enum request failed",
        "read character enum failed",
        "write player login failed",
        "read world opcode failed before login verify",
        "world session did not reach SMSG_LOGIN_VERIFY_WORLD",
        "character login failed before world entry",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn connect_world(spec: &str) -> Result<TcpStream, String> {
    let addrs = spec
        .to_socket_addrs()
        .map_err(|e| format!("world connect {spec} resolve failed: {e}"))?
        .collect::<Vec<_>>();
    if addrs.is_empty() {
        return Err(format!("world connect {spec} failed: DNS returned no addresses"));
    }

    let mut failures = Vec::new();
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, WORLD_CONNECT_TIMEOUT) {
            Ok(stream) => {
                let _ = stream.set_nodelay(true);
                return Ok(stream);
            }
            Err(error) => failures.push(format!("{addr}: {error}")),
        }
    }
    Err(format!("world connect {spec} failed: {}", failures.join(" | ")))
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR")
        .unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let mut auth_selector = AuthEndpointSelector::new(&auth_addr)?;
    let character_name = env::var("WOW112_CHARACTER").ok();
    let mode = env::var("WOW112_MODE")
        .unwrap_or_else(|_| "poc05".to_string())
        .trim()
        .to_ascii_lowercase();

    if !matches!(mode.as_str(), "poc05" | "portal" | "portal-clicker" | "clicker" | "tele" | "tele-sniffer" | "whisper-sniffer") {
        return Err(format!("unsupported WOW112_MODE={mode:?}"));
    }
    let portal_mode = matches!(mode.as_str(), "portal" | "portal-clicker" | "clicker");
    let tele_mode = matches!(mode.as_str(), "tele" | "tele-sniffer" | "whisper-sniffer");
    let mode_label = if tele_mode { "tele-sniffer" } else if portal_mode { "portal-clicker" } else { "poc05" };
    let direct_compat = portal_mode && portal_direct_compat_enabled();

    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);
    let soak_seconds = parse_env_u64("WOW112_SOAK_SECONDS", DEFAULT_SOAK_SECONDS)?;
    let requested_reconnect_limit = parse_env_u32("WOW112_RECONNECT_LIMIT", DEFAULT_RECONNECT_LIMIT)?.max(1);
    let requested_reconnect_delay_ms = parse_env_u64("WOW112_RECONNECT_DELAY_MS", 0)?;
    let reconnect_limit = if portal_mode {
        requested_reconnect_limit.max(PORTAL_MIN_RECONNECT_LIMIT)
    } else {
        requested_reconnect_limit
    };
    let reconnect_delay_ms = if portal_mode {
        requested_reconnect_delay_ms.max(PORTAL_MIN_RECONNECT_DELAY_MS)
    } else {
        requested_reconnect_delay_ms
    };
    let mut mail_mutation_committed = false;

    if portal_mode && (requested_reconnect_limit != reconnect_limit || requested_reconnect_delay_ms != reconnect_delay_ms) {
        println!(
            "[RESILIENCE] portal reconnect guard applied requested_limit={} requested_delay_ms={} effective_limit={} effective_delay_ms={}",
            requested_reconnect_limit,
            requested_reconnect_delay_ms,
            reconnect_limit,
            reconnect_delay_ms
        );
    }

    println!(
        "[WOW112-ANDROID-PROBE] binary-build=5875 wire-build={} protocol=vanilla target=headless mode={}",
        OCTOWOW_WIRE_BUILD,
        mode_label
    );
    if tele_mode {
        println!(
            "[TELE] soak_seconds={} reconnect_limit={} reconnect_delay_ms={} rx_only=yes chat_tx=disabled invite=disabled cast=disabled portal_use=disabled",
            soak_seconds, reconnect_limit, reconnect_delay_ms
        );
    } else if portal_mode {
        println!(
            "[PORTAL] soak_seconds={} reconnect_limit={} reconnect_delay_ms={} auto_gameobj_use=enabled direct_compat={}",
            soak_seconds,
            reconnect_limit,
            reconnect_delay_ms,
            if direct_compat { "yes" } else { "no" }
        );
    } else {
        println!(
            "[POC05] soak_seconds={} reconnect_limit={} reconnect_delay_ms={} guarded_mail_actions=enabled ah_candidate_pool_retry=enabled",
            soak_seconds, reconnect_limit, reconnect_delay_ms
        );
    }

    for attempt in 1..=reconnect_limit {
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        match run_session(
            &mut auth_selector,
            &auth_addr,
            realm_index,
            &username,
            &password,
            character_name.as_deref(),
            soak_seconds,
            &mode,
            &mut mail_mutation_committed,
        ) {
            Ok(()) => {
                let pass_label = if tele_mode { "TELE" } else if portal_mode { "PORTAL" } else { "POC-05" };
                println!("[RESILIENCE] {pass_label} RECONNECT/KEEPALIVE PASS attempts={attempt}");
                println!("[WOW112-ANDROID-PROBE] PASS: {mode_label} persistent world session");
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

    Err(format!("{mode_label} reconnect limit exhausted after {reconnect_limit} attempts"))
}

fn run_session(
    auth_selector: &mut AuthEndpointSelector,
    auth_addr: &str,
    realm_index: usize,
    username: &str,
    password: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    mode: &str,
    mail_mutation_committed: &mut bool,
) -> Result<(), String> {
    let portal_mode = matches!(mode, "portal" | "portal-clicker" | "clicker");
    let direct_compat = portal_mode && portal_direct_compat_enabled();

    let (mut auth_stream, selected_auth_addr) = if direct_compat {
        println!("[AUTH] direct-compat connecting to {auth_addr}");
        let stream = TcpStream::connect(auth_addr)
            .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
        (stream, None)
    } else {
        let (stream, addr) = auth_selector.connect()?;
        println!("[AUTH] connecting selected endpoint {addr}");
        (stream, Some(addr))
    };

    let (session_key, realms) = match auth::authenticate(&mut auth_stream, username, password) {
        Ok(result) => {
            if let Some(addr) = selected_auth_addr {
                auth_selector.mark_good(addr);
            }
            result
        }
        Err(error) => {
            if is_transient_network_error(&error) {
                if let Some(addr) = selected_auth_addr {
                    auth_selector.mark_failed(addr);
                }
            }
            return Err(error);
        }
    };

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

    let world_addr = if direct_compat {
        let address = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
        println!(
            "[WORLD] direct-compat realm={} id={} address={}",
            realm.name, realm.realm_id, address
        );
        address
    } else {
        // Optional endpoint selection remains available for non-recovery modes and
        // explicit diagnostics, but TERMINAL WIN portal workers use the proven direct
        // auth -> realm-list address path by default.
        let address = match env::var("WOW112_WORLD_ADDR") {
            Ok(explicit) => {
                println!("[WORLD-RACE] explicit override; selection bypassed address={explicit}");
                explicit
            }
            Err(_) => world_endpoint::select_world_endpoint(&realm.address),
        };
        println!(
            "[WORLD] connecting realm={} id={} offered={} selected={}",
            realm.name, realm.realm_id, realm.address, address
        );
        address
    };

    let mut world_stream = if direct_compat {
        TcpStream::connect(&world_addr)
            .map_err(|e| format!("world connect {world_addr} failed: {e}"))?
    } else {
        connect_world(&world_addr)?
    };

    if matches!(mode, "tele" | "tele-sniffer" | "whisper-sniffer") {
        world_tele::login_tele_sniffer(
            &mut world_stream,
            session_key,
            realm.realm_id,
            username,
            character_name,
            soak_seconds,
        )?;
    } else if portal_mode {
        world_portal::login_portal_clicker(
            &mut world_stream,
            session_key,
            realm.realm_id,
            username,
            character_name,
            soak_seconds,
        )?;
    } else {
        world_poc05_retry::login_poc05_retry(
            &mut world_stream,
            session_key,
            realm.realm_id,
            username,
            character_name,
            soak_seconds,
            mail_mutation_committed,
        )?;
    }

    Ok(())
}
