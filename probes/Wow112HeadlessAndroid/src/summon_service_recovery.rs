//! Durable correlation recovery for post-portal and payment-wait restarts.

use crate::tele10_trade_payment::{LedgerState, PaymentStatus, SummonStatus};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResumeSummon {
    pub summon_id: String,
    pub client_guid: u64,
    pub summon_status: SummonStatus,
}

pub fn resolve_resume_summon(
    ledger: &LedgerState,
    customer: &str,
    destination: &str,
) -> Result<Option<ResumeSummon>, String> {
    let customer = customer.trim();
    let destination = destination.trim();
    if customer.is_empty() || destination.is_empty() {
        return Err("resume summon requires non-empty customer and destination".to_string());
    }

    let mut candidates = ledger
        .summons
        .iter()
        .filter(|record| record.client_name.eq_ignore_ascii_case(customer))
        .filter(|record| record.destination.eq_ignore_ascii_case(destination))
        .filter(|record| {
            matches!(record.payment_status, PaymentStatus::Unpaid | PaymentStatus::Partial)
        })
        .filter(|record| {
            matches!(record.summon_status, SummonStatus::RitualStarted | SummonStatus::Summoned)
        })
        .collect::<Vec<_>>();

    if candidates.is_empty() {
        return Ok(None);
    }

    candidates.sort_by(|a, b| {
        (a.timestamp_created, &a.summon_id).cmp(&(b.timestamp_created, &b.summon_id))
    });
    let newest = candidates.pop().unwrap();

    if let Some(previous) = candidates.last() {
        if previous.timestamp_created == newest.timestamp_created {
            return Err(format!(
                "ambiguous resume summons customer={customer:?} destination={destination:?} timestamp={}",
                newest.timestamp_created
            ));
        }
    }

    if newest.client_guid == 0 {
        return Err(format!("resume summon has zero client guid summon_id={}", newest.summon_id));
    }

    Ok(Some(ResumeSummon {
        summon_id: newest.summon_id.clone(),
        client_guid: newest.client_guid,
        summon_status: newest.summon_status,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tele10_trade_payment::{LedgerState, SummonRecord};

    fn record(id: &str, ts: i64, customer: &str, destination: &str, status: SummonStatus) -> SummonRecord {
        SummonRecord {
            summon_id: id.to_string(),
            timestamp_created: ts,
            client_name: customer.to_string(),
            client_guid: 0xAABBCCDD,
            summoner_name: "Summoner".to_string(),
            destination: destination.to_string(),
            trigger_message: "hyjal pls".to_string(),
            expected_price_copper: 40_000,
            summon_status: status,
            payment_status: PaymentStatus::Unpaid,
            amount_paid_copper: 0,
            payment_timestamp: None,
            trade_partner: None,
            payment_event_id: None,
            settlement_id: None,
            last_update: ts,
            failure_reason: None,
            payment_session_active_until: ts + 600,
        }
    }

    #[test]
    fn reconstructs_summoned_request_for_payment_resume() {
        let mut ledger = LedgerState::default();
        ledger.summons.push(record("S1", 10, "Clienta", "hyjal", SummonStatus::Summoned));
        let found = resolve_resume_summon(&ledger, "clientA", "HYJAL").unwrap().unwrap();
        assert_eq!(found.summon_id, "S1");
        assert_eq!(found.client_guid, 0xAABBCCDD);
        assert_eq!(found.summon_status, SummonStatus::Summoned);
    }

    #[test]
    fn reconstructs_ritual_record_for_portal_wait_resume() {
        let mut ledger = LedgerState::default();
        ledger.summons.push(record("S2", 20, "Clienta", "winterspring", SummonStatus::RitualStarted));
        let found = resolve_resume_summon(&ledger, "Clienta", "winterspring").unwrap().unwrap();
        assert_eq!(found.summon_id, "S2");
        assert_eq!(found.summon_status, SummonStatus::RitualStarted);
    }

    #[test]
    fn newest_unresolved_record_wins_across_old_history() {
        let mut ledger = LedgerState::default();
        ledger.summons.push(record("old", 10, "Clienta", "hyjal", SummonStatus::Summoned));
        ledger.summons.push(record("new", 30, "Clienta", "hyjal", SummonStatus::RitualStarted));
        let found = resolve_resume_summon(&ledger, "Clienta", "hyjal").unwrap().unwrap();
        assert_eq!(found.summon_id, "new");
    }

    #[test]
    fn same_timestamp_candidates_fail_closed() {
        let mut ledger = LedgerState::default();
        ledger.summons.push(record("S1", 10, "Clienta", "hyjal", SummonStatus::Summoned));
        ledger.summons.push(record("S2", 10, "Clienta", "hyjal", SummonStatus::RitualStarted));
        let error = resolve_resume_summon(&ledger, "Clienta", "hyjal").unwrap_err();
        assert!(error.contains("ambiguous resume summons"));
    }

    #[test]
    fn paid_records_are_not_resume_candidates() {
        let mut ledger = LedgerState::default();
        let mut paid = record("paid", 10, "Clienta", "hyjal", SummonStatus::Summoned);
        paid.payment_status = PaymentStatus::Paid;
        ledger.summons.push(paid);
        assert!(resolve_resume_summon(&ledger, "Clienta", "hyjal").unwrap().is_none());
    }
}