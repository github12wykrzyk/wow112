use tele08_request_queue::{
    CancelSelector, FailureDisposition, LifecycleState, QueueConfig, QueueEngine, QueueError,
    QueueEvent, ResourceKey, SummonRequest,
};

fn config() -> QueueConfig {
    let mut config = QueueConfig::new(100, 1_000);
    config
        .map_destination_resource("Hyjal", ResourceKey::from("team-a"))
        .map_destination_resource("Winterspring", ResourceKey::from("team-b"))
        .map_destination_resource("Azshara", ResourceKey::from("team-a"));
    config
}

fn req(id: &str, player: &str, destination: &str, at: u64) -> SummonRequest {
    SummonRequest::new(id, player, destination, at)
}

fn activate(engine: &mut QueueEngine, resource: &str, now: u64) -> String {
    let out = engine
        .activate_next(&ResourceKey::from(resource), now)
        .expect("activation succeeds");
    out.events
        .iter()
        .find_map(|event| match event {
            QueueEvent::JobActivated { job } => Some(job.job_id.clone()),
            _ => None,
        })
        .expect("activation event has job")
}

#[test]
fn fifo_one_two_three() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    engine.enqueue(req("2", "p2", "Hyjal", 2));
    engine.enqueue(req("3", "p3", "Hyjal", 3));
    assert_eq!(engine.position("1"), Some(1));
    assert_eq!(engine.position("2"), Some(2));
    assert_eq!(engine.position("3"), Some(3));

    let j1 = activate(&mut engine, "team-a", 10);
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::Active);
    engine.complete(&j1, 11).unwrap();
    let j2 = activate(&mut engine, "team-a", 12);
    assert_eq!(engine.request("2").unwrap().state, LifecycleState::Active);
    engine.complete(&j2, 13).unwrap();
    let _j3 = activate(&mut engine, "team-a", 14);
    assert_eq!(engine.request("3").unwrap().state, LifecycleState::Active);
    engine.validate_invariants().unwrap();
}

#[test]
fn two_independent_destinations_can_be_active() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("h", "p1", "Hyjal", 1));
    engine.enqueue(req("w", "p2", "Winterspring", 2));
    let _jh = activate(&mut engine, "team-a", 10);
    let _jw = activate(&mut engine, "team-b", 10);
    assert!(engine.active_job_by_resource(&ResourceKey::from("team-a")).is_some());
    assert!(engine.active_job_by_resource(&ResourceKey::from("team-b")).is_some());
    engine.validate_invariants().unwrap();
}

#[test]
fn duplicate_same_player_destination_preserves_original_identity() {
    let mut engine = QueueEngine::new(config());
    assert!(engine.enqueue(req("original", "Same", "Hyjal", 10)).accepted);
    let duplicate = engine.enqueue(req("new-id", "Same", "Hyjal", 50));
    assert!(!duplicate.accepted);
    assert_eq!(duplicate.duplicate_of.as_deref(), Some("original"));
    assert_eq!(duplicate.effective_request_id.as_deref(), Some("original"));
    assert_eq!(engine.queued_count_by_destination("Hyjal"), 1);
    assert!(engine.request("new-id").is_none());
    assert_eq!(engine.request("original").unwrap().last_seen_at, 50);
}

#[test]
fn same_player_different_destination_is_not_duplicate() {
    let mut engine = QueueEngine::new(config());
    assert!(engine.enqueue(req("h", "Same", "Hyjal", 10)).accepted);
    assert!(engine.enqueue(req("w", "Same", "Winterspring", 11)).accepted);
}

#[test]
fn repeated_request_refreshes_expiry_without_changing_position() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 10));
    engine.enqueue(req("2", "p2", "Hyjal", 11));
    let duplicate = engine.enqueue(req("refresh", "p1", "Hyjal", 90));
    assert_eq!(duplicate.duplicate_of.as_deref(), Some("1"));
    assert_eq!(engine.position("1"), Some(1));
    assert_eq!(engine.position("2"), Some(2));
    engine.expire(1_050);
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::Queued);
    assert_eq!(engine.request("2").unwrap().state, LifecycleState::Expired);
    assert_eq!(engine.position("1"), Some(1));
}

#[test]
fn cancellation_first_middle_last_repairs_positions() {
    for target in ["1", "2", "3"] {
        let mut engine = QueueEngine::new(config());
        engine.enqueue(req("1", "p1", "Hyjal", 1));
        engine.enqueue(req("2", "p2", "Hyjal", 2));
        engine.enqueue(req("3", "p3", "Hyjal", 3));
        engine.cancel(CancelSelector::RequestId(target.to_owned()), 20).unwrap();
        assert_eq!(engine.request(target).unwrap().state, LifecycleState::Cancelled);
        let positions: Vec<_> = ["1", "2", "3"]
            .into_iter()
            .filter(|id| *id != target)
            .map(|id| engine.position(id).unwrap())
            .collect();
        assert_eq!(positions, vec![1, 2]);
        engine.validate_invariants().unwrap();
    }
}

