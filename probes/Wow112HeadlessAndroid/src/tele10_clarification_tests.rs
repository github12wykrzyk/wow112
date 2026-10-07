use crate::tele08_whisper_parser::{
    classify_whisper, ParserConfig, WhisperClassification, WhisperIntent, WhisperObservation,
};
use crate::tele10_clarification::{
    ClarificationConfig, ClarificationDecision, ClarificationGate,
};

fn classify_at(sender: &str, text: &str, timestamp_ms: u64) -> WhisperClassification {
    classify_whisper(
        &WhisperObservation {
            sender: sender.into(),
            text: text.into(),
            timestamp_ms,
            source_role: Some("tele10_clarification_test".into()),
            destination_context: None,
        },
        &ParserConfig::default(),
    )
}

fn default_gate() -> ClarificationGate {
    ClarificationGate::new(ClarificationConfig {
        timeout_ms: 45_000,
        reprompt_cooldown_ms: 60_000,
    })
}

#[test]
fn ambiguous_operational_message_prompts_without_becoming_action() {
    let mut gate = default_gate();
    let classification = classify_at("Customer", "sumon plz", 1_000);
    assert_eq!(classification.intent, WhisperIntent::Unknown);

    let decision = gate.process(&classification);
    assert_eq!(
        decision,
        ClarificationDecision::Prompt {
            recipient: "Customer".into(),
            text: "Do you want a summon?".into(),
            destination: None,
        }
    );
    assert_eq!(gate.pending_count(), 1);
}

#[test]
fn destination_is_preserved_in_prompt_and_confirmed_request() {
    let mut gate = default_gate();
    let classification = classify_at("Customer", "sumon hyjal plz", 1_000);
    assert_eq!(classification.intent, WhisperIntent::Unknown);
    assert_eq!(
        classification.destination.as_ref().map(|v| v.0.as_str()),
        Some("hyjal")
    );

    assert_eq!(
        gate.process(&classification),
        ClarificationDecision::Prompt {
            recipient: "Customer".into(),
            text: "Do you want a summon to Hyjal?".into(),
            destination: classification.destination.clone(),
        }
    );

    let confirmed = gate.process(&classify_at("Customer", "yes", 2_000));
    let ClarificationDecision::Confirmed(confirmed) = confirmed else {
        panic!("expected confirmed clarification");
    };
    assert_eq!(confirmed.intent, WhisperIntent::SummonRequest);
    assert_eq!(
        confirmed.destination.as_ref().map(|v| v.0.as_str()),
        Some("hyjal")
    );
    assert_eq!(confirmed.reason, "clarification_confirmed");
    assert_eq!(gate.pending_count(), 0);
}

#[test]
fn plus_confirms_only_inside_active_pending_context() {
    let mut gate = default_gate();
    let plus_without_pending = classify_at("Customer", "+", 1_000);
    assert_eq!(plus_without_pending.intent, WhisperIntent::GenericPositive);
    assert_eq!(
        gate.process(&plus_without_pending),
        ClarificationDecision::PassThrough
    );

    assert!(matches!(
        gate.process(&classify_at("Customer", "summn pls", 2_000)),
        ClarificationDecision::Prompt { .. }
    ));
    let decision = gate.process(&classify_at("Customer", "+", 3_000));
    let ClarificationDecision::Confirmed(confirmed) = decision else {
        panic!("pending '+' should confirm");
    };
    assert_eq!(confirmed.intent, WhisperIntent::SummonRequest);
}

#[test]
fn bare_yes_never_creates_request_without_pending_context() {
    let mut gate = default_gate();
    let yes = classify_at("Customer", "yes", 1_000);
    assert_ne!(yes.intent, WhisperIntent::SummonRequest);
    assert_eq!(gate.process(&yes), ClarificationDecision::PassThrough);
    assert_eq!(gate.pending_count(), 0);
}

