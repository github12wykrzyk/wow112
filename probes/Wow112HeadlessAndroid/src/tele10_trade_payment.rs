use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const CMSG_INITIATE_TRADE_OPCODE: u32 = 0x0116;
pub const CMSG_BEGIN_TRADE_OPCODE: u32 = 0x0117;
pub const CMSG_ACCEPT_TRADE_OPCODE: u32 = 0x011A;
pub const CMSG_CANCEL_TRADE_OPCODE: u32 = 0x011C;
pub const CMSG_SET_TRADE_GOLD_OPCODE: u32 = 0x011F;
pub const SMSG_TRADE_STATUS_OPCODE: u16 = 0x0120;
pub const SMSG_TRADE_STATUS_EXTENDED_OPCODE: u16 = 0x0121;

pub const TRADE_STATUS_BUSY: u32 = 0;
pub const TRADE_STATUS_BEGIN_TRADE: u32 = 1;
pub const TRADE_STATUS_OPEN_WINDOW: u32 = 2;
pub const TRADE_STATUS_TRADE_CANCELED: u32 = 3;
pub const TRADE_STATUS_TRADE_ACCEPT: u32 = 4;
pub const TRADE_STATUS_NO_TARGET: u32 = 6;
pub const TRADE_STATUS_BACK_TO_TRADE: u32 = 7;
pub const TRADE_STATUS_TRADE_COMPLETE: u32 = 8;
pub const TRADE_STATUS_TRADE_REJECTED: u32 = 9;
pub const TRADE_STATUS_TARGET_TO_FAR: u32 = 10;
pub const TRADE_STATUS_CLOSE_WINDOW: u32 = 12;

pub const DEFAULT_EXPECTED_PRICE_COPPER: u64 = 40_000;
pub const DEFAULT_ACTIVE_SESSION_SECONDS: i64 = 600;
pub const DEFAULT_CORRELATION_WINDOW_SECONDS: i64 = 21_600;

