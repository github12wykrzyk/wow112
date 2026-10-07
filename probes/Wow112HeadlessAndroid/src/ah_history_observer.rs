use std::collections::HashMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const QUALITY_RULE_VERSION: &str = "ah-quality-v2.0";
const QUEUE_CAPACITY: usize = 256;
static NEXT_SCAN: AtomicU64 = AtomicU64::new(1);
static REALM: OnceLock<RealmContext> = OnceLock::new();
static FULL_SCAN: OnceLock<Mutex<Option<HistoryObserver>>> = OnceLock::new();
static TARGETED: OnceLock<Mutex<HashMap<u32, HistoryObserver>>> = OnceLock::new();

#[derive(Clone, Debug)]
struct RealmContext {
    server_id: String,
    realm_id: String,
}

#[derive(Clone, Debug)]
pub struct HistoryAuction {
    pub auction_id: u32,
    pub item_id: u32,
    pub count: u32,
    pub buyout_total_copper: u32,
    pub start_bid_copper: u32,
    pub current_bid_copper: u32,
    pub min_increment_copper: u32,
    pub time_left_raw: u32,
}

#[derive(Clone, Debug)]
struct Identity {
    market_id: String,
    server_id: String,
    realm_id: String,
    ah_pool: String,
    market_epoch: String,
    status: String,
}

enum Msg {
    Event { line: String, is_page: bool },
    Finish { line: String, ack: mpsc::Sender<Result<PathBuf, String>> },
}

pub struct HistoryObserver {
    tx: Option<SyncSender<Msg>>,
    scan_id: String,
    market_id: String,
    producer: String,
    scope: String,
    identity: Identity,
    seq: u64,
    accepted_pages: u32,
    dropped_events: u32,
}

