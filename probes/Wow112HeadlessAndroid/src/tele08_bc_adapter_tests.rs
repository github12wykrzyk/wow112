use crate::tele08_bc_adapter::{classification_to_request, AdmissionRejection};
use crate::tele08_whisper_parser::{
    classify_whisper, ParserConfig, WhisperIntent, WhisperObservation,
};
use tele08_request_queue::{QueueConfig, QueueEngine, ResourceKey};

fn classify(sender: &str, text: &str, at: u64, context: Option<&str>) -> crate::tele08_whisper_parser::WhisperClassification {
    classify_whisper(
        &WhisperObservation {
            sender: sender.into(),
            text: text.into(),
            timestamp_ms: at,
            source_role: Some("summoner".into()),
            destination_context: context.map(str::to_owned),
        },
        &ParserConfig::default(),
    )
}

#[test]
fn queues_explicit_plus_with_destination() {
    let c = classify("Alice", "+ hyjal", 1_000, None);
    assert_eq!(c.intent, WhisperIntent::GenericPositive);
    let r = classification_to_request(&c).expect("queueable classification");
    assert_eq!(r.player, "Alice");
    assert_eq!(r.destination, "hyjal");
    assert_eq!(r.received_at, 1_000);
    assert_eq!(r.metadata.get("parser_intent").map(String::as_str), Some("GenericPositive"));
}

#[test]
fn queues_invite_with_destination_context() {
    let c = classify("Bob", "inv pls", 2_000, Some("winterspring"));
    assert_eq!(c.intent, WhisperIntent::InviteRequest);
    let r = classification_to_request(&c).expect("context resolves destination");
    assert_eq!(r.destination, "winterspring");
}

#[test]
fn queues_summon_request_with_destination_context() {
    let c = classify("Carol", "I need one", 3_000, Some("azshara"));
    assert_eq!(c.intent, WhisperIntent::SummonRequest);
    let r = classification_to_request(&c).expect("context resolves destination");
    assert_eq!(r.destination, "azshara");
}

#[test]
fn rejects_actionable_intent_without_destination_fail_closed() {
    let c = classify("Dave", "summon me", 4_000, None);
    assert_eq!(c.intent, WhisperIntent::SummonRequest);
    assert_eq!(
        classification_to_request(&c),
        Err(AdmissionRejection::MissingDestination)
    );
}

#[test]
fn does_not_queue_queries_competition_unknown_or_presence() {
    let cases = [
        ("do you have feralas?", None, WhisperIntent::DestinationQuery),
        ("selling summons hyjal", None, WhisperIntent::CompetitionMessage),
        ("summ maybe", Some("hyjal"), WhisperIntent::Unknown),
        ("here", Some("hyjal"), WhisperIntent::PresenceReady),
    ];

    for (text, context, expected_intent) in cases {
        let c = classify("Eve", text, 5_000, context);
        assert_eq!(c.intent, expected_intent, "text={text}");
        assert!(matches!(
            classification_to_request(&c),
            Err(AdmissionRejection::NonQueueableIntent(_))
        ));
    }
}

#[test]
fn request_instance_id_changes_with_timestamp_but_fingerprint_stays_stable() {
    let a = classify("Frank", "+ hyjal", 10_000, None);
    let b = classify("Frank", "+ hyjal", 99_000, None);
    let ra = classification_to_request(&a).unwrap();
    let rb = classification_to_request(&b).unwrap();

    assert_ne!(ra.request_id, rb.request_id);
    assert_eq!(
        ra.metadata.get("parser_fingerprint"),
        rb.metadata.get("parser_fingerprint")
    );
}

#[test]
fn end_to_end_bc_dedups_same_player_destination_inside_window() {
    let resource = ResourceKey::from("team-a");
    let mut config = QueueConfig::new(10_000, 60_000);
    config.map_destination_resource("hyjal", resource);
    let mut queue = QueueEngine::new(config);

    let first = classification_to_request(&classify("Grace", "+ hyjal", 100_000, None)).unwrap();
    let second = classification_to_request(&classify(
        "Grace",
        "summon me",
        105_000,
        Some("hyjal"),
    ))
    .unwrap();

    let first_outcome = queue.enqueue(first);
    let second_outcome = queue.enqueue(second);

    assert!(first_outcome.accepted);
    assert!(!second_outcome.accepted);
    assert!(second_outcome.duplicate_of.is_some());
    assert_eq!(queue.queued_count_by_destination("hyjal"), 1);
    queue.validate_invariants().unwrap();
}

#[test]
fn end_to_end_bc_allows_new_request_after_dedup_window() {
    let resource = ResourceKey::from("team-a");
    let mut config = QueueConfig::new(10_000, 120_000);
    config.map_destination_resource("hyjal", resource);
    let mut queue = QueueEngine::new(config);

    let first = classification_to_request(&classify("Heidi", "+ hyjal", 100_000, None)).unwrap();
    let later = classification_to_request(&classify("Heidi", "+ hyjal", 120_001, None)).unwrap();

    assert!(queue.enqueue(first).accepted);
    assert!(queue.enqueue(later).accepted);
    assert_eq!(queue.queued_count_by_destination("hyjal"), 2);
    queue.validate_invariants().unwrap();
}
