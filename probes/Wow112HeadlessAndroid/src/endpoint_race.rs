use crate::auth;
use std::collections::{HashMap, HashSet};
use std::env;
use std::io::Read;
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::{mpsc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const AUTH_MAX_CANDIDATES: usize = 8;
const WORLD_MAX_CANDIDATES: usize = 24;
const DEFAULT_AUTH_PORT: u16 = 3724;
const WORLD_AUTH_CHALLENGE_OPCODE: u16 = 0x01EC;

static AUTH_LAST_GOOD: OnceLock<Mutex<Option<SocketAddr>>> = OnceLock::new();

fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn env_u64(name: &str, default: u64, min: u64, max: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(default)
        .clamp(min, max)
}

fn auth_race_enabled(original: &str) -> bool {
    match env::var("WOW112_ENDPOINT_RACE") {
        Ok(raw) => parse_bool(&raw).unwrap_or(false),
        Err(_) => original.to_ascii_lowercase().contains("octowow.st"),
    }
}

fn world_race_enabled() -> bool {
    match env::var("WOW112_WORLD_ENDPOINT_RACE") {
        Ok(raw) => parse_bool(&raw).unwrap_or(false),
        Err(_) => true,
    }
}

fn split_specs(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(|c: char| c == ',' || c == ';' || c.is_ascii_whitespace())
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn with_default_port(spec: &str, default_port: u16) -> String {
    let spec = spec.trim();
    if spec.is_empty() {
        return String::new();
    }
    if spec.parse::<SocketAddr>().is_ok() {
        return spec.to_string();
    }
    if let Some((host, port)) = spec.rsplit_once(':') {
        if !host.is_empty() && port.parse::<u16>().is_ok() {
            return spec.to_string();
        }
    }
    format!("{spec}:{default_port}")
}

fn resolve_spec(spec: &str, default_port: u16) -> Vec<SocketAddr> {
    let normalized = with_default_port(spec, default_port);
    if normalized.is_empty() {
        return Vec::new();
    }
    match normalized.to_socket_addrs() {
        Ok(iter) => iter.filter(SocketAddr::is_ipv4).collect(),
        Err(error) => {
            println!("[ENDPOINT-RACE] resolve failed spec={spec:?}: {error}");
            Vec::new()
        }
    }
}

fn add_candidate(out: &mut Vec<SocketAddr>, addr: SocketAddr, max: usize) {
    if out.len() < max && addr.is_ipv4() && !out.contains(&addr) {
        out.push(addr);
    }
}

fn add_spec(out: &mut Vec<SocketAddr>, spec: &str, default_port: u16, max: usize) {
    for addr in resolve_spec(spec, default_port) {
        add_candidate(out, addr, max);
        if out.len() >= max {
            break;
        }
    }
}

fn original_port(spec: &str, fallback: u16) -> u16 {
    resolve_spec(spec, fallback)
        .first()
        .map(SocketAddr::port)
        .unwrap_or(fallback)
}

#[derive(Debug)]
enum LoginProbe {
    Service { addr: SocketAddr, elapsed: Duration },
    TcpOnly { addr: SocketAddr, elapsed: Duration, error: String },
    Failed { addr: SocketAddr, error: String },
}

fn probe_login(addr: SocketAddr, timeout: Duration) -> LoginProbe {
    let started = Instant::now();
    match TcpStream::connect_timeout(&addr, timeout) {
        Ok(mut stream) => {
            let _ = stream.set_read_timeout(Some(timeout));
            let _ = stream.set_write_timeout(Some(timeout));
            match auth::probe_login_service(&mut stream) {
                Ok(()) => LoginProbe::Service {
                    addr,
                    elapsed: started.elapsed(),
                },
                Err(error) => LoginProbe::TcpOnly {
                    addr,
                    elapsed: started.elapsed(),
                    error,
                },
            }
        }
        Err(error) => LoginProbe::Failed {
            addr,
            error: error.to_string(),
        },
    }
}

pub fn select_auth_endpoint(original: &str) -> String {
    if !auth_race_enabled(original) {
        println!("[ENDPOINT-RACE] login disabled address={original}");
        return original.to_string();
    }

    let port = original_port(original, DEFAULT_AUTH_PORT);
    let mut candidates = Vec::new();
    add_spec(&mut candidates, original, port, AUTH_MAX_CANDIDATES);

    if let Some(last) = AUTH_LAST_GOOD
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|guard| *guard)
    {
        if last.port() == port {
            add_candidate(&mut candidates, last, AUTH_MAX_CANDIDATES);
        }
    }

    let hosts = env::var("WOW112_AUTH_RACE_HOSTS")
        .unwrap_or_else(|_| "play.octowow.st,normal.octowow.st".to_string());
    for spec in split_specs(&hosts) {
        add_spec(&mut candidates, spec, port, AUTH_MAX_CANDIDATES);
    }
    let extra = env::var("WOW112_AUTH_RACE_EXTRA")
        .unwrap_or_else(|_| "185.246.188.177".to_string());
    for spec in split_specs(&extra) {
        add_spec(&mut candidates, spec, port, AUTH_MAX_CANDIDATES);
    }

    if candidates.is_empty() {
        println!("[ENDPOINT-RACE] login no resolved candidates; using original={original}");
        return original.to_string();
    }

    let budget_ms = env_u64("WOW112_AUTH_RACE_BUDGET_MS", 3_500, 500, 10_000);
    let per_probe_ms = env_u64(
        "WOW112_AUTH_RACE_PROBE_TIMEOUT_MS",
        budget_ms.min(3_000),
        250,
        budget_ms,
    );
    let budget = Duration::from_millis(budget_ms);
    let timeout = Duration::from_millis(per_probe_ms);
    println!(
        "[ENDPOINT-RACE] login start candidates={} budget_ms={} probe_timeout_ms={}",
        candidates.len(), budget_ms, per_probe_ms
    );

    let (tx, rx) = mpsc::channel();
    for addr in candidates.iter().copied() {
        let tx = tx.clone();
        thread::spawn(move || {
            let _ = tx.send(probe_login(addr, timeout));
        });
    }
    drop(tx);

    let deadline = Instant::now() + budget;
    let mut first_tcp: Option<(SocketAddr, Duration)> = None;
    let mut received = 0usize;
    while received < candidates.len() {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        match rx.recv_timeout(deadline.saturating_duration_since(now)) {
            Ok(LoginProbe::Service { addr, elapsed }) => {
                println!(
                    "[ENDPOINT-RACE] login winner={} service_answer_ms={} tried={}",
                    addr,
                    elapsed.as_millis(),
                    candidates.len()
                );
                if let Ok(mut guard) = AUTH_LAST_GOOD.get_or_init(|| Mutex::new(None)).lock() {
                    *guard = Some(addr);
                }
                return addr.to_string();
            }
            Ok(LoginProbe::TcpOnly { addr, elapsed, error }) => {
                received += 1;
                println!(
                    "[ENDPOINT-RACE] login tcp-only={} elapsed_ms={} reason={}",
                    addr,
                    elapsed.as_millis(),
                    error
                );
                if first_tcp.is_none() {
                    first_tcp = Some((addr, elapsed));
                }
            }
            Ok(LoginProbe::Failed { addr, error }) => {
                received += 1;
                println!("[ENDPOINT-RACE] login failed={} reason={}", addr, error);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => break,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    if let Some((addr, elapsed)) = first_tcp {
        println!(
            "[ENDPOINT-RACE] login no protocol answer; fallback_tcp={} elapsed_ms={}",
            addr,
            elapsed.as_millis()
        );
        addr.to_string()
    } else {
        println!("[ENDPOINT-RACE] login no candidate answered; using original={original}");
        original.to_string()
    }
}

fn probe_world_once(addr: SocketAddr, timeout: Duration) -> Option<Duration> {
    let started = Instant::now();
    let mut stream = TcpStream::connect_timeout(&addr, timeout).ok()?;
    let _ = stream.set_read_timeout(Some(timeout));
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).ok()?;
    let opcode = u16::from_le_bytes([header[2], header[3]]);
    if opcode == WORLD_AUTH_CHALLENGE_OPCODE {
        Some(started.elapsed())
    } else {
        None
    }
}

#[derive(Debug, Clone)]
struct WorldMetric {
    addr: SocketAddr,
    total: u32,
    timings_ms: Vec<u64>,
    offered: bool,
}

impl WorldMetric {
    fn ok(&self) -> u32 {
        self.timings_ms.len() as u32
    }

    fn failed(&self) -> u32 {
        self.total.saturating_sub(self.ok())
    }

    fn median_ms(&self) -> u64 {
        let mut values = self.timings_ms.clone();
        values.sort_unstable();
        if values.is_empty() {
            return u64::MAX;
        }
        let mid = values.len() / 2;
        if values.len() % 2 == 1 {
            values[mid]
        } else {
            (values[mid - 1] + values[mid]) / 2
        }
    }
}

fn better_world(a: &WorldMetric, b: &WorldMetric) -> bool {
    if a.ok() == 0 {
        return false;
    }
    if b.ok() == 0 {
        return true;
    }
    let lhs = u64::from(a.failed()) * u64::from(b.total.max(1));
    let rhs = u64::from(b.failed()) * u64::from(a.total.max(1));
    lhs < rhs || (lhs == rhs && a.median_ms() < b.median_ms())
}

fn choose_world_metric(metrics: &[WorldMetric]) -> Option<SocketAddr> {
    let mut best: Option<&WorldMetric> = None;
    for metric in metrics.iter().filter(|m| m.ok() > 0) {
        if best.map(|b| better_world(metric, b)).unwrap_or(true) {
            best = Some(metric);
        }
    }
    let best = best?;

    let offered = metrics
        .iter()
        .filter(|m| m.offered && m.ok() > 0 && m.failed() == 0)
        .min_by_key(|m| m.median_ms());
    if let Some(offered) = offered {
        if offered.median_ms() <= best.median_ms().saturating_add(20) {
            return Some(offered.addr);
        }
    }
    Some(best.addr)
}

pub fn select_world_endpoint(offered: &str) -> String {
    if !world_race_enabled() {
        println!("[ENDPOINT-RACE] world disabled address={offered}");
        return offered.to_string();
    }

    let port = original_port(offered, 8085);
    let offered_addrs: HashSet<SocketAddr> = resolve_spec(offered, port).into_iter().collect();
    let mut candidates = Vec::new();
    for addr in offered_addrs.iter().copied() {
        add_candidate(&mut candidates, addr, WORLD_MAX_CANDIDATES);
    }

    let hosts = env::var("WOW112_WORLD_RACE_HOSTS").unwrap_or_else(|_| {
        "normal.octowow.st:8091,hc.octowow.st:8090,pvp.octowow.st:8092".to_string()
    });
    for spec in split_specs(&hosts) {
        for addr in resolve_spec(spec, port) {
            if addr.port() == port {
                add_candidate(&mut candidates, addr, WORLD_MAX_CANDIDATES);
            }
        }
    }

    let known = env::var("WOW112_WORLD_RACE_KNOWN").unwrap_or_else(|_| {
        "92.114.107.53:8091,92.114.107.56:8091,92.114.107.61:8091,92.114.107.62:8091,92.114.107.47:8090,92.114.107.57:8090,92.114.107.49:8092,92.114.107.55:8092".to_string()
    });
    for spec in split_specs(&known) {
        for addr in resolve_spec(spec, port) {
            if addr.port() == port {
                add_candidate(&mut candidates, addr, WORLD_MAX_CANDIDATES);
            }
        }
    }

    if candidates.is_empty() {
        println!("[ENDPOINT-RACE] world no resolved candidates; using offered={offered}");
        return offered.to_string();
    }

    let rounds = env_u64("WOW112_WORLD_RACE_ROUNDS", 2, 1, 3) as u32;
    let window_ms = env_u64("WOW112_WORLD_RACE_WINDOW_MS", 8_000, 1_000, 15_000);
    let rate_ms = env_u64("WOW112_WORLD_RACE_RATE_MS", 334, 100, 2_000);
    let timeout_ms = env_u64("WOW112_WORLD_RACE_TIMEOUT_MS", 3_000, 200, 5_000);
    println!(
        "[ENDPOINT-RACE] world start offered={} candidates={} rounds={} window_ms={} rate_ms={} timeout_ms={}",
        offered,
        candidates.len(),
        rounds,
        window_ms,
        rate_ms,
        timeout_ms
    );

    let (tx, rx) = mpsc::channel();
    let started = Instant::now();
    let window = Duration::from_millis(window_ms);
    let timeout = Duration::from_millis(timeout_ms);
    let rate = Duration::from_millis(rate_ms);
    let mut launched = 0usize;
    let mut totals: HashMap<SocketAddr, u32> = HashMap::new();

    'rounds: for _round in 0..rounds {
        for addr in candidates.iter().copied() {
            let due = started + rate.saturating_mul(launched as u32);
            if due >= started + window {
                break 'rounds;
            }
            let now = Instant::now();
            if due > now {
                thread::sleep(due - now);
            }
            *totals.entry(addr).or_insert(0) += 1;
            let tx = tx.clone();
            thread::spawn(move || {
                let result = probe_world_once(addr, timeout);
                let _ = tx.send((addr, result));
            });
            launched += 1;
        }
    }
    drop(tx);

    let deadline = started + window;
    let mut timings: HashMap<SocketAddr, Vec<u64>> = HashMap::new();
    let mut received = 0usize;
    while received < launched {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        match rx.recv_timeout(deadline.saturating_duration_since(now)) {
            Ok((addr, result)) => {
                received += 1;
                if let Some(elapsed) = result {
                    timings
                        .entry(addr)
                        .or_default()
                        .push(elapsed.as_millis().min(u128::from(u64::MAX)) as u64);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => break,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    let metrics = candidates
        .iter()
        .copied()
        .map(|addr| WorldMetric {
            addr,
            total: totals.get(&addr).copied().unwrap_or(0),
            timings_ms: timings.remove(&addr).unwrap_or_default(),
            offered: offered_addrs.contains(&addr),
        })
        .collect::<Vec<_>>();

    for metric in &metrics {
        println!(
            "[ENDPOINT-RACE] world probe={} answered={}/{} median_ms={} offered={}",
            metric.addr,
            metric.ok(),
            metric.total,
            if metric.ok() > 0 {
                metric.median_ms().to_string()
            } else {
                "NA".to_string()
            },
            metric.offered
        );
    }

    match choose_world_metric(&metrics) {
        Some(addr) => {
            println!("[ENDPOINT-RACE] world selected={} offered={}", addr, offered);
            addr.to_string()
        }
        None => {
            println!("[ENDPOINT-RACE] world no greeting answered; using offered={offered}");
            offered.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn metric(addr: &str, total: u32, ms: &[u64], offered: bool) -> WorldMetric {
        WorldMetric {
            addr: addr.parse().unwrap(),
            total,
            timings_ms: ms.to_vec(),
            offered,
        }
    }

    #[test]
    fn default_port_is_added_only_when_missing() {
        assert_eq!(with_default_port("play.octowow.st", 3724), "play.octowow.st:3724");
        assert_eq!(with_default_port("1.2.3.4:3724", 3724), "1.2.3.4:3724");
    }

    #[test]
    fn world_prefers_lower_loss_before_ping() {
        let a = metric("127.0.0.1:8091", 2, &[10], false);
        let b = metric("127.0.0.2:8091", 2, &[50, 60], false);
        assert_eq!(choose_world_metric(&[a, b]).unwrap(), "127.0.0.2:8091".parse().unwrap());
    }

    #[test]
    fn world_keeps_offered_when_lossless_and_within_twenty_ms() {
        let offered = metric("127.0.0.1:8091", 2, &[120, 120], true);
        let best = metric("127.0.0.2:8091", 2, &[105, 105], false);
        assert_eq!(
            choose_world_metric(&[offered, best]).unwrap(),
            "127.0.0.1:8091".parse().unwrap()
        );
    }

    #[test]
    fn world_switches_when_offered_is_more_than_twenty_ms_slower() {
        let offered = metric("127.0.0.1:8091", 2, &[130, 130], true);
        let best = metric("127.0.0.2:8091", 2, &[100, 100], false);
        assert_eq!(
            choose_world_metric(&[offered, best]).unwrap(),
            "127.0.0.2:8091".parse().unwrap()
        );
    }
}
