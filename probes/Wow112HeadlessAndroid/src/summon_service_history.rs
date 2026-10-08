use crate::tele10_trade_payment::{LedgerState, PaymentStatus, SummonRecord};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryRow {
    pub summon_id: String,
    pub timestamp_created: i64,
    pub client_name: String,
    pub summoner_name: String,
    pub destination: String,
    pub expected_price_copper: u64,
    pub amount_paid_copper: u64,
    pub payment_status: PaymentStatus,
    pub payment_timestamp: Option<i64>,
    pub settlement_id: Option<String>,
}

impl From<&SummonRecord> for HistoryRow {
    fn from(value: &SummonRecord) -> Self {
        Self {
            summon_id: value.summon_id.clone(),
            timestamp_created: value.timestamp_created,
            client_name: value.client_name.clone(),
            summoner_name: value.summoner_name.clone(),
            destination: value.destination.clone(),
            expected_price_copper: value.expected_price_copper,
            amount_paid_copper: value.amount_paid_copper,
            payment_status: value.payment_status,
            payment_timestamp: value.payment_timestamp,
            settlement_id: value.settlement_id.clone(),
        }
    }
}

pub fn history_for_client(
    state: &LedgerState,
    client_name: Option<&str>,
    since_unix: Option<i64>,
) -> Vec<HistoryRow> {
    let key = client_name.map(|value| value.trim().to_ascii_lowercase());
    let mut rows = state
        .summons
        .iter()
        .filter(|record| {
            key.as_ref()
                .map(|wanted| record.client_name.trim().to_ascii_lowercase() == *wanted)
                .unwrap_or(true)
        })
        .filter(|record| {
            since_unix
                .map(|since| record.timestamp_created >= since || record.payment_timestamp.is_some_and(|ts| ts >= since))
                .unwrap_or(true)
        })
        .map(HistoryRow::from)
        .collect::<Vec<_>>();
    rows.sort_by_key(|row| (row.timestamp_created, row.summon_id.clone()));
    rows.reverse();
    rows
}

pub fn payment_status_label(status: PaymentStatus) -> &'static str {
    match status {
        PaymentStatus::Unpaid => "UNPAID",
        PaymentStatus::Partial => "PARTIAL",
        PaymentStatus::Paid => "PAID",
        PaymentStatus::Overpaid => "OVERPAID",
        PaymentStatus::Cancelled => "CANCELLED",
        PaymentStatus::Uncertain => "UNCERTAIN",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tele10_trade_payment::{LedgerState, SummonStatus};

    fn record(id: &str, client: &str, created: i64, paid_at: Option<i64>, status: PaymentStatus) -> SummonRecord {
        SummonRecord {
            summon_id: id.to_string(),
            timestamp_created: created,
            client_name: client.to_string(),
            client_guid: 1,
            summoner_name: "Summoner".to_string(),
            destination: "hyjal".to_string(),
            trigger_message: "hyjal pls".to_string(),
            expected_price_copper: 40_000,
            summon_status: SummonStatus::Summoned,
            payment_status: status,
            amount_paid_copper: if paid_at.is_some() { 40_000 } else { 0 },
            payment_timestamp: paid_at,
            trade_partner: paid_at.map(|_| client.to_string()),
            payment_event_id: None,
            settlement_id: paid_at.map(|_| format!("settle-{id}")),
            last_update: paid_at.unwrap_or(created),
            failure_reason: None,
            payment_session_active_until: created + 600,
        }
    }

    #[test]
    fn query_finds_payment_that_happened_an_hour_later() {
        let mut state = LedgerState::default();
        state.summons.push(record("s1", "ClientA", 1_000, Some(4_600), PaymentStatus::Paid));
        let rows = history_for_client(&state, Some("clienta"), Some(4_000));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].payment_timestamp, Some(4_600));
        assert_eq!(rows[0].amount_paid_copper, 40_000);
        assert_eq!(payment_status_label(rows[0].payment_status), "PAID");
    }

    #[test]
    fn client_filter_is_case_insensitive_and_newest_first() {
        let mut state = LedgerState::default();
        state.summons.push(record("old", "ClientA", 10, None, PaymentStatus::Unpaid));
        state.summons.push(record("new", "clienta", 20, Some(21), PaymentStatus::Paid));
        state.summons.push(record("other", "ClientB", 30, None, PaymentStatus::Unpaid));
        let rows = history_for_client(&state, Some("CLIENTA"), None);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].summon_id, "new");
        assert_eq!(rows[1].summon_id, "old");
    }
}