fn enabled() -> bool {
    !matches!(
        env::var("WOW112_AH_HISTORY_CAPTURE")
            .unwrap_or_else(|_| "1".into())
            .trim()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

fn esc(input: &str) -> String {
    let mut out = String::with_capacity(input.len() + 8);
    for c in input.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn event_base(
    scan_id: &str,
    seq: u64,
    market_id: &str,
    producer: &str,
    scope: &str,
) -> String {
    format!(
        "\"schema_version\":1,\"event_id\":\"{}:{}\",\"scan_id\":\"{}\",\"producer_seq\":{},\"market_id\":\"{}\",\"producer_id\":\"{}\",\"source\":\"live\",\"scope\":\"{}\",\"observed_at_utc_ms\":{},\"quality_rule_version\":\"{}\",\"capture_mode\":\"same_session_nonblocking_v1\"",
        esc(scan_id),
        seq,
        esc(scan_id),
        seq,
        esc(market_id),
        esc(producer),
        esc(scope),
        now_ms(),
        QUALITY_RULE_VERSION
    )
}

fn identity_json(identity: &Identity) -> String {
    format!(
        "{{\"server_id\":\"{}\",\"realm_id\":\"{}\",\"ah_pool\":\"{}\",\"market_epoch\":\"{}\",\"identity_status\":\"{}\",\"identity_source\":\"auth_realm_plus_ah_hello\"}}",
        esc(&identity.server_id),
        esc(&identity.realm_id),
        esc(&identity.ah_pool),
        esc(&identity.market_epoch),
        esc(&identity.status)
    )
}

fn finish_line(
    scan_id: &str,
    seq: u64,
    market_id: &str,
    producer: &str,
    scope: &str,
    identity: &Identity,
    status: &str,
    reason: &str,
    pages: u32,
) -> String {
    format!(
        "{{{},\"event_type\":\"ScanFinished\",\"status\":\"{}\",\"reason\":\"{}\",\"pages\":{},\"market_identity\":{}}}",
        event_base(scan_id, seq, market_id, producer, scope),
        esc(status),
        esc(reason),
        pages,
        identity_json(identity)
    )
}

fn build_identity(auction_house: u32) -> Identity {
    let realm = REALM.get().cloned().unwrap_or(RealmContext {
        server_id: "unknown".into(),
        realm_id: "unknown".into(),
    });
    let ah_pool = env::var("WOW112_AH_POOL_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| format!("house:{auction_house}"));
    let market_epoch = env::var("WOW112_MARKET_EPOCH")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "unknown".into());
    let verified = env::var("WOW112_MARKET_IDENTITY_VERIFIED").unwrap_or_default() == "YES"
        && realm.server_id != "unknown"
        && realm.realm_id != "unknown"
        && market_epoch != "unknown";
    let status = if verified {
        "verified"
    } else {
        "observed_not_reconciled"
    }
    .to_string();
    let default_market = format!(
        "live:{}:{}:{}:{}",
        realm.server_id, realm.realm_id, ah_pool, market_epoch
    );
    let market_id = env::var("WOW112_MARKET_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(default_market);
    Identity {
        market_id,
        server_id: realm.server_id,
        realm_id: realm.realm_id,
        ah_pool,
        market_epoch,
        status,
    }
}

pub fn configure_realm(server_id: &str, realm_numeric_id: u8, realm_name: &str) {
    let stable_server = env::var("WOW112_SERVER_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| server_id.to_string());
    let wanted = RealmContext {
        server_id: stable_server,
        realm_id: format!("{}:{}", realm_numeric_id, realm_name),
    };
    if let Some(current) = REALM.get() {
        if current.server_id != wanted.server_id || current.realm_id != wanted.realm_id {
            eprintln!(
                "[AH-HISTORY] realm context already fixed server={:?} realm={:?}; ignored server={:?} realm={:?}",
                current.server_id, current.realm_id, wanted.server_id, wanted.realm_id
            );
        }
        return;
    }
    let _ = REALM.set(wanted);
}

fn worker(
    rx: Receiver<Msg>,
    partial: PathBuf,
    final_path: PathBuf,
    scan_id: String,
    market_id: String,
    producer: String,
    scope: String,
    identity: Identity,
) {
    let mut first_error: Option<String> = None;
    let mut page_count = 0u32;
    let mut seq = 0u64;
    let mut finished = false;
    let mut writer = match OpenOptions::new().write(true).create_new(true).open(&partial) {
        Ok(file) => Some(BufWriter::new(file)),
        Err(error) => {
            first_error = Some(format!("open {:?}: {error}", partial));
            None
        }
    };

    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Event { line, is_page } => {
                seq = seq.saturating_add(1);
                if is_page {
                    page_count = page_count.saturating_add(1);
                }
                if first_error.is_none() {
                    if let Some(writer) = writer.as_mut() {
                        if let Err(error) = writeln!(writer, "{line}") {
                            first_error = Some(format!("write: {error}"));
                        }
                    }
                }
            }
            Msg::Finish { line, ack } => {
                if first_error.is_none() {
                    if let Some(writer) = writer.as_mut() {
                        if let Err(error) = writeln!(writer, "{line}")
                            .and_then(|_| writer.flush())
                            .and_then(|_| writer.get_ref().sync_all())
                        {
                            first_error = Some(format!("finish: {error}"));
                        }
                    }
                }
                let result = if let Some(error) = first_error.clone() {
                    Err(error)
                } else {
                    fs::rename(&partial, &final_path)
                        .map(|_| final_path.clone())
                        .map_err(|error| {
                            format!("rename {:?} -> {:?}: {error}", partial, final_path)
                        })
                };
                let _ = ack.send(result);
                finished = true;
                break;
            }
        }
    }

    if !finished && first_error.is_none() {
        if let Some(writer) = writer.as_mut() {
            let line = finish_line(
                &scan_id,
                seq.saturating_add(1),
                &market_id,
                &producer,
                &scope,
                &identity,
                "capture_failed",
                "observer_disconnected",
                page_count,
            );
            if writeln!(writer, "{line}")
                .and_then(|_| writer.flush())
                .and_then(|_| writer.get_ref().sync_all())
                .is_ok()
            {
                let _ = fs::rename(&partial, &final_path);
            }
        }
    }
}

impl HistoryObserver {
    pub fn start(scope: &str, auction_house: u32, query_item_id: Option<u32>) -> Option<Self> {
        if !enabled() {
            return None;
        }
        let identity = build_identity(auction_house);
        let producer = env::var("WOW112_PRODUCER_ID")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "terminal-vendor-de-v4".into());
        let serial = NEXT_SCAN.fetch_add(1, Ordering::Relaxed);
        let scan_id = format!("{}-{}-{}", now_ns(), std::process::id(), serial);
        let dir = PathBuf::from(
            env::var("WOW112_AH_HISTORY_CAPTURE_DIR")
                .unwrap_or_else(|_| "ah-history-capture".into()),
        );
        let partial = dir.join(format!("{scan_id}.ndjson.partial"));
        let final_path = dir.join(format!("{scan_id}.ndjson"));

        // Setup happens before the query sequence. Page writes themselves are non-blocking.
        // Storage setup failure disables history only and never fails the AH scan.
        if let Err(error) = fs::create_dir_all(&dir) {
            eprintln!(
                "[AH-HISTORY] disabled for scope={scope}: create_dir {:?}: {error}",
                dir
            );
            return None;
        }

        let (tx, rx) = mpsc::sync_channel::<Msg>(QUEUE_CAPACITY);
        let worker_partial = partial.clone();
        let worker_final = final_path.clone();
        let worker_scan_id = scan_id.clone();
        let worker_market_id = identity.market_id.clone();
        let worker_producer = producer.clone();
        let worker_scope = scope.to_string();
        let worker_identity = identity.clone();
        thread::spawn(move || {
            worker(
                rx,
                worker_partial,
                worker_final,
                worker_scan_id,
                worker_market_id,
                worker_producer,
                worker_scope,
                worker_identity,
            )
        });

        let mut observer = Self {
            tx: Some(tx),
            scan_id,
            market_id: identity.market_id.clone(),
            producer,
            scope: scope.into(),
            identity,
            seq: 0,
            accepted_pages: 0,
            dropped_events: 0,
        };
        let extra = query_item_id
            .map(|item_id| format!(",\"query_item_id\":{item_id}"))
            .unwrap_or_default();
        let seq = 1;
        let line = format!(
            "{{{},\"event_type\":\"ScanStarted\",\"max_page_size\":50,\"market_identity\":{}{} }}",
            event_base(
                &observer.scan_id,
                seq,
                &observer.market_id,
                &observer.producer,
                &observer.scope
            ),
            identity_json(&observer.identity),
            extra
        );
        observer.seq = seq;
        if !observer.try_event(line, false) {
            observer.dropped_events = observer.dropped_events.saturating_add(1);
        }
        Some(observer)
    }

    fn try_event(&self, line: String, is_page: bool) -> bool {
        let Some(tx) = self.tx.as_ref() else {
            return false;
        };
        match tx.try_send(Msg::Event { line, is_page }) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => {
                eprintln!("[AH-HISTORY] queue full scan={} event dropped", self.scan_id);
                false
            }
            Err(TrySendError::Disconnected(_)) => {
                eprintln!("[AH-HISTORY] writer disconnected scan={}", self.scan_id);
                false
            }
        }
    }

    pub fn page(&mut self, page: u32, total: u32, records: &[HistoryAuction]) {
        let seq = self.seq.saturating_add(1);
        let rows = records
            .iter()
            .enumerate()
            .map(|(index, record)| record.json(index))
            .collect::<Vec<_>>()
            .join(",");
        let line = format!(
            "{{{},\"event_type\":\"PageObserved\",\"page\":{},\"listfrom\":{},\"total\":{},\"record_count\":{},\"market_identity\":{},\"records\":[{}]}}",
            event_base(
                &self.scan_id,
                seq,
                &self.market_id,
                &self.producer,
                &self.scope
            ),
            page,
            page.saturating_mul(50),
            total,
            records.len(),
            identity_json(&self.identity),
            rows
        );
        if self.try_event(line, true) {
            self.seq = seq;
            self.accepted_pages = self.accepted_pages.saturating_add(1);
        } else {
            self.dropped_events = self.dropped_events.saturating_add(1);
        }
    }

    pub fn finish_best_effort(mut self, requested_status: &str, reason: &str) {
        let status = if self.dropped_events == 0 {
            requested_status
        } else {
            "capture_failed"
        };
        let reason = if self.dropped_events == 0 {
            reason.to_string()
        } else {
            format!("{reason};dropped_events={}", self.dropped_events)
        };
        let seq = self.seq.saturating_add(1);
        let line = finish_line(
            &self.scan_id,
            seq,
            &self.market_id,
            &self.producer,
            &self.scope,
            &self.identity,
            status,
            &reason,
            self.accepted_pages,
        );
        let Some(tx) = self.tx.take() else {
            return;
        };
        let (ack_tx, ack_rx) = mpsc::channel();
        match tx.try_send(Msg::Finish { line, ack: ack_tx }) {
            Ok(()) => match ack_rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(path)) => println!(
                    "[AH-HISTORY] SAME-SESSION CAPTURE status={} pages={} file={}",
                    status,
                    self.accepted_pages,
                    path.display()
                ),
                Ok(Err(error)) => eprintln!(
                    "[AH-HISTORY] storage failure ignored scan={}: {error}",
                    self.scan_id
                ),
                Err(_) => eprintln!(
                    "[AH-HISTORY] flush ack timeout ignored scan={}",
                    self.scan_id
                ),
            },
            Err(_) => eprintln!(
                "[AH-HISTORY] finish queue unavailable; partial will remain/recover scan={}",
                self.scan_id
            ),
        }
    }
}

