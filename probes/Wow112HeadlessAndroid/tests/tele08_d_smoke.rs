use wow112_headless_android_probe::destination_registry::{
    Availability, DestinationObservation, DestinationRegistry, ManualOverride, ShardPolicy,
    TeamHealth,
};

const SEED: &str = include_str!("../config/tele08_destinations.example.json");

fn healthy(shards: Option<u32>) -> DestinationObservation {
    DestinationObservation {
        shard_count: shards,
        manual_override: ManualOverride::Automatic,
        team_health: TeamHealth::Healthy,
    }
}

#[test]
fn tele08_d_public_api_smoke() {
    let mut registry = DestinationRegistry::from_json(SEED).expect("seed config must load");

    assert_eq!(registry.config().destinations.len(), 3);

    let azshara = registry
        .resolve_destination("HYDRAXIAN WATERLORDS")
        .expect("Hydraxian alias must resolve");
    let hyjal = registry
        .resolve_destination("Mount Hyjal")
        .expect("Hyjal alias must resolve");
    let winterspring = registry
        .resolve_destination("Everlook")
        .expect("Winterspring alias must resolve");

    assert_eq!(azshara.as_str(), "azshara");
    assert_eq!(hyjal.as_str(), "hyjal");
    assert_eq!(winterspring.as_str(), "winterspring");
    assert!(registry.resolve_destination("Feralas").is_none());
    assert_eq!(registry.resource_key(&azshara), Some("summon/azshara"));

    for id in [&azshara, &hyjal, &winterspring] {
        assert_eq!(
            registry.status(id).expect("seed status exists").availability,
            Availability::Unknown,
            "default observations must fail closed"
        );
        registry
            .set_observation(id, healthy(None))
            .expect("healthy observation must apply");
        assert_eq!(
            registry.status(id).expect("healthy status exists").availability,
            Availability::Enabled
        );
    }

    let manual_event = registry
        .set_observation(
            &hyjal,
            DestinationObservation {
                shard_count: None,
                manual_override: ManualOverride::ForceOff,
                team_health: TeamHealth::Healthy,
            },
        )
        .expect("manual off must apply")
        .expect("manual off must emit state change");
    assert_eq!(manual_event.old, Availability::Enabled);
    assert_eq!(manual_event.new, Availability::DisabledManual);

    let alternatives = registry
        .alternatives_for(&hyjal, 10)
        .into_iter()
        .map(|id| id.as_str().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(alternatives, vec!["azshara", "winterspring"]);

    let recovery = registry
        .set_observation(&hyjal, healthy(None))
        .expect("manual recovery must apply")
        .expect("manual recovery must emit state change");
    assert_eq!(recovery.old, Availability::DisabledManual);
    assert_eq!(recovery.new, Availability::Enabled);

    let mut config = registry.config().clone();
    config
        .destinations
        .iter_mut()
        .find(|destination| destination.id.as_str() == "winterspring")
        .expect("winterspring definition exists")
        .shard_policy = Some(ShardPolicy {
        disable_below: 5,
        reenable_at: 8,
        allow_unknown: false,
    });
    registry
        .reload_config(config)
        .expect("valid shard policy reload must succeed");

    assert_eq!(
        registry
            .status(&winterspring)
            .expect("winterspring status exists")
            .availability,
        Availability::Unknown,
        "unknown shard count must fail closed after enabling shard policy"
    );

    registry
        .set_observation(&winterspring, healthy(Some(4)))
        .expect("low shard observation applies");
    assert_eq!(
        registry
            .status(&winterspring)
            .expect("low shard status exists")
            .availability,
        Availability::DisabledLowShards
    );

    registry
        .set_observation(&winterspring, healthy(Some(6)))
        .expect("hysteresis observation applies");
    assert_eq!(
        registry
            .status(&winterspring)
            .expect("hysteresis status exists")
            .availability,
        Availability::DisabledLowShards,
        "must remain disabled until reenable_at is reached"
    );

    registry
        .set_observation(&winterspring, healthy(Some(8)))
        .expect("recovery shard observation applies");
    assert_eq!(
        registry
            .status(&winterspring)
            .expect("recovered status exists")
            .availability,
        Availability::Enabled
    );

    let before_invalid_reload = registry.destination_status_snapshot();
    assert!(registry.reload_json("{ definitely-not-json }").is_err());
    assert_eq!(
        registry.destination_status_snapshot(),
        before_invalid_reload,
        "invalid reload must preserve last valid state"
    );

    println!("TELE08_D_SMOKE_PASS destinations=3 aliases=PASS manual_off=PASS alternatives=PASS shard_hysteresis=PASS atomic_reload=PASS");
}
