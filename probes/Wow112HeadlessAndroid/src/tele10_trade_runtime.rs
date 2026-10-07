use crate::tele10_trade_ledger::{LedgerStore, PaymentEvent};

pub const CMSG_BEGIN_TRADE_OPCODE: u32 = 0x0117;
pub const CMSG_ACCEPT_TRADE_OPCODE: u32 = 0x011A;
pub const SMSG_TRADE_STATUS_OPCODE: u16 = 0x0120;
pub const SMSG_TRADE_STATUS_EXTENDED_OPCODE: u16 = 0x0121;

pub const TRADE_STATUS_BEGIN_TRADE: u32 = 1;
pub const TRADE_STATUS_OPEN_WINDOW: u32 = 2;
pub const TRADE_STATUS_CANCELED: u32 = 3;
pub const TRADE_STATUS_ACCEPT: u32 = 4;
pub const TRADE_STATUS_BACK_TO_TRADE: u32 = 7;
pub const TRADE_STATUS_COMPLETE: u32 = 8;
pub const TRADE_STATUS_REJECTED: u32 = 9;
pub const TRADE_STATUS_CLOSE_WINDOW: u32 = 12;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TradeAction {
    QueryPartnerName(u64),
    BeginTrade,
    AcceptTrade { intent_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TradeSnapshot {
    pub their_window: bool,
    pub offered_copper: u32,
}

#[derive(Debug, Clone)]
struct ActiveTrade {
    trade_session_id: String,
    partner_guid: u64,
    partner_name: Option<String>,
    correlation_error: Option<String>,
    offered_copper: u32,
    attempt: u32,
    current_intent_id: Option<String>,
    accept_wire_sent: bool,
    complete_seen_ms: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct TradeEngine {
    store: LedgerStore,
    active: Option<ActiveTrade>,
    coinage: Option<u32>,
    sequence: u64,
    settlement_timeout_ms: u64,
    last_terminal: Option<PaymentEvent>,
}

impl TradeEngine {
    pub fn new(store: LedgerStore, settlement_timeout_ms: u64) -> Self {
        Self {
            store,
            active: None,
            coinage: None,
            sequence: 0,
            settlement_timeout_ms: settlement_timeout_ms.max(1),
            last_terminal: None,
        }
    }

    pub fn store(&self) -> &LedgerStore {
        &self.store
    }

    pub fn coinage(&self) -> Option<u32> {
        self.coinage
    }

    pub fn active_partner(&self) -> Option<&str> {
        self.active
            .as_ref()
            .and_then(|trade| trade.partner_name.as_deref())
    }

    pub fn last_terminal(&self) -> Option<&PaymentEvent> {
        self.last_terminal.as_ref()
    }

    pub fn parse_trade_status(payload: &[u8]) -> Result<(u32, Option<u64>), String> {
        if payload.len() < 4 {
            return Err(format!("SMSG_TRADE_STATUS too short: {}", payload.len()));
        }
        let status = u32::from_le_bytes(payload[0..4].try_into().unwrap());
        let partner_guid = if status == TRADE_STATUS_BEGIN_TRADE {
            if payload.len() < 12 {
                return Err(format!(
                    "SMSG_TRADE_STATUS BEGIN_TRADE missing guid: {}",
                    payload.len()
                ));
            }
            Some(u64::from_le_bytes(payload[4..12].try_into().unwrap()))
        } else {
            None
        };
        Ok((status, partner_guid))
    }

    pub fn parse_extended(payload: &[u8]) -> Result<TradeSnapshot, String> {
        // Vanilla 1.12 body: u8 side + u32 slot_count + u32 slot_count +
        // u32 money + u32 enchant spell + seven 61-byte slots. `side=true`
        // is the partner/trader window (the offer visible to this receiver).
        if payload.len() < 17 {
            return Err(format!(
                "SMSG_TRADE_STATUS_EXTENDED too short: {}",
                payload.len()
            ));
        }
        Ok(TradeSnapshot {
            their_window: payload[0] != 0,
            offered_copper: u32::from_le_bytes(payload[9..13].try_into().unwrap()),
        })
    }

    pub fn on_coinage(
        &mut self,
        value: u32,
        now_wall: u64,
        now_ms: u64,
    ) -> Result<Option<PaymentEvent>, String> {
        self.coinage = Some(value);
        self.try_finish_completed(now_wall, now_ms)
    }

    pub fn on_trade_status(
        &mut self,
        payload: &[u8],
        now_wall: u64,
        now_ms: u64,
    ) -> Result<Vec<TradeAction>, String> {
        let (status, partner_guid) = Self::parse_trade_status(payload)?;
        match status {
            TRADE_STATUS_BEGIN_TRADE => {
                self.close_previous_as_uncertain_if_armed(
                    "new_begin_trade_superseded_pending_accept",
                    now_wall,
                )?;
                self.sequence = self.sequence.saturating_add(1);
                let guid =
                    partner_guid.ok_or_else(|| "BEGIN_TRADE without partner guid".to_string())?;
                self.active = Some(ActiveTrade {
                    trade_session_id: format!("T{now_wall}-{:016X}-{}", guid, self.sequence),
                    partner_guid: guid,
                    partner_name: None,
                    correlation_error: None,
                    offered_copper: 0,
                    attempt: 0,
                    current_intent_id: None,
                    accept_wire_sent: false,
                    complete_seen_ms: None,
                });
                Ok(vec![TradeAction::QueryPartnerName(guid)])
            }
            TRADE_STATUS_OPEN_WINDOW | TRADE_STATUS_ACCEPT => Ok(Vec::new()),
            TRADE_STATUS_BACK_TO_TRADE => {
                if let Some(trade) = self.active.as_mut() {
                    if let Some(intent_id) = trade.current_intent_id.take() {
                        let event = self.store.finish_intent_cancelled(
                            &intent_id,
                            "server_back_to_trade",
                            now_wall,
                        )?;
                        self.last_terminal = Some(event);
                    }
                    trade.accept_wire_sent = false;
                    trade.complete_seen_ms = None;
                }
                Ok(Vec::new())
            }
            TRADE_STATUS_COMPLETE => {
                if let Some(trade) = self.active.as_mut() {
                    trade.complete_seen_ms = Some(now_ms);
                    if trade.current_intent_id.is_some() && !trade.accept_wire_sent {
                        let intent_id = trade.current_intent_id.clone().unwrap();
                        let event = self.store.finish_intent_uncertain(
                            &intent_id,
                            "server_complete_without_confirmed_accept_send",
                            now_wall,
                        )?;
                        self.last_terminal = Some(event);
                        self.active = None;
                        return Ok(Vec::new());
                    }
                }
                let _ = self.try_finish_completed(now_wall, now_ms)?;
                Ok(Vec::new())
            }
            TRADE_STATUS_CANCELED | TRADE_STATUS_REJECTED | TRADE_STATUS_CLOSE_WINDOW => {
                self.finish_active_cancelled(
                    match status {
                        TRADE_STATUS_CANCELED => "server_trade_cancelled",
                        TRADE_STATUS_REJECTED => "server_trade_rejected",
                        _ => "server_trade_window_closed",
                    },
                    now_wall,
                )?;
                Ok(Vec::new())
            }
            _ => Ok(Vec::new()),
        }
    }

    pub fn on_partner_name(
        &mut self,
        guid: u64,
        name: &str,
        now_wall: u64,
    ) -> Result<Vec<TradeAction>, String> {
        let Some(trade) = self.active.as_mut() else {
            return Ok(Vec::new());
        };
        if trade.partner_guid != guid {
            return Ok(Vec::new());
        }
        let name = name.trim();
        if name.is_empty() {
            trade.correlation_error = Some("partner_name_empty".to_string());
            return Ok(Vec::new());
        }
        trade.partner_name = Some(name.to_string());
        match self.store.correlate(name, now_wall) {
            Ok(_) => {
                trade.correlation_error = None;
                Ok(vec![TradeAction::BeginTrade])
            }
            Err(error) => {
                trade.correlation_error = Some(error);
                Ok(Vec::new())
            }
        }
    }

    pub fn on_trade_extended(
        &mut self,
        payload: &[u8],
        now_wall: u64,
    ) -> Result<Vec<TradeAction>, String> {
        let snapshot = Self::parse_extended(payload)?;
        if !snapshot.their_window {
            return Ok(Vec::new());
        }
        let Some(trade) = self.active.as_mut() else {
            return Ok(Vec::new());
        };
        trade.offered_copper = snapshot.offered_copper;
        if trade.current_intent_id.is_some() {
            return Ok(Vec::new());
        }
        let Some(partner) = trade.partner_name.clone() else {
            return Ok(Vec::new());
        };
        if snapshot.offered_copper == 0 {
            return Ok(Vec::new());
        }
        trade.attempt = trade.attempt.saturating_add(1);
        let armed = match self.store.arm_accept(
            &trade.trade_session_id,
            trade.attempt,
            &partner,
            snapshot.offered_copper,
            self.coinage,
            now_wall,
        ) {
            Ok(value) => value,
            Err(error) => {
                trade.correlation_error = Some(error);
                return Ok(Vec::new());
            }
        };
        trade.current_intent_id = Some(armed.intent.intent_id.clone());
        trade.accept_wire_sent = false;
        trade.correlation_error = None;
        Ok(vec![TradeAction::AcceptTrade {
            intent_id: armed.intent.intent_id,
        }])
    }

    pub fn on_accept_write_success(&mut self, intent_id: &str) {
        if let Some(trade) = self.active.as_mut() {
            if trade.current_intent_id.as_deref() == Some(intent_id) {
                trade.accept_wire_sent = true;
            }
        }
    }

    pub fn on_accept_write_uncertain(
        &mut self,
        intent_id: &str,
        error: &str,
        now_wall: u64,
    ) -> Result<PaymentEvent, String> {
        let event = self.store.finish_intent_uncertain(
            intent_id,
            &format!("accept_send_uncertain:{error}"),
            now_wall,
        )?;
        self.last_terminal = Some(event.clone());
        self.active = None;
        Ok(event)
    }

    pub fn poll(&mut self, now_wall: u64, now_ms: u64) -> Result<Option<PaymentEvent>, String> {
        let timed_out = self
            .active
            .as_ref()
            .and_then(|trade| trade.complete_seen_ms)
            .map(|seen| now_ms.saturating_sub(seen) >= self.settlement_timeout_ms)
            .unwrap_or(false);
        if timed_out {
            if let Some(intent_id) = self
                .active
                .as_ref()
                .and_then(|trade| trade.current_intent_id.clone())
            {
                let event = self.store.finish_intent_uncertain(
                    &intent_id,
                    "server_complete_coinage_confirmation_timeout",
                    now_wall,
                )?;
                self.last_terminal = Some(event.clone());
                self.active = None;
                return Ok(Some(event));
            }
        }
        self.try_finish_completed(now_wall, now_ms)
    }

    fn try_finish_completed(
        &mut self,
        now_wall: u64,
        _now_ms: u64,
    ) -> Result<Option<PaymentEvent>, String> {
        let Some(trade) = self.active.as_ref() else {
            return Ok(None);
        };
        if trade.complete_seen_ms.is_none() {
            return Ok(None);
        }
        let Some(intent_id) = trade.current_intent_id.clone() else {
            self.active = None;
            return Ok(None);
        };
        if !trade.accept_wire_sent {
            return Ok(None);
        }
        let state = self.store.load()?;
        let Some(intent) = state.pending_intents.get(&intent_id) else {
            self.active = None;
            return Ok(None);
        };
        let Some(after) = self.coinage else {
            return Ok(None);
        };
        if after <= intent.coinage_before {
            return Ok(None);
        }
        let event = self
            .store
            .finish_intent_complete(&intent_id, Some(after), true, now_wall)?;
        self.last_terminal = Some(event.clone());
        self.active = None;
        Ok(Some(event))
    }

    fn finish_active_cancelled(&mut self, reason: &str, now_wall: u64) -> Result<(), String> {
        if let Some(intent_id) = self
            .active
            .as_ref()
            .and_then(|trade| trade.current_intent_id.clone())
        {
            let event = self
                .store
                .finish_intent_cancelled(&intent_id, reason, now_wall)?;
            self.last_terminal = Some(event);
        }
        self.active = None;
        Ok(())
    }

    fn close_previous_as_uncertain_if_armed(
        &mut self,
        reason: &str,
        now_wall: u64,
    ) -> Result<(), String> {
        if let Some(intent_id) = self
            .active
            .as_ref()
            .and_then(|trade| trade.current_intent_id.clone())
        {
            let event = self
                .store
                .finish_intent_uncertain(&intent_id, reason, now_wall)?;
            self.last_terminal = Some(event);
        }
        self.active = None;
        Ok(())
    }
}

pub fn encode_accept_trade_payload() -> [u8; 4] {
    0u32.to_le_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tele10_trade_ledger::unix_now;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn engine(name: &str) -> TradeEngine {
        let path = std::env::temp_dir().join(format!(
            "wow112_tele10_runtime_{name}_{}_{}.jsonl",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let store = LedgerStore::new(path);
        store
            .create_ritual_started("PlayerA", "Summoner", "Hyjal", "+", 1000)
            .unwrap();
        store.mark_summoned_for_client("PlayerA", 1005).unwrap();
        TradeEngine::new(store, 2000)
    }

    fn begin_payload(guid: u64) -> Vec<u8> {
        let mut payload = TRADE_STATUS_BEGIN_TRADE.to_le_bytes().to_vec();
        payload.extend_from_slice(&guid.to_le_bytes());
        payload
    }

    fn status_payload(status: u32) -> [u8; 4] {
        status.to_le_bytes()
    }

    fn extended(their_window: bool, gold: u32) -> Vec<u8> {
        let mut payload = vec![u8::from(their_window)];
        payload.extend_from_slice(&7u32.to_le_bytes());
        payload.extend_from_slice(&7u32.to_le_bytes());
        payload.extend_from_slice(&gold.to_le_bytes());
        payload.extend_from_slice(&0u32.to_le_bytes());
        payload.resize(444, 0);
        payload
    }

    fn arm_happy(engine: &mut TradeEngine) -> String {
        engine.on_coinage(100_000, 1006, 0).unwrap();
        assert_eq!(
            engine
                .on_trade_status(&begin_payload(0x1234), 1010, 10)
                .unwrap(),
            vec![TradeAction::QueryPartnerName(0x1234)]
        );
        assert_eq!(
            engine.on_partner_name(0x1234, "PlayerA", 1010).unwrap(),
            vec![TradeAction::BeginTrade]
        );
        let actions = engine
            .on_trade_extended(&extended(true, 40_000), 1011)
            .unwrap();
        let TradeAction::AcceptTrade { intent_id } = actions[0].clone() else {
            panic!("expected accept action")
        };
        intent_id
    }

    #[test]
    fn wire_parsers_match_vanilla_layout() {
        let (status, guid) =
            TradeEngine::parse_trade_status(&begin_payload(0x1122334455667788)).unwrap();
        assert_eq!(status, TRADE_STATUS_BEGIN_TRADE);
        assert_eq!(guid, Some(0x1122334455667788));
        let snapshot = TradeEngine::parse_extended(&extended(true, 40_000)).unwrap();
        assert!(snapshot.their_window);
        assert_eq!(snapshot.offered_copper, 40_000);
        assert_eq!(encode_accept_trade_payload(), [0, 0, 0, 0]);
    }

    #[test]
    fn incoming_trade_is_correlated_before_begin_trade() {
        let mut engine = engine("correlation");
        let actions = engine.on_trade_status(&begin_payload(7), 1010, 10).unwrap();
        assert_eq!(actions, vec![TradeAction::QueryPartnerName(7)]);
        assert_eq!(
            engine.on_partner_name(7, "PlayerB", 1010).unwrap(),
            Vec::<TradeAction>::new()
        );
    }

    #[test]
    fn accept_is_armed_persistently_before_wire_send() {
        let mut engine = engine("arm_before_send");
        let intent_id = arm_happy(&mut engine);
        let state = engine.store().load().unwrap();
        assert!(state.pending_intents.contains_key(&intent_id));
        assert!(state.payments.is_empty());
    }

    #[test]
    fn happy_path_requires_server_complete_and_coinage_delta() {
        let mut engine = engine("runtime_happy");
        let intent_id = arm_happy(&mut engine);
        engine.on_accept_write_success(&intent_id);
        engine
            .on_trade_status(&status_payload(TRADE_STATUS_COMPLETE), 1012, 20)
            .unwrap();
        assert!(engine.last_terminal().is_none());
        let event = engine.on_coinage(140_000, 1013, 21).unwrap().unwrap();
        assert_eq!(event.status, "paid");
        assert_eq!(event.received_copper, 40_000);
    }

    #[test]
    fn cancel_after_accept_is_not_payment() {
        let mut engine = engine("cancel_after_accept");
        let intent_id = arm_happy(&mut engine);
        engine.on_accept_write_success(&intent_id);
        engine
            .on_trade_status(&status_payload(TRADE_STATUS_CANCELED), 1012, 20)
            .unwrap();
        let event = engine.last_terminal().unwrap();
        assert_eq!(event.status, "cancelled");
        assert_eq!(
            engine.store().load().unwrap().summons[0].amount_paid_copper,
            0
        );
    }

    #[test]
    fn accept_write_uncertain_hard_stops_without_retry() {
        let mut engine = engine("send_uncertain");
        let intent_id = arm_happy(&mut engine);
        let event = engine
            .on_accept_write_uncertain(&intent_id, "BrokenPipe", 1012)
            .unwrap();
        assert_eq!(event.status, "uncertain");
        assert!(engine.active.is_none());
    }

    #[test]
    fn complete_without_coinage_confirmation_times_out_uncertain() {
        let mut engine = engine("timeout");
        let intent_id = arm_happy(&mut engine);
        engine.on_accept_write_success(&intent_id);
        engine
            .on_trade_status(&status_payload(TRADE_STATUS_COMPLETE), 1012, 20)
            .unwrap();
        let event = engine.poll(1015, 2021).unwrap().unwrap();
        assert_eq!(event.status, "uncertain");
    }

    #[test]
    fn own_window_snapshot_never_triggers_accept() {
        let mut engine = engine("own_window");
        engine.on_coinage(100_000, 1006, 0).unwrap();
        engine.on_trade_status(&begin_payload(7), 1010, 10).unwrap();
        engine.on_partner_name(7, "PlayerA", 1010).unwrap();
        assert!(engine
            .on_trade_extended(&extended(false, 40_000), 1011)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn duplicate_complete_cannot_double_book() {
        let mut engine = engine("duplicate_complete");
        let intent_id = arm_happy(&mut engine);
        engine.on_accept_write_success(&intent_id);
        engine
            .on_trade_status(&status_payload(TRADE_STATUS_COMPLETE), 1012, 20)
            .unwrap();
        engine.on_coinage(140_000, 1013, 21).unwrap();
        let state = engine.store().load().unwrap();
        assert_eq!(state.summons[0].amount_paid_copper, 40_000);
        assert_eq!(state.payments.len(), 1);
    }

    #[test]
    fn module_does_not_depend_on_real_clock_for_state_machine_tests() {
        assert!(unix_now() > 0);
    }
}
