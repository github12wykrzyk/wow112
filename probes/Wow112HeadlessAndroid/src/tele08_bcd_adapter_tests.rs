use crate::destination_registry::{
    Availability, DestinationObservation, DestinationRegistry, ManualOverride, ShardPolicy,
    TeamHealth,
};
use crate::tele08_bc_adapter::AdmissionRejection;
use crate::tele08_bcd_adapter::{
    classification_to_routed_request, parser_config_from_registry, queue_config_from_registry,
    RoutingRejection,
};
use crate::tele08_whisper_parser::{classify_whisper, WhisperIntent, WhisperObservation};
use tele08_request_queue::QueueEngine;

const SEED: &str = include_str!("../config/tele08_destinations.example.json");

fn healthy() -> DestinationObservation {
    DestinationObservation {
        shard_count: None,
        manual_override: ManualOverride::Automatic,
        team_health: TeamHealth::Healthy,
    }
}

fn classify(
    registry: &DestinationRegistry,
    sender: &str,
    text: &str,
    timestamp_ms: u64,
) -> crate::tele08_whisper_parser::WhisperClassification {
    classify_whisper(
        &WhisperObservation {
            sender: sender.into(),
            text: text.into(),
            timestamp_ms,
            source_role: Some("bcd-test".into()),
            destination_context: None,
        },
        &parser_config_from_registry(registry),
    )
}

fn enable_all(registry: &mut DestinationRegistry) {
    let ids = registry
        .config()
        .destinations
        .iter()
        .map(|d| d.id.clone())
        .collect::<Vec<_>>();
    for id in ids {
        registry.set_observation(&id, healthy()).unwrap();
    }
}

#[test]
fn parser_destination_vocabulary_is_generated_from_registry() {
    let registry = DestinationRegistry::from_json(SEED).unwrap();

    let hydraxian = classify(&registry, "Alice", "hydraxian pls", 1_000);
    assert_eq!(hydraxian.intent, WhisperIntent::SummonRequest);
    assert_eq!(
        hydraxian.destination.as_ref().map(|d| d.0.as_str()),
        Some("azshara")
    );

    let everlook = classify(&registry, "Bob", "everlook pls", 2_000);
    assert_eq!(everlook.intent, WhisperIntent::SummonRequest);
    assert_eq!(
        everlook.destination.as_ref().map(|d| d.0.as_str()),
        Some("winterspring")
    );

    let mount_hyjal = classify(&registry, "Carol", "mount hyjal pls", 3_000);
    assert_eq!(mount_hyjal.intent, WhisperIntent::SummonRequest);
    assert_eq!(
        mount_hyjal.destination.as_ref().map(|d| d.0.as_str()),
        Some("hyjal")
    );
}

#[test]
fn registry_unknown_state_blocks_queue_admission_fail_closed() {
    let registry = DestinationRegistry::from_json(SEED).unwrap();
    let classification = classify(&registry, "Alice", "+ hyjal", 10_000);

    let rejection = classification_to_routed_request(&classification, &registry).unwrap_err();
    assert!(matches!(
        rejection,
        RoutingRejection::DestinationUnavailable {
            destination,
            availability: Availability::Unknown,
            ..
        } if destination == "hyjal"
    ));
}

#[test]
fn healthy_registry_admits_and_attaches_execution_resource() {
    let mut registry = DestinationRegistry::from_json(SEED).unwrap();
    let hyjal = registry.resolve_destination("hyjal").unwrap();
    registry.set_observation(&hyjal, healthy()).unwrap();

    let classification = classify(&registry, "Alice", "+ hyjal", 20_000);
    let request = classification_to_routed_request(&classification, &registry).unwrap();

    assert_eq!(request.destination, "hyjal");
    assert_eq!(
        request.metadata.get("execution_resource").map(String::as_str),
        Some("summon/hyjal")
    );
    assert_eq!(
        request.metadata.get("destination_source").map(String::as_str),
        Some("tele08_registry")
    );
}

