#[path = "../src/tele_conversation.rs"]
mod tele_conversation;

use tele_conversation::{
    classify_whisper, ConversationContext, ConversationPhase, Destination, Intent, SuggestedAction,
};

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