#[test]
fn cancellation_by_player_and_destination_is_deterministic() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    let out = engine
        .cancel(
            CancelSelector::PlayerDestination {
                player: "p1".to_owned(),
                destination: "Hyjal".to_owned(),
            },
            2,
        )
        .unwrap();
    assert_eq!(out.affected_request_id.as_deref(), Some("1"));
}

#[test]
fn expiry_is_configurable_and_deterministic() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 10));
    engine.enqueue(req("2", "p2", "Hyjal", 20));
    engine.expire(1_015);
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::Expired);
    assert_eq!(engine.request("2").unwrap().state, LifecycleState::Queued);
    assert_eq!(engine.position("2"), Some(1));
}

#[test]
fn safe_retry_requeues_at_front_without_auto_activation() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    engine.enqueue(req("2", "p2", "Hyjal", 2));
    let job = activate(&mut engine, "team-a", 10);
    engine.fail(&job, FailureDisposition::RetryableSafe, 11).unwrap();
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::Queued);
    assert_eq!(engine.position("1"), Some(1));
    assert_eq!(engine.position("2"), Some(2));
    assert!(engine.active_job_by_resource(&ResourceKey::from("team-a")).is_none());
    engine.validate_invariants().unwrap();
}

#[test]
fn terminal_failure_releases_resource_and_never_requeues() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    let job = activate(&mut engine, "team-a", 10);
    engine.fail(&job, FailureDisposition::Terminal, 11).unwrap();
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::Failed);
    assert!(matches!(
        engine.activate_next(&ResourceKey::from("team-a"), 12),
        Err(QueueError::NoEligibleRequest(_))
    ));
}

#[test]
fn uncertain_failure_never_replays() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    let job = activate(&mut engine, "team-a", 10);
    let out = engine.fail(&job, FailureDisposition::UncertainDoNotReplay, 11).unwrap();
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::BlockedReconciliation);
    assert!(out.events.iter().any(|event| matches!(
        event,
        QueueEvent::JobBlockedUncertain { request_id, .. } if request_id == "1"
    )));
    assert!(matches!(
        engine.activate_next(&ResourceKey::from("team-a"), 12),
        Err(QueueError::NoEligibleRequest(_))
    ));
}

#[test]
fn crash_restore_keeps_queued_requests() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    engine.enqueue(req("2", "p2", "Hyjal", 2));
    let (restored, events) = QueueEngine::restore(engine.snapshot(), 100).unwrap();
    assert!(events.is_empty());
    assert_eq!(restored.position("1"), Some(1));
    assert_eq!(restored.position("2"), Some(2));
    restored.validate_invariants().unwrap();
}

#[test]
fn crash_restore_active_is_fail_closed_and_not_replayed() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    let _job = activate(&mut engine, "team-a", 10);
    let (mut restored, events) = QueueEngine::restore(engine.snapshot(), 100).unwrap();
    assert_eq!(restored.request("1").unwrap().state, LifecycleState::BlockedReconciliation);
    assert!(restored.active_job_by_resource(&ResourceKey::from("team-a")).is_none());
    assert!(events.iter().any(|event| matches!(
        event,
        QueueEvent::JobBlockedUncertain { request_id, .. } if request_id == "1"
    )));
    assert!(matches!(
        restored.activate_next(&ResourceKey::from("team-a"), 101),
        Err(QueueError::NoEligibleRequest(_))
    ));
}

#[test]
fn queue_queries_do_not_mutate_hidden_state() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    engine.enqueue(req("2", "p2", "Hyjal", 2));
    let audit_len = engine.audit_log().len();
    assert_eq!(engine.position("2"), Some(2));
    assert_eq!(engine.queued_count_by_destination("Hyjal"), 2);
    assert!(engine.next_eligible_request(&ResourceKey::from("team-a")).is_some());
    assert_eq!(engine.audit_log().len(), audit_len);
}

#[test]
fn resource_lock_prevents_two_active_jobs_on_shared_team() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("h", "p1", "Hyjal", 1));
    engine.enqueue(req("a", "p2", "Azshara", 2));
    let _job = activate(&mut engine, "team-a", 10);
    assert!(matches!(
        engine.activate_next(&ResourceKey::from("team-a"), 11),
        Err(QueueError::ResourceBusy(_))
    ));
    engine.validate_invariants().unwrap();
}

#[test]
fn one_destination_can_use_multiple_teams() {
    let mut cfg = config();
    cfg.map_destination_resource("Hyjal", ResourceKey::from("team-c"));
    let mut engine = QueueEngine::new(cfg);
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    engine.enqueue(req("2", "p2", "Hyjal", 2));
    let _j1 = activate(&mut engine, "team-c", 10);
    let _j2 = activate(&mut engine, "team-a", 11);
    assert_eq!(engine.request("1").unwrap().state, LifecycleState::Active);
    assert_eq!(engine.request("2").unwrap().state, LifecycleState::Active);
    engine.validate_invariants().unwrap();
}

