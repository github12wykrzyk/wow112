use crate::wire_build::OCTOWOW_WIRE_BUILD;
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::Write;
use std::net::{Ipv4Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wow_login_messages::all::{
    CMD_AUTH_LOGON_CHALLENGE_Client, Locale, Os, Platform, ProtocolVersion, Version,
};
use wow_login_messages::helper::expect_server_message;
use wow_login_messages::version_3::CMD_AUTH_LOGON_CHALLENGE_Server;
use wow_login_messages::Message;

const DEFAULT_PORT: u16 = 3724;
const MAX_CANDIDATES: usize = 8;
const CONNECT_TIMEOUT: Duration = Duration::from_millis(800);
const PROBE_IO_TIMEOUT: Duration = Duration::from_millis(1100);
const FAILOVER_RACE_BUDGET: Duration = Duration::from_millis(1900);
const AUTH_READ_TIMEOUT: Duration = Duration::from_secs(8);
const AUTH_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_CACHE_TTL_SECS: u64 = 180;
const PROBE_ACCOUNT: &str = "OCTOENDPOINTTEST";

pub struct AuthEndpointSelector {
    configured_addr: String,
    enabled: bool,
    seeds: Vec<String>,
    cache_path: Option<PathBuf>,
    cache_ttl: Duration,
    last_good: Option<SocketAddr>,
    failed: HashSet<SocketAddr>,
}

impl AuthEndpointSelector {
    pub fn new(configured_addr: &str) -> Result<Self, String> {
        let configured_addr = configured_addr.trim().to_string();
        if configured_addr.is_empty() {
            return Err("WOW112_AUTH_ADDR is empty".to_string());
        }

        let enabled = selector_enabled();
        let port = configured_port(&configured_addr);
        let mut seeds = Vec::new();
        push_seed(&mut seeds, configured_addr.clone());

        let lower = configured_addr.to_ascii_lowercase();
        if lower.contains("octowow.st") {
            push_seed(&mut seeds, format!("play.octowow.st:{port}"));
            push_seed(&mut seeds, format!("normal.octowow.st:{port}"));
        }

        if let Ok(extra) = env::var("WOW112_AUTH_FALLBACKS") {
            for raw in extra
                .split(|ch: char| ch == ',' || ch == ';' || ch.is_whitespace())
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                push_seed(&mut seeds, ensure_port(raw, port));
            }
        }

        let cache_ttl_secs = env::var("WOW112_AUTH_CACHE_TTL_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(DEFAULT_CACHE_TTL_SECS)
            .clamp(15, 3600);
        let cache_path = resolve_cache_path();

        println!(
            "[AUTH-SELECT] enabled={} configured={} seeds={} cache={} ttl={}s",
            if enabled { "yes" } else { "no" },
            configured_addr,
            seeds.len(),
            cache_path
                .as_ref()
                .map(|path| path.display().to_string())
                .unwrap_or_else(|| "off".to_string()),
            cache_ttl_secs
        );

        Ok(Self {
            configured_addr,
            enabled,
            seeds,
            cache_path,
            cache_ttl: Duration::from_secs(cache_ttl_secs),
            last_good: None,
            failed: HashSet::new(),
        })
    }

    pub fn connect(&mut self) -> Result<(TcpStream, SocketAddr), String> {
        if !self.enabled {
            let stream = TcpStream::connect(&self.configured_addr)
                .map_err(|e| format!("auth connect {} failed: {e}", self.configured_addr))?;
            let peer = stream
                .peer_addr()
                .map_err(|e| format!("auth peer address unavailable: {e}"))?;
            configure_auth_stream(&stream);
            return Ok((stream, peer));
        }

        let shared_cache = self.read_cache();
        let trusted = self.last_good.or_else(|| shared_cache.map(|entry| entry.0));
        if let Some(addr) = trusted {
            if !self.failed.contains(&addr) {
                match connect_socket(addr) {
                    Ok(stream) => {
                        println!("[AUTH-SELECT] trusted endpoint connect PASS addr={addr}");
                        return Ok((stream, addr));
                    }
                    Err(error) => {
                        println!("[AUTH-SELECT] trusted endpoint connect FAIL addr={addr}: {error}");
                        self.failed.insert(addr);
                    }
                }
            }
        }

        let mut candidates = self.resolve_candidates()?;
        candidates.retain(|addr| !self.failed.contains(addr));
        if let Some(addr) = trusted {
            candidates.retain(|candidate| *candidate != addr);
        }
        if candidates.is_empty() {
            return Err("auth endpoint selection failed: no usable candidates remain".to_string());
        }

        let primary = candidates.remove(0);
        match probe_candidate(primary) {
            Ok(latency) => {
                println!(
                    "[AUTH-SELECT] primary probe PASS addr={} latency={}ms",
                    primary,
                    latency.as_millis()
                );
                return connect_socket(primary)
                    .map(|stream| (stream, primary))
                    .map_err(|error| format!("auth endpoint selected {primary} but connect failed: {error}"));
            }
            Err(error) => {
                println!("[AUTH-SELECT] primary probe FAIL addr={primary}: {error}");
                self.failed.insert(primary);
            }
        }

        // Give another worker a very small window to publish a shared last-good endpoint
        // before this process fans out. This keeps normal multi-account startup light.
        let stagger_ms = (std::process::id() as u64 % 5) * 35;
        if stagger_ms != 0 {
            thread::sleep(Duration::from_millis(stagger_ms));
        }
        if let Some((addr, age_secs)) = self.read_cache() {
            if !self.failed.contains(&addr) {
                match connect_socket(addr) {
                    Ok(stream) => {
                        println!(
                            "[AUTH-SELECT] fleet cache takeover PASS addr={} age={}s",
                            addr, age_secs
                        );
                        return Ok((stream, addr));
                    }
                    Err(error) => {
                        println!("[AUTH-SELECT] fleet cache takeover FAIL addr={addr}: {error}");
                        self.failed.insert(addr);
                    }
                }
            }
        }

        candidates.retain(|addr| !self.failed.contains(addr));
        if candidates.is_empty() {
            return Err("auth endpoint selection failed: primary failed and no failover candidates remain".to_string());
        }

        let (tx, rx) = mpsc::channel();
        for addr in candidates.iter().copied() {
            let tx = tx.clone();
            thread::spawn(move || {
                let result = probe_candidate(addr);
                let _ = tx.send((addr, result));
            });
        }
        drop(tx);

        let deadline = Instant::now() + FAILOVER_RACE_BUDGET;
        let mut failures = Vec::new();
        loop {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            match rx.recv_timeout(deadline.saturating_duration_since(now)) {
                Ok((addr, Ok(latency))) => {
                    println!(
                        "[AUTH-SELECT] failover race PASS addr={} latency={}ms",
                        addr,
                        latency.as_millis()
                    );
                    match connect_socket(addr) {
                        Ok(stream) => return Ok((stream, addr)),
                        Err(error) => {
                            self.failed.insert(addr);
                            failures.push(format!("{addr}: selected-connect {error}"));
                        }
                    }
                }
                Ok((addr, Err(error))) => {
                    self.failed.insert(addr);
                    failures.push(format!("{addr}: {error}"));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }

        let detail = if failures.is_empty() {
            "no responsive endpoint before race deadline".to_string()
        } else {
            failures.join(" | ")
        };
        Err(format!("auth endpoint selection failed: {detail}"))
    }

    pub fn mark_good(&mut self, addr: SocketAddr) {
        self.last_good = Some(addr);
        self.failed.remove(&addr);
        if let Some(path) = self.cache_path.as_ref() {
            let now = unix_seconds();
            let payload = format!("version=1\nunix={now}\naddr={addr}\n");
            if let Some(parent) = path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            match fs::write(path, payload.as_bytes()) {
                Ok(()) => println!("[AUTH-SELECT] last-good cached addr={addr}"),
                Err(error) => println!("[AUTH-SELECT] cache write skipped: {error}"),
            }
        }
    }

    pub fn mark_failed(&mut self, addr: SocketAddr) {
        self.failed.insert(addr);
        if self.last_good == Some(addr) {
            self.last_good = None;
        }
        println!("[AUTH-SELECT] endpoint penalized for this process addr={addr}");
    }

    fn resolve_candidates(&self) -> Result<Vec<SocketAddr>, String> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();

        if let Some(addr) = self.last_good {
            if seen.insert(addr) {
                out.push(addr);
            }
        }
        if let Some((addr, age_secs)) = self.read_cache() {
            if seen.insert(addr) {
                println!("[AUTH-SELECT] shared cache candidate addr={addr} age={age_secs}s");
                out.push(addr);
            }
        }

        for seed in &self.seeds {
            match seed.to_socket_addrs() {
                Ok(addrs) => {
                    for addr in addrs {
                        if seen.insert(addr) {
                            out.push(addr);
                            if out.len() >= MAX_CANDIDATES {
                                break;
                            }
                        }
                    }
                }
                Err(error) => println!("[AUTH-SELECT] DNS seed FAIL {}: {}", seed, error),
            }
            if out.len() >= MAX_CANDIDATES {
                break;
            }
        }

        if out.is_empty() {
            return Err(format!(
                "auth endpoint selection failed: DNS produced no candidates for {}",
                self.configured_addr
            ));
        }
        println!("[AUTH-SELECT] resolved candidates={}", out.len());
        Ok(out)
    }

    fn read_cache(&self) -> Option<(SocketAddr, u64)> {
        let path = self.cache_path.as_ref()?;
        let text = fs::read_to_string(path).ok()?;
        let mut timestamp = None;
        let mut addr = None;
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("unix=") {
                timestamp = value.trim().parse::<u64>().ok();
            } else if let Some(value) = line.strip_prefix("addr=") {
                addr = value.trim().parse::<SocketAddr>().ok();
            }
        }
        let timestamp = timestamp?;
        let addr = addr?;
        let age = unix_seconds().saturating_sub(timestamp);
        if age > self.cache_ttl.as_secs() {
            return None;
        }
        Some((addr, age))
    }
}

fn selector_enabled() -> bool {
    match env::var("WOW112_AUTH_SELECTOR") {
        Ok(value) => !matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "off" | "no"
        ),
        Err(_) => cfg!(windows),
    }
}