impl HistoryAuction {
    fn json(&self, index: usize) -> String {
        format!(
            "{{\"record_index\":{},\"auction_id\":{},\"item_id\":{},\"count\":{},\"buyout_total_copper\":{},\"owner_token\":null,\"start_bid_copper\":{},\"current_bid_copper\":{},\"min_increment_copper\":{},\"time_left_raw\":{}}}",
            index,
            self.auction_id,
            self.item_id,
            self.count,
            self.buyout_total_copper,
            self.start_bid_copper,
            self.current_bid_copper,
            self.min_increment_copper,
            self.time_left_raw
        )
    }
}

fn full_slot() -> &'static Mutex<Option<HistoryObserver>> {
    FULL_SCAN.get_or_init(|| Mutex::new(None))
}

fn targeted_slots() -> &'static Mutex<HashMap<u32, HistoryObserver>> {
    TARGETED.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn observe_full_page_best_effort(
    auction_house: u32,
    page: u32,
    total: u32,
    records: &[HistoryAuction],
) {
    let mut slot = match full_slot().lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };
    if page == 0 || slot.is_none() {
        if let Some(old) = slot.take() {
            old.finish_best_effort("aborted", "new_full_scan_started");
        }
        *slot = HistoryObserver::start("full_market", auction_house, None);
    }
    if let Some(observer) = slot.as_mut() {
        observer.page(page, total, records);
    }
    if records.len() < 50 {
        if let Some(observer) = slot.take() {
            observer.finish_best_effort("completed", "terminal_page");
        }
    }
}