pub fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn norm(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SummonStatus {
    RitualStarted,
    Summoned,
    Failed,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PaymentStatus {
    Unpaid,
    Partial,
    Paid,
    Overpaid,
    Cancelled,
    Uncertain,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SummonRecord {
    pub summon_id: String,
    pub timestamp_created: i64,
    pub client_name: String,
    pub client_guid: u64,
    pub summoner_name: String,
    pub destination: String,
    pub trigger_message: String,
    pub expected_price_copper: u64,
    pub summon_status: SummonStatus,
    pub payment_status: PaymentStatus,
    pub amount_paid_copper: u64,
    pub payment_timestamp: Option<i64>,
    pub trade_partner: Option<String>,
    pub payment_event_id: Option<String>,
    pub settlement_id: Option<String>,
    pub last_update: i64,
    pub failure_reason: Option<String>,
    pub payment_session_active_until: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PaymentRecord {
    pub payment_event_id: String,
    pub settlement_id: Option<String>,
    pub summon_id: Option<String>,
    pub timestamp: i64,
    pub trade_partner: String,
    pub partner_guid: u64,
    pub amount_copper: u64,
    pub payment_status: PaymentStatus,
    pub failure_reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MutationRecord {
    pub mutation_id: String,
    pub trade_id: String,
    pub summon_id: String,
    pub timestamp: i64,
    pub offered_copper: u64,
    pub state: String,
    pub resolved: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LedgerState {
    pub schema_version: u32,
    pub state_revision: u64,
    pub summon_sequence: u64,
    pub payment_sequence: u64,
    pub trade_sequence: u64,
    pub mutation_sequence: u64,
    pub expected_price_copper: u64,
    pub partial_enabled: bool,
    pub active_session_seconds: i64,
    pub correlation_window_seconds: i64,
    pub summons: Vec<SummonRecord>,
    pub payments: Vec<PaymentRecord>,
    pub mutations: Vec<MutationRecord>,
    pub settlement_ids: BTreeMap<String, String>,
}

impl Default for LedgerState {
    fn default() -> Self {
        Self {
            schema_version: 1,
            state_revision: 0,
            summon_sequence: 0,
            payment_sequence: 0,
            trade_sequence: 0,
            mutation_sequence: 0,
            expected_price_copper: DEFAULT_EXPECTED_PRICE_COPPER,
            partial_enabled: false,
            active_session_seconds: DEFAULT_ACTIVE_SESSION_SECONDS,
            correlation_window_seconds: DEFAULT_CORRELATION_WINDOW_SECONDS,
            summons: Vec::new(),
            payments: Vec::new(),
            mutations: Vec::new(),
            settlement_ids: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct LedgerStore {
    path: PathBuf,
    pub state: LedgerState,
}

impl LedgerStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        let path = path.as_ref().to_path_buf();
        let mut candidates = Vec::<LedgerState>::new();
        for candidate in [path.clone(), sidecar(&path, "next"), sidecar(&path, "bak")] {
            if !candidate.exists() {
                continue;
            }
            let text = fs::read_to_string(&candidate)
                .map_err(|e| format!("read ledger {} failed: {e}", candidate.display()))?;
            match serde_json::from_str::<LedgerState>(&text) {
                Ok(state) if state.schema_version == 1 => candidates.push(state),
                Ok(state) => {
                    return Err(format!(
                        "unsupported ledger schema={} file={}",
                        state.schema_version,
                        candidate.display()
                    ))
                }
                Err(error) => {
                    eprintln!(
                        "[TELE10-LEDGER] ignored invalid recovery candidate={} cause={error}",
                        candidate.display()
                    );
                }
            }
        }
        let state = candidates
            .into_iter()
            .max_by_key(|state| state.state_revision)
            .unwrap_or_default();
        Ok(Self { path, state })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn persist(&mut self) -> Result<(), String> {
        self.state.state_revision = self.state.state_revision.saturating_add(1);
        if let Some(parent) = self.path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)
                .map_err(|e| format!("create ledger dir {} failed: {e}", parent.display()))?;
        }
        let next = sidecar(&self.path, "next");
        let bak = sidecar(&self.path, "bak");
        let body = serde_json::to_vec_pretty(&self.state)
            .map_err(|e| format!("serialize ledger failed: {e}"))?;
        {
            let mut file = File::create(&next)
                .map_err(|e| format!("create ledger next {} failed: {e}", next.display()))?;
            file.write_all(&body)
                .map_err(|e| format!("write ledger next {} failed: {e}", next.display()))?;
            file.sync_all()
                .map_err(|e| format!("sync ledger next {} failed: {e}", next.display()))?;
        }
        if self.path.exists() {
            let _ = fs::copy(&self.path, &bak);
            fs::remove_file(&self.path)
                .map_err(|e| format!("remove old ledger {} failed: {e}", self.path.display()))?;
        }
        fs::rename(&next, &self.path).map_err(|e| {
            format!(
                "commit ledger {} -> {} failed: {e}",
                next.display(),
                self.path.display()
            )
        })?;
        Ok(())
    }

    pub fn set_policy(&mut self, expected_price_copper: u64, partial_enabled: bool) {
        self.state.expected_price_copper = expected_price_copper.max(1);
        self.state.partial_enabled = partial_enabled;
    }

    pub fn record_ritual_started(
        &mut self,
        now: i64,
        client_name: &str,
        client_guid: u64,
        summoner_name: &str,
        destination: &str,
        trigger_message: &str,
    ) -> Result<String, String> {
        if client_name.trim().is_empty() || client_guid == 0 {
            return Err("summon ledger requires client name and nonzero guid".to_string());
        }
        let client_key = norm(client_name);
        for record in &mut self.state.summons {
            if norm(&record.client_name) == client_key && record.payment_session_active_until > now {
                record.payment_session_active_until = now;
                record.last_update = now;
            }
        }
        self.state.summon_sequence = self.state.summon_sequence.saturating_add(1);
        let summon_id = format!("S{now}-{:06}", self.state.summon_sequence);
        self.state.summons.push(SummonRecord {
            summon_id: summon_id.clone(),
            timestamp_created: now,
            client_name: client_name.trim().to_string(),
            client_guid,
            summoner_name: summoner_name.trim().to_string(),
            destination: destination.trim().to_string(),
            trigger_message: trigger_message.trim().to_string(),
            expected_price_copper: self.state.expected_price_copper,
            summon_status: SummonStatus::RitualStarted,
            payment_status: PaymentStatus::Unpaid,
            amount_paid_copper: 0,
            payment_timestamp: None,
            trade_partner: None,
            payment_event_id: None,
            settlement_id: None,
            last_update: now,
            failure_reason: None,
            payment_session_active_until: now.saturating_add(self.state.active_session_seconds),
        });
        self.persist()?;
        Ok(summon_id)
    }

    pub fn mark_summoned(&mut self, summon_id: &str, now: i64) -> Result<(), String> {
        let record = self
            .state
            .summons
            .iter_mut()
            .find(|record| record.summon_id == summon_id)
            .ok_or_else(|| format!("unknown summon_id={summon_id}"))?;
        record.summon_status = SummonStatus::Summoned;
        record.payment_session_active_until = now.saturating_add(self.state.active_session_seconds);
        record.last_update = now;
        self.persist()
    }

    pub fn correlate(&self, partner_name: Option<&str>, partner_guid: u64, now: i64) -> Correlation {
        let partner_key = partner_name.map(norm).filter(|value| !value.is_empty());
        let window_start = now.saturating_sub(self.state.correlation_window_seconds);
        let unresolved: Vec<&SummonRecord> = self
            .state
            .summons
            .iter()
            .filter(|record| record.timestamp_created >= window_start)
            .filter(|record| {
                matches!(record.payment_status, PaymentStatus::Unpaid | PaymentStatus::Partial)
            })
            .filter(|record| {
                let guid_match = partner_guid != 0 && record.client_guid == partner_guid;
                let name_match = partner_key
                    .as_ref()
                    .is_some_and(|key| norm(&record.client_name) == *key);
                guid_match || name_match
            })
            .collect();

        if unresolved.is_empty() {
            return Correlation::None;
        }
        let active: Vec<&SummonRecord> = unresolved
            .iter()
            .copied()
            .filter(|record| record.payment_session_active_until >= now)
            .collect();
        if active.len() == 1 {
            return Correlation::Unique(active[0].summon_id.clone());
        }
        if active.len() > 1 {
            return Correlation::Ambiguous(
                "multiple_active_summons_for_trade_partner".to_string(),
            );
        }
        if unresolved.len() == 1 {
            return Correlation::Unique(unresolved[0].summon_id.clone());
        }
        Correlation::Ambiguous("multiple_unpaid_summons_for_trade_partner".to_string())
    }

    pub fn allocate_trade_id(&mut self, now: i64) -> Result<String, String> {
        self.state.trade_sequence = self.state.trade_sequence.saturating_add(1);
        let id = format!("T{now}-{:06}", self.state.trade_sequence);
        self.persist()?;
        Ok(id)
    }

    pub fn commit_accept_mutation(
        &mut self,
        trade_id: &str,
        summon_id: &str,
        offered_copper: u64,
        partner_name: &str,
        now: i64,
    ) -> Result<String, String> {
        if self.has_unresolved_mutation_for(summon_id) {
            return Err(format!(
                "hard_stop_unresolved_trade_mutation summon_id={summon_id}"
            ));
        }
        self.state.mutation_sequence = self.state.mutation_sequence.saturating_add(1);
        let mutation_id = format!("M{now}-{:06}", self.state.mutation_sequence);
        self.state.mutations.push(MutationRecord {
            mutation_id: mutation_id.clone(),
            trade_id: trade_id.to_string(),
            summon_id: summon_id.to_string(),
            timestamp: now,
            offered_copper,
            state: "accept_committed_before_socket_write".to_string(),
            resolved: false,
        });
        let record = self
            .state
            .summons
            .iter_mut()
            .find(|record| record.summon_id == summon_id)
            .ok_or_else(|| format!("unknown summon_id={summon_id}"))?;
        record.trade_partner = Some(partner_name.to_string());
        record.payment_status = PaymentStatus::Uncertain;
        record.failure_reason = Some("trade_accept_committed_waiting_server_result".to_string());
        record.last_update = now;
        self.persist()?;
        Ok(mutation_id)
    }

    pub fn mark_accept_socket_uncertain(
        &mut self,
        mutation_id: &str,
        now: i64,
        cause: &str,
    ) -> Result<(), String> {
        let mutation = self
            .state
            .mutations
            .iter_mut()
            .find(|record| record.mutation_id == mutation_id)
            .ok_or_else(|| format!("unknown mutation_id={mutation_id}"))?;
        mutation.state = format!("accept_socket_uncertain:{cause}");
        let summon_id = mutation.summon_id.clone();
        let record = self
            .state
            .summons
            .iter_mut()
            .find(|record| record.summon_id == summon_id)
            .ok_or_else(|| format!("unknown summon_id={summon_id}"))?;
        record.payment_status = PaymentStatus::Uncertain;
        record.failure_reason = Some(format!("accept_socket_uncertain:{cause}"));
        record.last_update = now;
        self.persist()
    }

    pub fn resolve_cancelled_trade(
        &mut self,
        mutation_id: Option<&str>,
        summon_id: Option<&str>,
        partner_name: &str,
        partner_guid: u64,
        now: i64,
        reason: &str,
    ) -> Result<(), String> {
        if let Some(mutation_id) = mutation_id {
            if let Some(mutation) = self
                .state
                .mutations
                .iter_mut()
                .find(|record| record.mutation_id == mutation_id)
            {
                mutation.resolved = true;
                mutation.state = format!("server_cancelled:{reason}");
            }
        }
        self.state.payment_sequence = self.state.payment_sequence.saturating_add(1);
        let event_id = format!("P{now}-{:06}", self.state.payment_sequence);
        self.state.payments.push(PaymentRecord {
            payment_event_id: event_id.clone(),
            settlement_id: None,
            summon_id: summon_id.map(ToString::to_string),
            timestamp: now,
            trade_partner: partner_name.to_string(),
            partner_guid,
            amount_copper: 0,
            payment_status: PaymentStatus::Cancelled,
            failure_reason: Some(reason.to_string()),
        });
        if let Some(summon_id) = summon_id {
            if let Some(record) = self
                .state
                .summons
                .iter_mut()
                .find(|record| record.summon_id == summon_id)
            {
                record.payment_status = payment_status_for_amount(
                    record.amount_paid_copper,
                    record.expected_price_copper,
                );
                record.failure_reason = None;
                record.last_update = now;
            }
        }
        self.persist()
    }

    pub fn settle_trade_complete(
        &mut self,
        trade_id: &str,
        mutation_id: &str,
        summon_id: &str,
        partner_name: &str,
        partner_guid: u64,
        offered_copper: u64,
        now: i64,
    ) -> Result<SettlementOutcome, String> {
        let settlement_id = format!("{trade_id}:complete");
        if let Some(existing) = self.state.settlement_ids.get(&settlement_id) {
            return Ok(SettlementOutcome::Duplicate(existing.clone()));
        }
        let mutation = self
            .state
            .mutations
            .iter_mut()
            .find(|record| record.mutation_id == mutation_id)
            .ok_or_else(|| format!("unknown mutation_id={mutation_id}"))?;
        if mutation.resolved {
            return Err(format!("mutation_already_resolved id={mutation_id}"));
        }
        if mutation.trade_id != trade_id || mutation.summon_id != summon_id {
            return Err("mutation_trade_summon_mismatch".to_string());
        }
        if mutation.offered_copper != offered_copper || offered_copper == 0 {
            return Err("settlement_offer_mismatch_or_zero".to_string());
        }
        mutation.resolved = true;
        mutation.state = "server_trade_complete".to_string();

        self.state.payment_sequence = self.state.payment_sequence.saturating_add(1);
        let event_id = format!("P{now}-{:06}", self.state.payment_sequence);
        let record = self
            .state
            .summons
            .iter_mut()
            .find(|record| record.summon_id == summon_id)
            .ok_or_else(|| format!("unknown summon_id={summon_id}"))?;
        record.summon_status = SummonStatus::Summoned;
        record.amount_paid_copper = record.amount_paid_copper.saturating_add(offered_copper);
        record.payment_status = payment_status_for_amount(
            record.amount_paid_copper,
            record.expected_price_copper,
        );
        record.payment_timestamp = Some(now);
        record.trade_partner = Some(partner_name.to_string());
        record.payment_event_id = Some(event_id.clone());
        record.settlement_id = Some(settlement_id.clone());
        record.failure_reason = None;
        record.last_update = now;
        let resulting_status = record.payment_status;

        self.state.payments.push(PaymentRecord {
            payment_event_id: event_id.clone(),
            settlement_id: Some(settlement_id.clone()),
            summon_id: Some(summon_id.to_string()),
            timestamp: now,
            trade_partner: partner_name.to_string(),
            partner_guid,
            amount_copper: offered_copper,
            payment_status: resulting_status,
            failure_reason: None,
        });
        self.state
            .settlement_ids
            .insert(settlement_id.clone(), event_id.clone());
        self.persist()?;
        Ok(SettlementOutcome::Booked {
            settlement_id,
            event_id,
            status: resulting_status,
        })
    }

    pub fn mark_ambiguous_or_unassigned_payment(
        &mut self,
        partner_name: &str,
        partner_guid: u64,
        offered_copper: u64,
        now: i64,
        reason: &str,
    ) -> Result<(), String> {
        self.state.payment_sequence = self.state.payment_sequence.saturating_add(1);
        let event_id = format!("P{now}-{:06}", self.state.payment_sequence);
        self.state.payments.push(PaymentRecord {
            payment_event_id: event_id,
            settlement_id: None,
            summon_id: None,
            timestamp: now,
            trade_partner: partner_name.to_string(),
            partner_guid,
            amount_copper: offered_copper,
            payment_status: PaymentStatus::Uncertain,
            failure_reason: Some(reason.to_string()),
        });
        self.persist()
    }

    pub fn has_unresolved_mutation_for(&self, summon_id: &str) -> bool {
        self.state
            .mutations
            .iter()
            .any(|record| record.summon_id == summon_id && !record.resolved)
    }

    pub fn recent_summons(&self, limit: usize) -> Vec<&SummonRecord> {
        self.state.summons.iter().rev().take(limit).collect()
    }

    pub fn filtered_summons(
        &self,
        player: Option<&str>,
        payment_status: Option<PaymentStatus>,
        since: Option<i64>,
        limit: usize,
    ) -> Vec<&SummonRecord> {
        let player = player.map(norm);
        self.state
            .summons
            .iter()
            .rev()
            .filter(|record| {
                player
                    .as_ref()
                    .is_none_or(|wanted| norm(&record.client_name) == *wanted)
            })
            .filter(|record| payment_status.is_none_or(|status| record.payment_status == status))
            .filter(|record| since.is_none_or(|min_time| record.timestamp_created >= min_time))
            .take(limit)
            .collect()
    }

    pub fn recent_payments(&self, player: Option<&str>, limit: usize) -> Vec<&PaymentRecord> {
        let player = player.map(norm);
        self.state
            .payments
            .iter()
            .rev()
            .filter(|record| {
                player
                    .as_ref()
                    .is_none_or(|wanted| norm(&record.trade_partner) == *wanted)
            })
            .take(limit)
            .collect()
    }
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}.{}", path.display(), suffix))
}

fn payment_status_for_amount(amount: u64, expected: u64) -> PaymentStatus {
    if amount == 0 {
        PaymentStatus::Unpaid
    } else if amount < expected {
        PaymentStatus::Partial
    } else if amount == expected {
        PaymentStatus::Paid
    } else {
        PaymentStatus::Overpaid
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Correlation {
    None,
    Unique(String),
    Ambiguous(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettlementOutcome {
    Booked {
        settlement_id: String,
        event_id: String,
        status: PaymentStatus,
    },
    Duplicate(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TradeStatusPacket {
    pub status: u32,
    pub trader_guid: Option<u64>,
}

pub fn parse_trade_status(payload: &[u8]) -> Result<TradeStatusPacket, String> {
    if payload.len() < 4 {
        return Err(format!("trade status payload too short: {}", payload.len()));
    }
    let status = u32::from_le_bytes(payload[0..4].try_into().unwrap());
    let trader_guid = if status == TRADE_STATUS_BEGIN_TRADE {
        if payload.len() < 12 {
            return Err(format!(
                "begin-trade payload too short: {} expected>=12",
                payload.len()
            ));
        }
        Some(u64::from_le_bytes(payload[4..12].try_into().unwrap()))
    } else {
        None
    };
    Ok(TradeStatusPacket {
        status,
        trader_guid,
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TradeExtendedPacket {
    pub trader_state: bool,
    pub offered_copper: u64,
    pub spell_id: u32,
    pub has_items: bool,
}

pub fn parse_trade_extended(payload: &[u8]) -> Result<TradeExtendedPacket, String> {
    if payload.len() < 17 {
        return Err(format!("extended trade payload too short: {}", payload.len()));
    }
    let trader_state = payload[0] != 0;
    let offered_copper = u32::from_le_bytes(payload[9..13].try_into().unwrap()) as u64;
    let spell_id = u32::from_le_bytes(payload[13..17].try_into().unwrap());
    let mut has_items = false;
    let mut offset = 17usize;
    while offset + 61 <= payload.len() {
        let entry = u32::from_le_bytes(payload[offset + 1..offset + 5].try_into().unwrap());
        if entry != 0 {
            has_items = true;
            break;
        }
        offset += 61;
    }
    Ok(TradeExtendedPacket {
        trader_state,
        offered_copper,
        spell_id,
        has_items,
    })
}

#[derive(Clone, Debug)]
pub struct TradeSession {
    pub trade_id: String,
    pub partner_guid: u64,
    pub partner_name: Option<String>,
    pub summon_id: Option<String>,
    pub offered_copper: u64,
    pub partner_accepted: bool,
    pub has_items: bool,
    pub spell_id: u32,
    pub accept_mutation_id: Option<String>,
    pub accept_sent: bool,
    pub terminal: bool,
}

impl TradeSession {
    pub fn new(trade_id: String, partner_guid: u64) -> Self {
        Self {
            trade_id,
            partner_guid,
            partner_name: None,
            summon_id: None,
            offered_copper: 0,
            partner_accepted: false,
            has_items: false,
            spell_id: 0,
            accept_mutation_id: None,
            accept_sent: false,
            terminal: false,
        }
    }

    pub fn update_partner_name(&mut self, name: &str) {
        self.partner_name = Some(name.trim().to_string());
    }

    pub fn update_offer(&mut self, packet: &TradeExtendedPacket) {
        if !packet.trader_state {
            return;
        }
        self.offered_copper = packet.offered_copper;
        self.spell_id = packet.spell_id;
        self.has_items = packet.has_items;
        if self.accept_sent {
            self.partner_accepted = false;
        }
    }

    pub fn can_auto_accept(&self, ledger: &LedgerStore) -> Result<&str, String> {
        if self.terminal {
            return Err("trade_session_terminal".to_string());
        }
        if self.accept_sent || self.accept_mutation_id.is_some() {
            return Err("accept_already_committed_no_retry".to_string());
        }
        if !self.partner_accepted {
            return Err("partner_not_accepted".to_string());
        }
        if self.has_items || self.spell_id != 0 {
            return Err("gold_only_policy_blocked_items_or_spell".to_string());
        }
        if self.offered_copper == 0 {
            return Err("zero_gold_offer".to_string());
        }
        let summon_id = self
            .summon_id
            .as_deref()
            .ok_or_else(|| "trade_not_correlated".to_string())?;
        if ledger.has_unresolved_mutation_for(summon_id) {
            return Err("hard_stop_unresolved_mutation".to_string());
        }
        let summon = ledger
            .state
            .summons
            .iter()
            .find(|record| record.summon_id == summon_id)
            .ok_or_else(|| "correlated_summon_missing".to_string())?;
        let remaining = summon
            .expected_price_copper
            .saturating_sub(summon.amount_paid_copper);
        if self.offered_copper < remaining && !ledger.state.partial_enabled {
            return Err(format!(
                "underpay_blocked offered={} remaining={remaining}",
                self.offered_copper
            ));
        }
        Ok(summon_id)
    }
}

pub fn summarize_integrity(state: &LedgerState) -> Result<(), String> {
    let mut summon_ids = HashSet::new();
    for record in &state.summons {
        if !summon_ids.insert(record.summon_id.clone()) {
            return Err(format!("duplicate summon_id={}", record.summon_id));
        }
    }
    let mut event_ids = HashSet::new();
    for payment in &state.payments {
        if !event_ids.insert(payment.payment_event_id.clone()) {
            return Err(format!(
                "duplicate payment_event_id={}",
                payment.payment_event_id
            ));
        }
    }
    let mut mutation_ids = HashSet::new();
    for mutation in &state.mutations {
        if !mutation_ids.insert(mutation.mutation_id.clone()) {
            return Err(format!("duplicate mutation_id={}", mutation.mutation_id));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "wow112_tele10_trade_test_{}_{}_{}.json",
            std::process::id(),
            unix_now(),
            tag
        ));
        let _ = fs::remove_file(&path);
        let _ = fs::remove_file(sidecar(&path, "next"));
        let _ = fs::remove_file(sidecar(&path, "bak"));
        path
    }

    fn seeded(tag: &str, partial: bool) -> (LedgerStore, String, PathBuf) {
        let path = temp_path(tag);
        let mut ledger = LedgerStore::open(&path).unwrap();
        ledger.set_policy(40_000, partial);
        let summon_id = ledger
            .record_ritual_started(1_000, "Clienta", 0xAA, "Summoner", "hyjal", "+")
            .unwrap();
        ledger.mark_summoned(&summon_id, 1_010).unwrap();
        (ledger, summon_id, path)
    }

    fn book(
        ledger: &mut LedgerStore,
        summon_id: &str,
        amount: u64,
        trade_seq: i64,
    ) -> SettlementOutcome {
        let trade_id = ledger.allocate_trade_id(trade_seq).unwrap();
        let mutation = ledger
            .commit_accept_mutation(
                &trade_id,
                summon_id,
                amount,
                "Clienta",
                trade_seq + 1,
            )
            .unwrap();
        ledger
            .settle_trade_complete(
                &trade_id,
                &mutation,
                summon_id,
                "Clienta",
                0xAA,
                amount,
                trade_seq + 2,
            )
            .unwrap()
    }

    #[test]
    fn exact_4g_books_paid_only_after_complete() {
        let (mut ledger, summon_id, _) = seeded("exact", false);
        let trade = ledger.allocate_trade_id(2_000).unwrap();
        let mutation = ledger
            .commit_accept_mutation(&trade, &summon_id, 40_000, "Clienta", 2_001)
            .unwrap();
        assert_eq!(
            ledger.state.summons[0].payment_status,
            PaymentStatus::Uncertain
        );
        let out = ledger
            .settle_trade_complete(
                &trade,
                &mutation,
                &summon_id,
                "Clienta",
                0xAA,
                40_000,
                2_002,
            )
            .unwrap();
        assert!(matches!(
            out,
            SettlementOutcome::Booked {
                status: PaymentStatus::Paid,
                ..
            }
        ));
        assert_eq!(ledger.state.summons[0].amount_paid_copper, 40_000);
    }

    #[test]
    fn underpay_policy_blocks_by_default() {
        let (ledger, summon_id, _) = seeded("under_block", false);
        let mut session = TradeSession::new("T1".to_string(), 0xAA);
        session.summon_id = Some(summon_id);
        session.partner_accepted = true;
        session.offered_copper = 30_000;
        assert!(session.can_auto_accept(&ledger).unwrap_err().contains("underpay_blocked"));
    }

    #[test]
    fn partial_3g_can_be_booked_when_policy_enabled() {
        let (mut ledger, summon_id, _) = seeded("under_accept", true);
        book(&mut ledger, &summon_id, 30_000, 2_100);
        assert_eq!(ledger.state.summons[0].payment_status, PaymentStatus::Partial);
        assert_eq!(ledger.state.summons[0].amount_paid_copper, 30_000);
    }

    #[test]
    fn overpay_5g_is_preserved() {
        let (mut ledger, summon_id, _) = seeded("over", false);
        book(&mut ledger, &summon_id, 50_000, 2_200);
        assert_eq!(ledger.state.summons[0].payment_status, PaymentStatus::Overpaid);
        assert_eq!(ledger.state.summons[0].amount_paid_copper, 50_000);
    }

    #[test]
    fn two_partial_2g_payments_reach_paid() {
        let (mut ledger, summon_id, _) = seeded("two_partial", true);
        book(&mut ledger, &summon_id, 20_000, 2_300);
        assert_eq!(ledger.state.summons[0].payment_status, PaymentStatus::Partial);
        book(&mut ledger, &summon_id, 20_000, 2_400);
        assert_eq!(ledger.state.summons[0].payment_status, PaymentStatus::Paid);
        assert_eq!(ledger.state.summons[0].amount_paid_copper, 40_000);
    }

    #[test]
    fn cancel_after_accept_resolves_uncertain_without_booking() {
        let (mut ledger, summon_id, _) = seeded("cancel", false);
        let trade = ledger.allocate_trade_id(2_500).unwrap();
        let mutation = ledger
            .commit_accept_mutation(&trade, &summon_id, 40_000, "Clienta", 2_501)
            .unwrap();
        ledger
            .resolve_cancelled_trade(
                Some(&mutation),
                Some(&summon_id),
                "Clienta",
                0xAA,
                2_502,
                "server_trade_cancelled",
            )
            .unwrap();
        assert_eq!(ledger.state.summons[0].payment_status, PaymentStatus::Unpaid);
        assert_eq!(ledger.state.summons[0].amount_paid_copper, 0);
        assert!(ledger.state.mutations[0].resolved);
    }

    #[test]
    fn duplicate_complete_is_idempotent() {
        let (mut ledger, summon_id, _) = seeded("duplicate", false);
        let trade = ledger.allocate_trade_id(2_600).unwrap();
        let mutation = ledger
            .commit_accept_mutation(&trade, &summon_id, 40_000, "Clienta", 2_601)
            .unwrap();
        let first = ledger
            .settle_trade_complete(
                &trade,
                &mutation,
                &summon_id,
                "Clienta",
                0xAA,
                40_000,
                2_602,
            )
            .unwrap();
        let second = ledger
            .settle_trade_complete(
                &trade,
                &mutation,
                &summon_id,
                "Clienta",
                0xAA,
                40_000,
                2_603,
            )
            .unwrap();
        assert!(matches!(first, SettlementOutcome::Booked { .. }));
        assert!(matches!(second, SettlementOutcome::Duplicate(_)));
        assert_eq!(ledger.state.summons[0].amount_paid_copper, 40_000);
        assert_eq!(ledger.state.payments.len(), 1);
    }

    #[test]
    fn wrong_client_does_not_correlate() {
        let (ledger, _, _) = seeded("wrong_client", false);
        assert_eq!(ledger.correlate(Some("Other"), 0xBB, 1_020), Correlation::None);
    }

    #[test]
    fn old_unique_unpaid_can_pay_one_hour_later() {
        let (ledger, summon_id, _) = seeded("late", false);
        assert_eq!(
            ledger.correlate(Some("Clienta"), 0xAA, 4_600),
            Correlation::Unique(summon_id)
        );
    }

    #[test]
    fn newer_active_summon_wins_same_client() {
        let (mut ledger, old_id, _) = seeded("newer", false);
        let new_id = ledger
            .record_ritual_started(1_100, "Clienta", 0xAA, "Summoner", "azshara", "+ azshara")
            .unwrap();
        assert_ne!(old_id, new_id);
        assert_eq!(
            ledger.correlate(Some("Clienta"), 0xAA, 1_101),
            Correlation::Unique(new_id)
        );
    }

    #[test]
    fn multiple_old_unpaid_same_client_is_ambiguous() {
        let (mut ledger, _, _) = seeded("ambiguous", false);
        ledger
            .record_ritual_started(1_100, "Clienta", 0xAA, "Summoner", "azshara", "+ azshara")
            .unwrap();
        let result = ledger.correlate(Some("Clienta"), 0xAA, 2_000);
        assert!(matches!(result, Correlation::Ambiguous(_)));
    }

    #[test]
    fn unresolved_accept_survives_restart_and_hard_stops() {
        let (mut ledger, summon_id, path) = seeded("restart_uncertain", false);
        let trade = ledger.allocate_trade_id(3_000).unwrap();
        ledger
            .commit_accept_mutation(&trade, &summon_id, 40_000, "Clienta", 3_001)
            .unwrap();
        drop(ledger);
        let reopened = LedgerStore::open(path).unwrap();
        assert!(reopened.has_unresolved_mutation_for(&summon_id));
        let mut session = TradeSession::new("T2".to_string(), 0xAA);
        session.summon_id = Some(summon_id);
        session.partner_accepted = true;
        session.offered_copper = 40_000;
        assert!(session
            .can_auto_accept(&reopened)
            .unwrap_err()
            .contains("hard_stop"));
    }

    #[test]
    fn parser_trade_status_begin_and_complete() {
        let mut begin = Vec::new();
        begin.extend_from_slice(&TRADE_STATUS_BEGIN_TRADE.to_le_bytes());
        begin.extend_from_slice(&0x1122334455667788u64.to_le_bytes());
        let parsed = parse_trade_status(&begin).unwrap();
        assert_eq!(parsed.status, TRADE_STATUS_BEGIN_TRADE);
        assert_eq!(parsed.trader_guid, Some(0x1122334455667788));
        let complete = parse_trade_status(&TRADE_STATUS_TRADE_COMPLETE.to_le_bytes()).unwrap();
        assert_eq!(complete.status, TRADE_STATUS_TRADE_COMPLETE);
        assert_eq!(complete.trader_guid, None);
    }

    #[test]
    fn parser_extended_reads_partner_money_and_items() {
        let mut payload = vec![1u8];
        payload.extend_from_slice(&7u32.to_le_bytes());
        payload.extend_from_slice(&7u32.to_le_bytes());
        payload.extend_from_slice(&40_000u32.to_le_bytes());
        payload.extend_from_slice(&0u32.to_le_bytes());
        payload.push(0);
        payload.extend_from_slice(&0u32.to_le_bytes());
        payload.extend_from_slice(&[0u8; 56]);
        let parsed = parse_trade_extended(&payload).unwrap();
        assert!(parsed.trader_state);
        assert_eq!(parsed.offered_copper, 40_000);
        assert!(!parsed.has_items);
    }

    #[test]
    fn gold_only_policy_rejects_items() {
        let (ledger, summon_id, _) = seeded("items", false);
        let mut session = TradeSession::new("T1".to_string(), 0xAA);
        session.summon_id = Some(summon_id);
        session.partner_accepted = true;
        session.offered_copper = 40_000;
        session.has_items = true;
        assert!(session.can_auto_accept(&ledger).unwrap_err().contains("gold_only"));
    }

    #[test]
    fn integrity_check_passes_seeded_state() {
        let (ledger, _, _) = seeded("integrity", false);
        summarize_integrity(&ledger.state).unwrap();
    }
}