#[test]
fn explicit_decline_closes_pending_state() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));
    assert_eq!(
        gate.process(&classify_at("Customer", "no", 2_000)),
        ClarificationDecision::Declined
    );
    assert_eq!(gate.pending_count(), 0);
    assert_eq!(
        gate.process(&classify_at("Customer", "yes", 3_000)),
        ClarificationDecision::PassThrough
    );
}

#[test]
fn late_confirmation_after_timeout_is_not_actionable() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));
    assert_eq!(
        gate.process(&classify_at("Customer", "yes", 46_001)),
        ClarificationDecision::PassThrough
    );
    assert_eq!(gate.pending_count(), 0);
}

#[test]
fn repeated_ambiguous_message_does_not_spam_prompts() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));
    assert_eq!(
        gate.process(&classify_at("Customer", "summn pls", 2_000)),
        ClarificationDecision::Suppressed
    );
    assert_eq!(gate.pending_count(), 1);
}

#[test]
fn cooldown_blocks_immediate_reprompt_after_decline_or_expiry() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));
    assert_eq!(
        gate.process(&classify_at("Customer", "no", 2_000)),
        ClarificationDecision::Declined
    );
    assert_eq!(
        gate.process(&classify_at("Customer", "sumon plz", 20_000)),
        ClarificationDecision::Suppressed
    );
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 61_001)),
        ClarificationDecision::Prompt { .. }
    ));
}

#[test]
fn irrelevant_and_competition_messages_never_open_fallback() {
    let mut gate = default_gate();
    for text in ["hello", "thanks", "need gold", "selling summons cheaper today"] {
        assert_eq!(
            gate.process(&classify_at("Customer", text, 1_000)),
            ClarificationDecision::PassThrough,
            "input={text:?}"
        );
        assert_eq!(gate.pending_count(), 0, "input={text:?}");
    }
}

#[test]
fn competitor_message_cancels_existing_pending_fallback() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));
    let competitor = classify_at("Customer", "selling summons cheaper today", 2_000);
    assert_eq!(competitor.intent, WhisperIntent::CompetitionMessage);
    assert_eq!(gate.process(&competitor), ClarificationDecision::PassThrough);
    assert_eq!(gate.pending_count(), 0);
    assert_eq!(
        gate.process(&classify_at("Customer", "yes", 3_000)),
        ClarificationDecision::PassThrough
    );
}

#[test]
fn pending_state_is_isolated_per_sender() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Alice", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));
    assert_eq!(
        gate.process(&classify_at("Bob", "yes", 2_000)),
        ClarificationDecision::PassThrough
    );
    assert!(gate.pending_for("Alice").is_some());
    assert!(gate.pending_for("Bob").is_none());

    assert!(matches!(
        gate.process(&classify_at("Alice", "yes", 3_000)),
        ClarificationDecision::Confirmed(_)
    ));
}

#[test]
fn explicit_action_replaces_pending_without_extra_prompt() {
    let mut gate = default_gate();
    assert!(matches!(
        gate.process(&classify_at("Customer", "sumon plz", 1_000)),
        ClarificationDecision::Prompt { .. }
    ));

    let explicit = classify_at("Customer", "summon please", 2_000);
    assert_eq!(explicit.intent, WhisperIntent::SummonRequest);
    assert_eq!(gate.process(&explicit), ClarificationDecision::PassThrough);
    assert_eq!(gate.pending_count(), 0);
}

#[test]
fn common_confirmation_variants_are_bounded_to_pending_state() {
    for confirmation in [
        "y",
        "yes",
        "yea",
        "yeah",
        "yep",
        "yup",
        "sure",
        "ok",
        "okay",
        "pls",
        "please",
        "yes pls",
        "yes please",
        "ofc",
    ] {
        let mut gate = default_gate();
        assert!(matches!(
            gate.process(&classify_at("Customer", "sumon plz", 1_000)),
            ClarificationDecision::Prompt { .. }
        ));
        assert!(
            matches!(
                gate.process(&classify_at("Customer", confirmation, 2_000)),
                ClarificationDecision::Confirmed(_)
            ),
            "confirmation={confirmation:?}"
        );
    }
}
