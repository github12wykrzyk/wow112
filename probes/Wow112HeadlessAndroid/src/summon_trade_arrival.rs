//! Fail-closed decision gate for using an expected customer's trade as post-portal arrival evidence.

use crate::summon_service_core::RequestPhase;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TradeArrivalDecision {
    CompleteSummon,
    PaymentAlreadyOpen,
    NeedPartnerName,
    WrongPartner,
    NotReady,
}

pub fn decide_trade_arrival(
    active_customer: &str,
    phase: RequestPhase,
    partner_name: Option<&str>,
) -> TradeArrivalDecision {
    let expected = active_customer.trim();
    if expected.is_empty() {
        return TradeArrivalDecision::NotReady;
    }

    let Some(partner) = partner_name.map(str::trim).filter(|value| !value.is_empty()) else {
        return TradeArrivalDecision::NeedPartnerName;
    };

    if !partner.eq_ignore_ascii_case(expected) {
        return TradeArrivalDecision::WrongPartner;
    }

    match phase {
        RequestPhase::PortalCommitted => TradeArrivalDecision::CompleteSummon,
        RequestPhase::AwaitingPayment => TradeArrivalDecision::PaymentAlreadyOpen,
        _ => TradeArrivalDecision::NotReady,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expected_customer_trade_after_portal_is_arrival_evidence() {
        assert_eq!(
            decide_trade_arrival("Clienta", RequestPhase::PortalCommitted, Some("clientA")),
            TradeArrivalDecision::CompleteSummon
        );
    }

    #[test]
    fn expected_customer_can_trade_when_payment_window_is_already_open() {
        assert_eq!(
            decide_trade_arrival("Clienta", RequestPhase::AwaitingPayment, Some("Clienta")),
            TradeArrivalDecision::PaymentAlreadyOpen
        );
    }

    #[test]
    fn wrong_partner_never_completes_summon() {
        assert_eq!(
            decide_trade_arrival("Clienta", RequestPhase::PortalCommitted, Some("Intruder")),
            TradeArrivalDecision::WrongPartner
        );
    }

    #[test]
    fn unresolved_partner_name_is_fail_closed() {
        assert_eq!(
            decide_trade_arrival("Clienta", RequestPhase::PortalCommitted, None),
            TradeArrivalDecision::NeedPartnerName
        );
    }

    #[test]
    fn trade_before_portal_proof_is_not_arrival_evidence() {
        for phase in [
            RequestPhase::Queued,
            RequestPhase::Inviting,
            RequestPhase::RitualCommitted,
            RequestPhase::Completed,
            RequestPhase::Failed,
            RequestPhase::BlockedUncertain,
        ] {
            assert_eq!(
                decide_trade_arrival("Clienta", phase, Some("Clienta")),
                TradeArrivalDecision::NotReady
            );
        }
    }
}