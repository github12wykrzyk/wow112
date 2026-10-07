use crate::tele08_whisper_parser::WhisperObservation;
use crate::tele10_message_router::{MessageRoute, Tele10MessageRouter};

fn obs(sender: &str, text: &str, at: u64) -> WhisperObservation {
    WhisperObservation {
        sender: sender.into(),
        text: text.into(),
        timestamp_ms: at,
        source_role: Some("tele10_router_test".into()),
        destination_context: None,
    }
}

#[test]
fn normal_destination_request_stays_direct_and_queueable() {
    let mut router = Tele10MessageRouter::default();
    let route = router.handle(&obs("Alice", "winterspring pls", 1_000));
    let MessageRoute::Request(request) = route else {
        panic!("expected direct request");
    };
    assert_eq!(request.player, "Alice");
    assert_eq!(request.destination, "winterspring");
    assert_eq!(
        request
            .metadata
            .get("tele10_message_route")
            .map(String::as_str),
        Some("direct")
    );
}

#[test]
fn typo_with_destination_clarifies_then_becomes_request() {
    let mut router = Tele10MessageRouter::default();
    assert!(matches!(
        router.handle(&obs("Alice", "sumon hyjal plz", 1_000)),
        MessageRoute::Clarify { ref text, .. } if text == "Do you want a summon to Hyjal?"
    ));

    let route = router.handle(&obs("Alice", "yes", 2_000));
    let MessageRoute::Request(request) = route else {
        panic!("confirmed typo should become request");
    };
    assert_eq!(request.destination, "hyjal");
    assert_eq!(
        request
            .metadata
            .get("tele10_message_route")
            .map(String::as_str),
        Some("clarification_confirmed")
    );
    assert_eq!(router.pending_clarifications(), 0);
}

#[test]
fn typo_without_destination_requires_two_step_clarification() {
    let mut router = Tele10MessageRouter::default();
    assert!(matches!(
        router.handle(&obs("Alice", "sumon plz", 1_000)),
        MessageRoute::Clarify { ref text, .. } if text == "Do you want a summon?"
    ));
    assert!(matches!(
        router.handle(&obs("Alice", "yes", 2_000)),
        MessageRoute::Clarify { ref text, .. }
            if text == "Which location: Hyjal, Winterspring or Azshara?"
    ));

    let route = router.handle(&obs("Alice", "azshara", 3_000));
    let MessageRoute::Request(request) = route else {
        panic!("destination selection should complete request");
    };
    assert_eq!(request.destination, "azshara");
    assert_eq!(
        request.metadata.get("parser_reason").map(String::as_str),
        Some("clarification_destination_selected")
    );
}

#[test]
fn bare_confirmation_without_pending_context_is_ignored() {
    let mut router = Tele10MessageRouter::default();
    assert!(matches!(
        router.handle(&obs("Alice", "yes", 1_000)),
        MessageRoute::Ignore { .. }
    ));
    assert_eq!(router.pending_clarifications(), 0);
}

#[test]
fn obvious_seller_messages_are_suppressed_even_when_leading_plus_would_parse_positive() {
    let cases = [
        "+ wts ports",
        "+ cheap summons",
        "wts ports",
        "selling ports",
        "we sell summons",
        "i sell hyjal",
    ];
    for text in cases {
        let mut router = Tele10MessageRouter::default();
        assert!(
            matches!(
                router.handle(&obs("Seller", text, 1_000)),
                MessageRoute::Ignore { ref reason } if reason == "clarification_suppressed"
            ),
            "seller input escaped guard: {text:?}"
        );
        assert_eq!(router.pending_clarifications(), 0, "input={text:?}");
    }
}

#[test]
fn configured_competition_is_ignored_without_clarification() {
    let mut router = Tele10MessageRouter::default();
    assert!(matches!(
        router.handle(&obs("Seller", "selling summons cheaper today", 1_000)),
        MessageRoute::Ignore { ref reason } if reason == "non_queueable:CompetitionMessage"
    ));
    assert_eq!(router.pending_clarifications(), 0);
}

#[test]
fn explicit_plus_with_destination_remains_direct_request() {
    let mut router = Tele10MessageRouter::default();
    let route = router.handle(&obs("Alice", "+ hyjal", 1_000));
    let MessageRoute::Request(request) = route else {
        panic!("expected + hyjal to remain direct");
    };
    assert_eq!(request.destination, "hyjal");
    assert_eq!(
        request
            .metadata
            .get("tele10_message_route")
            .map(String::as_str),
        Some("direct")
    );
}

#[test]
fn late_yes_after_clarification_timeout_never_creates_request() {
    let mut router = Tele10MessageRouter::default();
    assert!(matches!(
        router.handle(&obs("Alice", "sumon hyjal plz", 1_000)),
        MessageRoute::Clarify { .. }
    ));
    assert!(matches!(
        router.handle(&obs("Alice", "yes", 46_001)),
        MessageRoute::Ignore { .. }
    ));
    assert_eq!(router.pending_clarifications(), 0);
}

#[test]
fn sender_states_do_not_cross_talk() {
    let mut router = Tele10MessageRouter::default();
    assert!(matches!(
        router.handle(&obs("Alice", "sumon hyjal plz", 1_000)),
        MessageRoute::Clarify { .. }
    ));
    assert!(matches!(
        router.handle(&obs("Bob", "yes", 2_000)),
        MessageRoute::Ignore { .. }
    ));
    assert!(matches!(
        router.handle(&obs("Alice", "yes", 3_000)),
        MessageRoute::Request(_)
    ));
}
