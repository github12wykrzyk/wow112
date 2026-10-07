use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const DEFAULT_EXPECTED_PRICE_COPPER: u32 = 40_000;
pub const DEFAULT_ACTIVE_SESSION_SECONDS: u64 = 600;
pub const DEFAULT_CORRELATION_WINDOW_SECONDS: u64 = 21_600;
pub const DEFAULT_SETTLEMENT_TIMEOUT_MS: u64 = 2_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SummonRecord {
    pub summon_id: String,
    pub timestamp_created: u64,
    pub timestamp_summoned: Option<u64>,
    pub client_name: String,
    pub summoner_name: String,
    pub destination: String,
    pub trigger_message: String,
    pub expected_price_copper: u32,
    pub summon_status: String,
    pub payment_status: String,
    pub amount_paid_copper: u32,
    pub payment_timestamp: Option<u64>,
    pub trade_partner: Option<String>,
    pub payment_event_id: Option<String>,
    pub settlement_id: Option<String>,
    pub last_update: u64,
    pub failure_reason: Option<String>,
    pub payment_session_active_until: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TradeIntent {
    pub intent_id: String,
    pub trade_session_id: String,
    pub summon_id: String,
    pub partner: String,
    pub offered_copper: u32,
    pub coinage_before: u32,
    pub timestamp: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PaymentEvent {
    pub payment_event_id: String,
    pub settlement_id: Option<String>,
    pub intent_id: Option<String>,
    pub trade_session_id: String,
    pub summon_id: Option<String>,
    pub timestamp: u64,
    pub trade_partner: String,
    pub offered_copper: u32,
    pub received_copper: u32,
    pub status: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
enum JournalEvent {
    SummonCreated { record: SummonRecord },
    SummonStatus {
        summon_id: String,
        status: String,
        timestamp: u64,
        failure_reason: Option<String>,
    },
    TradeIntent { intent: TradeIntent },
    Payment { event: PaymentEvent },
}

#[derive(Debug, Clone, Default)]
pub struct LedgerState {
    pub summons: Vec<SummonRecord>,
    pub payments: Vec<PaymentEvent>,
    pub pending_intents: HashMap<String, TradeIntent>,
    terminal_intents: HashSet<String>,
}

impl LedgerState {
    fn replay(&mut self, event: JournalEvent) {
        match event {
            JournalEvent::SummonCreated { record } => {
                self.summons.push(record);
            }
            JournalEvent::SummonStatus {
                summon_id,
                status,
                timestamp,
                failure_reason,
            } => {
                if let Some(record) = self
                    .summons
                    .iter_mut()
                    .rev()
                    .find(|record| record.summon_id == summon_id)
                {
                    record.summon_status = status.clone();
                    record.last_update = timestamp;
                    record.failure_reason = failure_reason;
                    if status == "summoned" {
                        record.timestamp_summoned = Some(timestamp);
                        record.payment_session_active_until =
                            timestamp.saturating_add(DEFAULT_ACTIVE_SESSION_SECONDS);
                    }
                }
            }
            JournalEvent::TradeIntent { intent } => {
                if !self.terminal_intents.contains(&intent.intent_id) {
                    self.pending_intents.insert(intent.intent_id.clone(), intent);
                }
            }
            JournalEvent::Payment { event } => {
                if let Some(intent_id) = event.intent_id.as_ref() {
                    self.terminal_intents.insert(intent_id.clone());
                    self.pending_intents.remove(intent_id);
                }
                if let Some(summon_id) = event.summon_id.as_ref() {
                    if let Some(record) = self
                        .summons
                        .iter_mut()
                        .rev()
                        .find(|record| &record.summon_id == summon_id)
                    {
                        record.last_update = event.timestamp;
                        record.trade_partner = Some(event.trade_partner.clone());
                        record.payment_event_id = Some(event.payment_event_id.clone());
                        record.settlement_id = event.settlement_id.clone();
                        match event.status.as_str() {
                            "partial" | "paid" | "overpaid" => {
                                record.amount_paid_copper = record
                                    .amount_paid_copper
                                    .saturating_add(event.received_copper);
                                record.payment_status = event.status.clone();
                                record.payment_timestamp = Some(event.timestamp);
                            }
                            "uncertain" => {
                                record.payment_status = "uncertain".to_string();
                                record.failure_reason = Some(event.reason.clone());
                            }
                            _ => {}
                        }
                    }
                }
                self.payments.push(event);
            }
        }
    }

    fn apply_pending_hard_stops(&mut self) {
        let blocked: HashSet<String> = self
            .pending_intents
            .values()
            .map(|intent| intent.summon_id.clone())
            .collect();
        for record in &mut self.summons {
            if blocked.contains(&record.summon_id)
                && !matches!(record.payment_status.as_str(), "paid" | "overpaid")
            {
                record.payment_status = "uncertain".to_string();
                record.failure_reason = Some("unresolved_accept_intent_after_restart".to_string());
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Correlation {
    pub summon_id: String,
    pub remaining_copper: u32,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArmedAccept {
    pub intent: TradeIntent,
    pub correlation: Correlation,
}

#[derive(Debug, Clone)]
pub struct LedgerStore {
    path: PathBuf,
    pub expected_price_copper: u32,
    pub partial_enabled: bool,
    pub active_session_seconds: u64,
    pub correlation_window_seconds: u64,
}

impl LedgerStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            expected_price_copper: DEFAULT_EXPECTED_PRICE_COPPER,
            partial_enabled: true,
            active_session_seconds: DEFAULT_ACTIVE_SESSION_SECONDS,
            correlation_window_seconds: DEFAULT_CORRELATION_WINDOW_SECONDS,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn stable_file_for(dir: impl AsRef<Path>, summoner_name: &str) -> PathBuf {
        let mut safe = summoner_name
            .trim()
            .to_ascii_lowercase()
            .chars()
            .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '_' })
            .collect::<String>();
        if safe.is_empty() {
            safe = "unknown_summoner".to_string();
        }
        dir.as_ref().join(format!("tele10_trade_ledger_{safe}.jsonl"))
    }

    fn append(&self, event: &JournalEvent) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create ledger directory failed: {error}"))?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|error| format!("open ledger {} failed: {error}", self.path.display()))?;
        let line = serde_json::to_string(event)
            .map_err(|error| format!("serialize ledger event failed: {error}"))?;
        file.write_all(line.as_bytes())
            .and_then(|_| file.write_all(b"\n"))
            .and_then(|_| file.flush())
            .and_then(|_| file.sync_all())
            .map_err(|error| format!("append ledger {} failed: {error}", self.path.display()))?;
        Ok(())
    }

    pub fn load(&self) -> Result<LedgerState, String> {
        let file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(LedgerState::default())
            }
            Err(error) => {
                return Err(format!("open ledger {} failed: {error}", self.path.display()))
            }
        };
        let reader = BufReader::new(file);
        let mut state = LedgerState::default();
        for (index, line) in reader.lines().enumerate() {
            let line = line.map_err(|error| {
                format!("read ledger {} line {} failed: {error}", self.path.display(), index + 1)
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let event: JournalEvent = serde_json::from_str(&line).map_err(|error| {
                format!(
                    "parse ledger {} line {} failed: {error}",
                    self.path.display(),
                    index + 1
                )
            })?;
            state.replay(event);
        }
        state.apply_pending_hard_stops();
        Ok(state)
    }

    fn next_id(prefix: &str, now: u64, ordinal: usize) -> String {
        format!("{prefix}{now}-{ordinal}")
    }

    pub fn create_ritual_started(
        &self,
        client_name: &str,
        summoner_name: &str,
        destination: &str,
        trigger_message: &str,
        now: u64,
    ) -> Result<SummonRecord, String> {
        let client_name = client_name.trim();
        if client_name.is_empty() {
            return Err("cannot create summon ledger record without client name".to_string());
        }
        let state = self.load()?;
        let ordinal = state.summons.len() + 1;
        let record = SummonRecord {
            summon_id: Self::next_id("S", now, ordinal),
            timestamp_created: now,
            timestamp_summoned: None,
            client_name: client_name.to_string(),
            summoner_name: summoner_name.trim().to_string(),
            destination: destination.trim().to_string(),
            trigger_message: trigger_message.to_string(),
            expected_price_copper: self.expected_price_copper,
            summon_status: "ritual_started".to_string(),
            payment_status: "unpaid".to_string(),
            amount_paid_copper: 0,
            payment_timestamp: None,
            trade_partner: None,
            payment_event_id: None,
            settlement_id: None,
            last_update: now,
            failure_reason: None,
            payment_session_active_until: 0,
        };
        self.append(&JournalEvent::SummonCreated {
            record: record.clone(),
        })?;
        Ok(record)
    }

    pub fn mark_summoned_for_client(
        &self,
        client_name: &str,
        now: u64,
    ) -> Result<SummonRecord, String> {
        let state = self.load()?;
        let mut candidates = state
            .summons
            .iter()
            .filter(|record| {
                record.client_name.eq_ignore_ascii_case(client_name)
                    && matches!(record.summon_status.as_str(), "ritual_started" | "portal_ready")
            })
            .collect::<Vec<_>>();
        candidates.sort_by_key(|record| record.timestamp_created);
        let Some(record) = candidates.last() else {
            return Err(format!("no pending ritual ledger record for client {client_name:?}"));
        };
        if candidates.len() > 1 {
            let newest = record.timestamp_created;
            let same_newest = candidates
                .iter()
                .filter(|candidate| candidate.timestamp_created == newest)
                .count();
            if same_newest > 1 {
                return Err(format!("ambiguous pending ritual ledger records for {client_name:?}"));
            }
        }
        self.append(&JournalEvent::SummonStatus {
            summon_id: record.summon_id.clone(),
            status: "summoned".to_string(),
            timestamp: now,
            failure_reason: None,
        })?;
        self.load()?
            .summons
            .into_iter()
            .find(|item| item.summon_id == record.summon_id)
            .ok_or_else(|| "summon record disappeared after status append".to_string())
    }

    pub fn mark_failed(
        &self,
        summon_id: &str,
        reason: &str,
        now: u64,
    ) -> Result<(), String> {
        self.append(&JournalEvent::SummonStatus {
            summon_id: summon_id.to_string(),
            status: "failed".to_string(),
            timestamp: now,
            failure_reason: Some(reason.to_string()),
        })
    }

    pub fn correlate(&self, partner: &str, now: u64) -> Result<Correlation, String> {
        let state = self.load()?;
        let partner = partner.trim();
        if partner.is_empty() {
            return Err("partner_unknown".to_string());
        }
        let mut active = Vec::new();
        let mut fallback = Vec::new();
        for record in &state.summons {
            if !record.client_name.eq_ignore_ascii_case(partner)
                || record.summon_status != "summoned"
                || !matches!(record.payment_status.as_str(), "unpaid" | "partial")
            {
                continue;
            }
            let base = record.timestamp_summoned.unwrap_or(record.timestamp_created);
            if now < base || now.saturating_sub(base) > self.correlation_window_seconds {
                continue;
            }
            fallback.push(record);
            if now <= record.payment_session_active_until.max(base.saturating_add(self.active_session_seconds)) {
                active.push(record);
            }
        }
        let selected = match (active.len(), fallback.len()) {
            (1, _) => (active[0], "active_session_exact"),
            (n, _) if n > 1 => return Err("ambiguous_active_sessions".to_string()),
            (0, 1) => (fallback[0], "unique_unpaid_window"),
            (0, n) if n > 1 => return Err("ambiguous_unpaid_summons".to_string()),
            _ => return Err("no_matching_unpaid_summon".to_string()),
        };
        let remaining = selected
            .0
            .expected_price_copper
            .saturating_sub(selected.0.amount_paid_copper);
        Ok(Correlation {
            summon_id: selected.0.summon_id.clone(),
            remaining_copper: remaining,
            reason: selected.1.to_string(),
        })
    }

    pub fn arm_accept(
        &self,
        trade_session_id: &str,
        attempt: u32,
        partner: &str,
        offered_copper: u32,
        coinage_before: Option<u32>,
        now: u64,
    ) -> Result<ArmedAccept, String> {
        if offered_copper == 0 {
            return Err("no_gold_offer".to_string());
        }
        let coinage_before = coinage_before.ok_or_else(|| "coinage_baseline_unknown".to_string())?;
        let correlation = self.correlate(partner, now)?;
        if !self.partial_enabled && offered_copper < correlation.remaining_copper {
            return Err("underpay_policy_block".to_string());
        }
        let intent_id = format!("{}-A{}", trade_session_id, attempt.max(1));
        let state = self.load()?;
        if let Some(existing) = state.pending_intents.get(&intent_id) {
            return Ok(ArmedAccept {
                intent: existing.clone(),
                correlation,
            });
        }
        if state
            .payments
            .iter()
            .any(|event| event.intent_id.as_deref() == Some(intent_id.as_str()))
        {
            return Err("accept_attempt_already_terminal".to_string());
        }
        let intent = TradeIntent {
            intent_id,
            trade_session_id: trade_session_id.to_string(),
            summon_id: correlation.summon_id.clone(),
            partner: partner.to_string(),
            offered_copper,
            coinage_before,
            timestamp: now,
        };
        self.append(&JournalEvent::TradeIntent {
            intent: intent.clone(),
        })?;
        Ok(ArmedAccept { intent, correlation })
    }

    fn next_payment_id(&self, now: u64) -> Result<String, String> {
        let state = self.load()?;
        Ok(Self::next_id("E", now, state.payments.len() + 1))
    }

    pub fn finish_intent_cancelled(
        &self,
        intent_id: &str,
        reason: &str,
        now: u64,
    ) -> Result<PaymentEvent, String> {
        let state = self.load()?;
        if let Some(existing) = state
            .payments
            .iter()
            .find(|event| event.intent_id.as_deref() == Some(intent_id))
        {
            return Ok(existing.clone());
        }
        let intent = state
            .pending_intents
            .get(intent_id)
            .ok_or_else(|| format!("pending trade intent not found: {intent_id}"))?;
        let event = PaymentEvent {
            payment_event_id: self.next_payment_id(now)?,
            settlement_id: None,
            intent_id: Some(intent.intent_id.clone()),
            trade_session_id: intent.trade_session_id.clone(),
            summon_id: Some(intent.summon_id.clone()),
            timestamp: now,
            trade_partner: intent.partner.clone(),
            offered_copper: intent.offered_copper,
            received_copper: 0,
            status: "cancelled".to_string(),
            reason: reason.to_string(),
        };
        self.append(&JournalEvent::Payment {
            event: event.clone(),
        })?;
        Ok(event)
    }

    pub fn finish_intent_uncertain(
        &self,
        intent_id: &str,
        reason: &str,
        now: u64,
    ) -> Result<PaymentEvent, String> {
        self.finish_intent_terminal(intent_id, None, false, reason, now)
    }

    pub fn finish_intent_complete(
        &self,
        intent_id: &str,
        coinage_after: Option<u32>,
        server_trade_complete: bool,
        now: u64,
    ) -> Result<PaymentEvent, String> {
        self.finish_intent_terminal(
            intent_id,
            coinage_after,
            server_trade_complete,
            "server_trade_complete",
            now,
        )
    }

    fn finish_intent_terminal(
        &self,
        intent_id: &str,
        coinage_after: Option<u32>,
        server_trade_complete: bool,
        reason: &str,
        now: u64,
    ) -> Result<PaymentEvent, String> {
        let state = self.load()?;
        if let Some(existing) = state
            .payments
            .iter()
            .find(|event| event.intent_id.as_deref() == Some(intent_id))
        {
            return Ok(existing.clone());
        }
        let intent = state
            .pending_intents
            .get(intent_id)
            .ok_or_else(|| format!("pending trade intent not found: {intent_id}"))?;
        let mut status = "uncertain".to_string();
        let mut terminal_reason = reason.to_string();
        let mut received = 0u32;
        let mut settlement_id = None;

        if !server_trade_complete {
            terminal_reason = format!("{reason}:missing_server_trade_complete");
        } else if let Some(after) = coinage_after {
            let delta = after.saturating_sub(intent.coinage_before);
            if after > intent.coinage_before && delta == intent.offered_copper {
                received = delta;
                let record = state
                    .summons
                    .iter()
                    .find(|record| record.summon_id == intent.summon_id)
                    .ok_or_else(|| "correlated summon disappeared before settlement".to_string())?;
                let total = record.amount_paid_copper.saturating_add(received);
                status = if total < record.expected_price_copper {
                    "partial"
                } else if total == record.expected_price_copper {
                    "paid"
                } else {
                    "overpaid"
                }
                .to_string();
                settlement_id = Some(format!("SET-{intent_id}"));
                terminal_reason = "server_complete_and_coinage_delta_match".to_string();
            } else {
                terminal_reason = format!(
                    "server_complete_coinage_mismatch before={} after={} delta={} offered={}",
                    intent.coinage_before, after, delta, intent.offered_copper
                );
            }
        } else {
            terminal_reason = "server_complete_without_coinage_confirmation".to_string();
        }

        let event = PaymentEvent {
            payment_event_id: self.next_payment_id(now)?,
            settlement_id,
            intent_id: Some(intent.intent_id.clone()),
            trade_session_id: intent.trade_session_id.clone(),
            summon_id: Some(intent.summon_id.clone()),
            timestamp: now,
            trade_partner: intent.partner.clone(),
            offered_copper: intent.offered_copper,
            received_copper: received,
            status,
            reason: terminal_reason,
        };
        self.append(&JournalEvent::Payment {
            event: event.clone(),
        })?;
        Ok(event)
    }

    pub fn recent_summons(&self, limit: usize) -> Result<Vec<SummonRecord>, String> {
        let state = self.load()?;
        Ok(state.summons.into_iter().rev().take(limit).collect())
    }

    pub fn summons_for_player(&self, player: &str) -> Result<Vec<SummonRecord>, String> {
        let state = self.load()?;
        Ok(state
            .summons
            .into_iter()
            .rev()
            .filter(|record| record.client_name.eq_ignore_ascii_case(player))
            .collect())
    }

    pub fn summons_by_payment_status(
        &self,
        status: &str,
        limit: usize,
    ) -> Result<Vec<SummonRecord>, String> {
        let wanted = status.to_ascii_lowercase();
        let state = self.load()?;
        Ok(state
            .summons
            .into_iter()
            .rev()
            .filter(|record| record.payment_status == wanted)
            .take(limit)
            .collect())
    }

    pub fn payments_for_player(
        &self,
        player: Option<&str>,
        limit: usize,
    ) -> Result<Vec<PaymentEvent>, String> {
        let state = self.load()?;
        Ok(state
            .payments
            .into_iter()
            .rev()
            .filter(|event| {
                player
                    .map(|name| event.trade_partner.eq_ignore_ascii_case(name))
                    .unwrap_or(true)
            })
            .take(limit)
            .collect())
    }
}

pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn format_money(copper: u32) -> String {
    let gold = copper / 10_000;
    let silver = (copper / 100) % 100;
    let copper = copper % 100;
    format!("{gold}g{silver:02}s{copper:02}c")
}

pub fn format_summon_line(record: &SummonRecord) -> String {
    format!(
        "{} | {} | {} | expected {} | paid {} | {} | {}",
        record.client_name,
        record.timestamp_created,
        record.destination,
        format_money(record.expected_price_copper),
        format_money(record.amount_paid_copper),
        record.payment_timestamp.unwrap_or(0),
        record.payment_status.to_ascii_uppercase()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store(name: &str) -> LedgerStore {
        let path = std::env::temp_dir().join(format!(
            "wow112_tele10_{name}_{}_{}.jsonl",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        LedgerStore::new(path)
    }

    fn summoned(store: &LedgerStore, player: &str, now: u64) -> SummonRecord {
        store
            .create_ritual_started(player, "Summoner", "Hyjal", "+ hyjal", now)
            .unwrap();
        store.mark_summoned_for_client(player, now + 5).unwrap()
    }

    #[test]
    fn happy_path_exact_4g_is_paid_only_after_complete_and_delta() {
        let store = temp_store("happy");
        let record = summoned(&store, "PlayerA", 1000);
        let armed = store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 1010)
            .unwrap();
        assert_eq!(armed.correlation.summon_id, record.summon_id);
        assert_eq!(store.load().unwrap().summons[0].amount_paid_copper, 0);
        let event = store
            .finish_intent_complete(&armed.intent.intent_id, Some(140_000), true, 1011)
            .unwrap();
        assert_eq!(event.status, "paid");
        let state = store.load().unwrap();
        assert_eq!(state.summons[0].amount_paid_copper, 40_000);
        assert_eq!(state.summons[0].payment_status, "paid");
    }

    #[test]
    fn underpay_then_second_payment_becomes_paid() {
        let store = temp_store("partial");
        summoned(&store, "PlayerA", 1000);
        let first = store
            .arm_accept("T1", 1, "PlayerA", 20_000, Some(100_000), 1010)
            .unwrap();
        assert_eq!(
            store
                .finish_intent_complete(&first.intent.intent_id, Some(120_000), true, 1011)
                .unwrap()
                .status,
            "partial"
        );
        let second = store
            .arm_accept("T2", 1, "PlayerA", 20_000, Some(120_000), 1020)
            .unwrap();
        assert_eq!(
            store
                .finish_intent_complete(&second.intent.intent_id, Some(140_000), true, 1021)
                .unwrap()
                .status,
            "paid"
        );
        assert_eq!(store.load().unwrap().summons[0].amount_paid_copper, 40_000);
    }

    #[test]
    fn overpay_preserves_actual_amount() {
        let store = temp_store("overpay");
        summoned(&store, "PlayerA", 1000);
        let armed = store
            .arm_accept("T1", 1, "PlayerA", 50_000, Some(10_000), 1010)
            .unwrap();
        let event = store
            .finish_intent_complete(&armed.intent.intent_id, Some(60_000), true, 1011)
            .unwrap();
        assert_eq!(event.status, "overpaid");
        assert_eq!(store.load().unwrap().summons[0].amount_paid_copper, 50_000);
    }

    #[test]
    fn cancel_and_accept_then_cancel_never_book_gold() {
        let store = temp_store("cancel");
        summoned(&store, "PlayerA", 1000);
        let armed = store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 1010)
            .unwrap();
        let event = store
            .finish_intent_cancelled(&armed.intent.intent_id, "server_trade_cancelled", 1011)
            .unwrap();
        assert_eq!(event.status, "cancelled");
        let state = store.load().unwrap();
        assert_eq!(state.summons[0].payment_status, "unpaid");
        assert_eq!(state.summons[0].amount_paid_copper, 0);
    }

    #[test]
    fn duplicate_terminal_event_is_idempotent() {
        let store = temp_store("dedupe");
        summoned(&store, "PlayerA", 1000);
        let armed = store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 1010)
            .unwrap();
        let a = store
            .finish_intent_complete(&armed.intent.intent_id, Some(140_000), true, 1011)
            .unwrap();
        let b = store
            .finish_intent_complete(&armed.intent.intent_id, Some(140_000), true, 1012)
            .unwrap();
        assert_eq!(a.payment_event_id, b.payment_event_id);
        let state = store.load().unwrap();
        assert_eq!(state.payments.len(), 1);
        assert_eq!(state.summons[0].amount_paid_copper, 40_000);
    }

    #[test]
    fn wrong_client_is_not_correlated() {
        let store = temp_store("wrong_client");
        summoned(&store, "PlayerA", 1000);
        assert_eq!(
            store
                .arm_accept("T1", 1, "PlayerB", 40_000, Some(100_000), 1010)
                .unwrap_err(),
            "no_matching_unpaid_summon"
        );
    }

    #[test]
    fn old_unique_unpaid_summon_can_be_paid_an_hour_later() {
        let store = temp_store("old");
        summoned(&store, "PlayerA", 1000);
        let armed = store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 4600)
            .unwrap();
        assert_eq!(armed.correlation.reason, "unique_unpaid_window");
    }

    #[test]
    fn multiple_old_unpaid_same_client_fails_closed() {
        let store = temp_store("ambiguous");
        summoned(&store, "PlayerA", 1000);
        summoned(&store, "PlayerA", 2000);
        assert_eq!(
            store
                .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 5000)
                .unwrap_err(),
            "ambiguous_unpaid_summons"
        );
    }

    #[test]
    fn newer_active_session_disambiguates_same_client() {
        let store = temp_store("active");
        let old = summoned(&store, "PlayerA", 1000);
        let new = summoned(&store, "PlayerA", 2000);
        let correlation = store.correlate("PlayerA", 2010).unwrap();
        assert_eq!(correlation.summon_id, new.summon_id);
        assert_ne!(correlation.summon_id, old.summon_id);
    }

    #[test]
    fn restart_with_unresolved_accept_intent_hard_stops() {
        let store = temp_store("restart_uncertain");
        summoned(&store, "PlayerA", 1000);
        store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 1010)
            .unwrap();
        let reloaded = LedgerStore::new(store.path().to_path_buf());
        let state = reloaded.load().unwrap();
        assert_eq!(state.summons[0].payment_status, "uncertain");
        assert!(reloaded.correlate("PlayerA", 1011).is_err());
    }

    #[test]
    fn server_complete_without_matching_coinage_is_uncertain() {
        let store = temp_store("mismatch");
        summoned(&store, "PlayerA", 1000);
        let armed = store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 1010)
            .unwrap();
        let event = store
            .finish_intent_complete(&armed.intent.intent_id, Some(130_000), true, 1011)
            .unwrap();
        assert_eq!(event.status, "uncertain");
        assert_eq!(event.received_copper, 0);
        assert_eq!(store.load().unwrap().summons[0].payment_status, "uncertain");
    }

    #[test]
    fn offer_or_accept_intent_alone_never_books_payment() {
        let store = temp_store("no_phantom");
        summoned(&store, "PlayerA", 1000);
        store
            .arm_accept("T1", 1, "PlayerA", 40_000, Some(100_000), 1010)
            .unwrap();
        let state = store.load().unwrap();
        assert_eq!(state.summons[0].amount_paid_copper, 0);
        assert!(state.payments.is_empty());
    }

    #[test]
    fn journal_survives_reopen() {
        let store = temp_store("persist");
        let record = summoned(&store, "PlayerA", 1000);
        let path = store.path().to_path_buf();
        drop(store);
        let reloaded = LedgerStore::new(path);
        let state = reloaded.load().unwrap();
        assert_eq!(state.summons.len(), 1);
        assert_eq!(state.summons[0].summon_id, record.summon_id);
        assert_eq!(state.summons[0].summon_status, "summoned");
    }
}
