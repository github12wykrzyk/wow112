#[path = "../src/tele_conversation.rs"]
mod tele_conversation;
#[path = "../src/tele_conversation_store.rs"]
mod tele_conversation_store;
#[path = "../src/tele_unknown_report.rs"]
mod tele_unknown_report;

use tele_conversation::{
    classify_whisper, ConversationContext, ConversationPhase, Destination, Intent, SuggestedAction,
};
use tele_conversation_store::ConversationStore;
use tele_unknown_report::UnknownWhisperRecord;

fn ctx(destination: Destination, phase: ConversationPhase) -> ConversationContext {
    ConversationContext {
        destination: Some(destination),
        phase,
    }
}

#[test]
fn corpus_smoke_requests() {
    let cases = [
        ("inv hyjal pls", Destination::Hyjal),
        ("need summon winterspring", Destination::Winterspring),
        ("wtb summon azshara", Destination::Hydraxian),
        ("hydraxian waterlords please", Destination::Hydraxian),
    ];
    for (raw, expected) in cases {
        let got = classify_whisper(raw, ConversationContext::default());
        assert_eq!(got.destination, Some(expected), "{raw}");
        assert_eq!(got.action, SuggestedAction::Invite, "{raw}");
    }
}

#[test]
fn short_codes_never_mutate_without_context() {
    for raw in ["+", "+ anything", "123", "here", "go", "ready"] {
        let got = classify_whisper(raw, ConversationContext::default());
        assert_eq!(got.action, SuggestedAction::LogUnknown, "{raw}");
    }
}

#[test]
fn short_codes_become_ready_in_active_conversation() {
    for raw in ["+", "+ anything", "123", "here", "go", "ready"] {
        let got = classify_whisper(raw, ctx(Destination::Hyjal, ConversationPhase::Grouped));
        assert_eq!(got.intent, Intent::ReadySignal, "{raw}");
        assert_eq!(got.action, SuggestedAction::MarkReady, "{raw}");
    }
}

#[test]
fn ambiguous_invite_without_destination_asks_destination() {
    for raw in ["inv", "invite me", "invi", "i need one", "one pls"] {
        let got = classify_whisper(raw, ConversationContext::default());
        assert_eq!(got.action, SuggestedAction::AskDestination, "{raw}");
    }
}

#[test]
fn seller_language_does_not_enter_buyer_flow() {
    for raw in [
        "wts summon hyjal 4g pst",
        "summoning service winterspring 4g whisper me",
        "portal service azshara 3g available",
    ] {
        let got = classify_whisper(raw, ConversationContext::default());
        assert_eq!(got.intent, Intent::CompetitorOffer, "{raw}");
        assert_eq!(got.action, SuggestedAction::RecordCompetitor, "{raw}");
    }
}

#[test]
fn manual_lock_prevents_policy_action_without_losing_context() {
    let mut store = ConversationStore::new(300, 60).unwrap();
    let entry = store
        .touch_destination("Somebody", Destination::Hyjal, 100)
        .unwrap();
    let seq = entry.request_seq;
    store.manual_lock("Somebody", 110).unwrap();
    assert!(!store.automation_allowed("somebody", 120));
    assert_eq!(store.get("SOMEBODY", 120).unwrap().request_seq, seq);
    assert!(store.automation_allowed("Somebody", 170));
}

#[test]
fn unknown_record_is_one_line_and_keeps_policy_reason() {
    let record = UnknownWhisperRecord {
        timestamp_s: 123,
        character: "Feltaxi".to_string(),
        sender: "Somebody".to_string(),
        raw: "+ whatever\nsecond line".to_string(),
        normalized: "whatever second line".to_string(),
        conversation_state: "New".to_string(),
        classification: "Unknown".to_string(),
        confidence: 35,
        reason: "ambiguous ready token without conversation context".to_string(),
        destination: None,
        action_taken: "LogUnknown".to_string(),
    };
    let line = record.to_json_line();
    assert_eq!(line.lines().count(), 1);
    assert!(line.contains("ambiguous ready token without conversation context"));
    assert!(line.contains("\\nsecond line"));
}