#[test]
fn manual_off_blocks_requested_destination_and_returns_enabled_alternatives() {
    let mut registry = DestinationRegistry::from_json(SEED).unwrap();
    enable_all(&mut registry);
    let hyjal = registry.resolve_destination("hyjal").unwrap();
    registry
        .set_observation(
            &hyjal,
            DestinationObservation {
                shard_count: None,
                manual_override: ManualOverride::ForceOff,
                team_health: TeamHealth::Healthy,
            },
        )
        .unwrap();

    let classification = classify(&registry, "Alice", "+ hyjal", 30_000);
    let rejection = classification_to_routed_request(&classification, &registry).unwrap_err();
    match rejection {
        RoutingRejection::DestinationUnavailable {
            destination,
            availability,
            alternatives,
            ..
        } => {
            assert_eq!(destination, "hyjal");
            assert_eq!(availability, Availability::DisabledManual);
            assert_eq!(alternatives, vec!["azshara", "winterspring"]);
        }
        other => panic!("unexpected rejection: {other:?}"),
    }
}

#[test]
fn low_shard_hysteresis_blocks_then_recovers_admission() {
    let mut registry = DestinationRegistry::from_json(SEED).unwrap();
    let winterspring = registry.resolve_destination("winterspring").unwrap();
    let mut config = registry.config().clone();
    config
        .destinations
        .iter_mut()
        .find(|d| d.id == winterspring)
        .unwrap()
        .shard_policy = Some(ShardPolicy {
        disable_below: 5,
        reenable_at: 8,
        allow_unknown: false,
    });
    registry.reload_config(config).unwrap();

    registry
        .set_observation(
            &winterspring,
            DestinationObservation {
                shard_count: Some(4),
                manual_override: ManualOverride::Automatic,
                team_health: TeamHealth::Healthy,
            },
        )
        .unwrap();
    let low = classify(&registry, "Alice", "winterspring pls", 40_000);
    assert!(matches!(
        classification_to_routed_request(&low, &registry),
        Err(RoutingRejection::DestinationUnavailable {
            availability: Availability::DisabledLowShards,
            ..
        })
    ));

    registry
        .set_observation(
            &winterspring,
            DestinationObservation {
                shard_count: Some(8),
                manual_override: ManualOverride::Automatic,
                team_health: TeamHealth::Healthy,
            },
        )
        .unwrap();
    let recovered = classify(&registry, "Alice", "winterspring pls", 50_000);
    assert!(classification_to_routed_request(&recovered, &registry).is_ok());
}

#[test]
fn queue_resource_map_is_owned_by_registry() {
    let registry = DestinationRegistry::from_json(SEED).unwrap();
    let config = queue_config_from_registry(&registry, 10_000, 120_000).unwrap();

    assert_eq!(config.resources_for("azshara")[0].0, "summon/azshara");
    assert_eq!(config.resources_for("hyjal")[0].0, "summon/hyjal");
    assert_eq!(
        config.resources_for("winterspring")[0].0,
        "summon/winterspring"
    );
    assert!(!config.destination_is_configured("feralas"));
}

#[test]
fn feralas_is_not_promoted_into_a_destination_request() {
    let mut registry = DestinationRegistry::from_json(SEED).unwrap();
    enable_all(&mut registry);
    let classification = classify(&registry, "Alice", "+ feralas", 60_000);
    assert!(classification.destination.is_none());
    assert_eq!(
        classification_to_routed_request(&classification, &registry),
        Err(RoutingRejection::ParserAdmission(
            AdmissionRejection::MissingDestination
        ))
    );
}

#[test]
fn end_to_end_b_d_c_enqueues_only_enabled_destinations() {
    let mut registry = DestinationRegistry::from_json(SEED).unwrap();
    enable_all(&mut registry);
    let hyjal = registry.resolve_destination("hyjal").unwrap();
    registry
        .set_observation(
            &hyjal,
            DestinationObservation {
                shard_count: None,
                manual_override: ManualOverride::ForceOff,
                team_health: TeamHealth::Healthy,
            },
        )
        .unwrap();

    let queue_config = queue_config_from_registry(&registry, 10_000, 120_000).unwrap();
    let mut queue = QueueEngine::new(queue_config);

    for (sender, text, at) in [
        ("Alice", "+ hyjal", 100_000),
        ("Bob", "winterspring pls", 120_000),
        ("Carol", "azshara please", 140_000),
    ] {
        let classification = classify(&registry, sender, text, at);
        if let Ok(request) = classification_to_routed_request(&classification, &registry) {
            assert!(queue.enqueue(request).accepted);
        }
    }

    assert_eq!(queue.queued_count_by_destination("hyjal"), 0);
    assert_eq!(queue.queued_count_by_destination("winterspring"), 1);
    assert_eq!(queue.queued_count_by_destination("azshara"), 1);
    queue.validate_invariants().unwrap();
}