fn resolve_cache_path() -> Option<PathBuf> {
    if let Ok(value) = env::var("WOW112_AUTH_CACHE_FILE") {
        let value = value.trim();
        if value.eq_ignore_ascii_case("off") || value == "0" {
            return None;
        }
        if !value.is_empty() {
            return Some(PathBuf::from(value));
        }
    }
    env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join("wow112_auth_endpoint.cache")))
}

fn configured_port(value: &str) -> u16 {
    if let Ok(addr) = value.parse::<SocketAddr>() {
        return addr.port();
    }
    value
        .rsplit_once(':')
        .and_then(|(_, port)| port.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT)
}

fn ensure_port(value: &str, port: u16) -> String {
    if value.parse::<SocketAddr>().is_ok() {
        return value.to_string();
    }
    if value.rsplit_once(':').and_then(|(_, p)| p.parse::<u16>().ok()).is_some() {
        value.to_string()
    } else {
        format!("{value}:{port}")
    }
}

fn push_seed(seeds: &mut Vec<String>, value: String) {
    if !seeds.iter().any(|existing| existing.eq_ignore_ascii_case(&value)) {
        seeds.push(value);
    }
}

fn connect_socket(addr: SocketAddr) -> Result<TcpStream, String> {
    let stream = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
        .map_err(|e| format!("connect {addr} failed: {e}"))?;
    configure_auth_stream(&stream);
    Ok(stream)
}