pub fn finish_full_best_effort(status: &str, reason: &str) {
    if let Ok(mut slot) = full_slot().lock() {
        if let Some(observer) = slot.take() {
            observer.finish_best_effort(status, reason);
        }
    }
}

pub fn observe_revalidation_page_best_effort(
    auction_house: u32,
    page: u32,
    total: u32,
    records: &[HistoryAuction],
    label: &str,
) {
    if let Some(mut observer) = HistoryObserver::start("revalidation_window", auction_house, None)
    {
        observer.page(page, total, records);
        observer.finish_best_effort("completed", label);
    }
}

pub fn observe_targeted_page_best_effort(
    auction_house: u32,
    item_id: u32,
    page: u32,
    total: u32,
    records: &[HistoryAuction],
) {
    let mut map = match targeted_slots().lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };
    if page == 0 || !map.contains_key(&item_id) {
        if let Some(old) = map.remove(&item_id) {
            old.finish_best_effort("aborted", "new_targeted_query_started");
        }
        if let Some(observer) = HistoryObserver::start("targeted_item", auction_house, Some(item_id)) {
            map.insert(item_id, observer);
        }
    }
    if let Some(observer) = map.get_mut(&item_id) {
        observer.page(page, total, records);
    }
    let done = total == 0
        || records.is_empty()
        || page
            .saturating_mul(50)
            .saturating_add(records.len() as u32)
            >= total;
    if done {
        if let Some(observer) = map.remove(&item_id) {
            observer.finish_best_effort("completed", "targeted_query_complete");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_escape_is_valid_shape() {
        assert_eq!(esc("a\"b\\c\n"), "a\\\"b\\\\c\\n");
    }

    #[test]
    fn record_json_has_canonical_fields() {
        let record = HistoryAuction {
            auction_id: 1,
            item_id: 2,
            count: 3,
            buyout_total_copper: 4,
            start_bid_copper: 5,
            current_bid_copper: 6,
            min_increment_copper: 7,
            time_left_raw: 8,
        };
        let json = record.json(9);
        assert!(json.contains("\"record_index\":9"));
        assert!(json.contains("\"owner_token\":null"));
    }
}