#[test]
fn next_selection_is_deterministic_independent_of_mapping_order() {
    fn build(reverse: bool) -> QueueEngine {
        let mut cfg = QueueConfig::new(100, 1_000);
        if reverse {
            cfg.map_destination_resource("Azshara", ResourceKey::from("shared"));
            cfg.map_destination_resource("Hyjal", ResourceKey::from("shared"));
        } else {
            cfg.map_destination_resource("Hyjal", ResourceKey::from("shared"));
            cfg.map_destination_resource("Azshara", ResourceKey::from("shared"));
        }
        let mut engine = QueueEngine::new(cfg);
        engine.enqueue(req("later", "p1", "Hyjal", 20));
        engine.enqueue(req("earlier", "p2", "Azshara", 10));
        engine
    }
    for reverse in [false, true] {
        let engine = build(reverse);
        assert_eq!(
            engine.next_eligible_request(&ResourceKey::from("shared")).unwrap().request.request_id,
            "earlier"
        );
    }
}

#[test]
fn unknown_destination_is_rejected_without_state() {
    let mut engine = QueueEngine::new(config());
    let out = engine.enqueue(req("x", "p", "Feralas", 1));
    assert!(!out.accepted);
    assert!(engine.request("x").is_none());
    assert!(matches!(out.events.as_slice(), [QueueEvent::RequestRejected { .. }]));
}

#[test]
fn exact_request_id_conflict_is_rejected() {
    let mut engine = QueueEngine::new(config());
    assert!(engine.enqueue(req("same", "p1", "Hyjal", 1)).accepted);
    let conflict = engine.enqueue(req("same", "other", "Hyjal", 2));
    assert!(!conflict.accepted);
    assert_eq!(engine.request("same").unwrap().request.player, "p1");
}

#[test]
fn completed_cancelled_and_terminal_failed_never_auto_reactivate() {
    let mut completed = QueueEngine::new(config());
    completed.enqueue(req("c", "p1", "Hyjal", 1));
    let job = activate(&mut completed, "team-a", 2);
    completed.complete(&job, 3).unwrap();
    assert!(matches!(completed.activate_next(&ResourceKey::from("team-a"), 4), Err(QueueError::NoEligibleRequest(_))));

    let mut cancelled = QueueEngine::new(config());
    cancelled.enqueue(req("x", "p2", "Hyjal", 1));
    cancelled.cancel(CancelSelector::RequestId("x".to_owned()), 2).unwrap();
    assert!(matches!(cancelled.activate_next(&ResourceKey::from("team-a"), 3), Err(QueueError::NoEligibleRequest(_))));

    let mut failed = QueueEngine::new(config());
    failed.enqueue(req("f", "p3", "Hyjal", 1));
    let job = activate(&mut failed, "team-a", 2);
    failed.fail(&job, FailureDisposition::Terminal, 3).unwrap();
    assert!(matches!(failed.activate_next(&ResourceKey::from("team-a"), 4), Err(QueueError::NoEligibleRequest(_))));
}

#[test]
fn audit_records_every_state_transition() {
    let mut engine = QueueEngine::new(config());
    engine.enqueue(req("1", "p1", "Hyjal", 1));
    let job = activate(&mut engine, "team-a", 2);
    engine.complete(&job, 3).unwrap();
    let states: Vec<_> = engine.audit_log().iter().map(|entry| entry.to).collect();
    assert_eq!(states, vec![
        LifecycleState::Received,
        LifecycleState::Queued,
        LifecycleState::Active,
        LifecycleState::Completed,
    ]);
}

#[test]
fn randomized_invariant_sequence_stays_valid() {
    let mut engine = QueueEngine::new(config());
    let mut seed = 0xC0FFEE_u64;
    let mut next_id = 0_u64;
    for step in 0..2_000_u64 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        match seed % 7 {
            0 | 1 | 2 => {
                let destinations = ["Hyjal", "Winterspring", "Azshara"];
                let destination = destinations[(seed as usize >> 8) % destinations.len()];
                let player = format!("p{}", (seed >> 16) % 32);
                let id = format!("r{next_id}");
                next_id += 1;
                engine.enqueue(req(&id, &player, destination, step));
            }
            3 => {
                let resource = if seed & 1 == 0 { "team-a" } else { "team-b" };
                let _ = engine.activate_next(&ResourceKey::from(resource), step);
            }
            4 => {
                let job = ["team-a", "team-b"].into_iter().find_map(|resource| {
                    engine.active_job_by_resource(&ResourceKey::from(resource)).map(|job| job.job_id.clone())
                });
                if let Some(job) = job { let _ = engine.complete(&job, step); }
            }
            5 => {
                let job = ["team-a", "team-b"].into_iter().find_map(|resource| {
                    engine.active_job_by_resource(&ResourceKey::from(resource)).map(|job| job.job_id.clone())
                });
                if let Some(job) = job {
                    let disposition = match (seed >> 24) % 3 {
                        0 => FailureDisposition::RetryableSafe,
                        1 => FailureDisposition::Terminal,
                        _ => FailureDisposition::UncertainDoNotReplay,
                    };
                    let _ = engine.fail(&job, disposition, step);
                }
            }
            _ => { let _ = engine.expire(step.saturating_add(2_000)); }
        }
        engine.validate_invariants().unwrap();
    }
}