fn configure_auth_stream(stream: &TcpStream) {
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(AUTH_READ_TIMEOUT));
    let _ = stream.set_write_timeout(Some(AUTH_WRITE_TIMEOUT));
}

fn probe_candidate(addr: SocketAddr) -> Result<Duration, String> {
    let started = Instant::now();
    let mut stream = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
        .map_err(|e| format!("probe connect failed: {e}"))?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(PROBE_IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(PROBE_IO_TIMEOUT));

    let request = CMD_AUTH_LOGON_CHALLENGE_Client {
        protocol_version: ProtocolVersion::Three,
        version: Version {
            major: 1,
            minor: 12,
            patch: 1,
            build: OCTOWOW_WIRE_BUILD,
        },
        platform: Platform::X86,
        os: Os::Windows,
        locale: Locale::EnGb,
        utc_timezone_offset: 0,
        client_ip_address: Ipv4Addr::LOCALHOST,
        account_name: PROBE_ACCOUNT.to_string(),
    };

    let mut wire = Vec::new();
    request
        .write(&mut wire)
        .map_err(|e| format!("probe encode failed: {e:?}"))?;
    stream
        .write_all(&wire)
        .map_err(|e| format!("probe write failed: {e}"))?;
    let _ = expect_server_message::<CMD_AUTH_LOGON_CHALLENGE_Server, _>(&mut stream)
        .map_err(|e| format!("probe challenge response failed: {e:?}"))?;
    Ok(started.elapsed())
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ensure_port_keeps_explicit_port() {
        assert_eq!(ensure_port("example.test:1234", 3724), "example.test:1234");
    }

    #[test]
    fn ensure_port_adds_default_port() {
        assert_eq!(ensure_port("example.test", 3724), "example.test:3724");
    }

    #[test]
    fn configured_port_uses_default_without_port() {
        assert_eq!(configured_port("play.octowow.st"), 3724);
    }
}
