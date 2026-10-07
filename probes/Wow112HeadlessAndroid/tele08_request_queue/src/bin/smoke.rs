use tele08_request_queue::{
    CancelSelector, FailureDisposition, LifecycleState, QueueConfig, QueueEngine, QueueError,
    ResourceKey, SummonRequest,
};

fn req(id: &str, player: &str, destination: &str, at: u64) -> SummonRequest {
    SummonRequest::new(id, player, destination, at)
}

fn main() {
    let team_a = ResourceKey::from("team-a");
    let team_b = ResourceKey::from("team-b");

    let mut config = QueueConfig::new(10, 30);
    config
        .map_destination_resource("Hyjal", team_a.clone())
        .map_destination_resource("Azshara", team_a.clone())
        .map_destination_resource("Winterspring", team_b.clone());

    let mut q = QueueEngine::new(config);

    // 1) FIFO + duplicate suppression without changing original identity/position.
    assert!(q.enqueue(req("h1", "alice", "Hyjal", 1)).accepted);
    assert!(q.enqueue(req("h2", "bob", "Hyjal", 2)).accepted);
    assert!(q.enqueue(req("h3", "carol", "Hyjal", 3)).accepted);
    let dup = q.enqueue(req("h1-dup", "alice", "Hyjal", 4));
    assert!(!dup.accepted);
    assert_eq!(dup.duplicate_of.as_deref(), Some("h1"));
    assert_eq!(q.queued_count_by_destination("Hyjal"), 3);
    assert_eq!(q.position("h1"), Some(1));
    assert_eq!(q.position("h2"), Some(2));
    assert_eq!(q.position("h3"), Some(3));
    println!("SMOKE fifo_dedup PASS");

    // 2) Independent destination/resource can run concurrently; shared resource cannot.
    assert!(q.enqueue(req("w1", "dave", "Winterspring", 4)).accepted);
    q.activate_next(&team_a, 5).expect("team-a should activate h1");
    assert_eq!(q.active_job_by_resource(&team_a).unwrap().request_id, "h1");
    assert!(matches!(
        q.activate_next(&team_a, 5),
        Err(QueueError::ResourceBusy(ref key)) if key == &team_a
    ));
    q.activate_next(&team_b, 5).expect("team-b should activate w1");
    assert_eq!(q.active_job_by_resource(&team_b).unwrap().request_id, "w1");
    println!("SMOKE resource_lock_concurrency PASS");

    // 3) Safe retry must release the resource, preserve request identity, and requeue at front.
    let first_h1_job = q.active_job_by_resource(&team_a).unwrap().job_id.clone();
    q.fail(&first_h1_job, FailureDisposition::RetryableSafe, 6)
        .expect("safe retry should succeed");
    assert!(q.active_job_by_resource(&team_a).is_none());
    assert_eq!(q.position("h1"), Some(1));
    assert_eq!(q.request("h1").unwrap().state, LifecycleState::Queued);
    assert_eq!(q.next_eligible_request(&team_a).unwrap().request.request_id, "h1");

    q.activate_next(&team_a, 7).expect("h1 retry should reactivate");
    let second_h1_job = q.active_job_by_resource(&team_a).unwrap().clone();
    assert_eq!(second_h1_job.request_id, "h1");
    assert_eq!(second_h1_job.attempt, 2);
    assert_ne!(second_h1_job.job_id, first_h1_job);
    q.complete(&second_h1_job.job_id, 8)
        .expect("retried h1 should complete");
    assert_eq!(q.request("h1").unwrap().state, LifecycleState::Completed);

    let w1_job = q.active_job_by_resource(&team_b).unwrap().job_id.clone();
    q.complete(&w1_job, 8).expect("w1 should complete");
    assert_eq!(q.request("w1").unwrap().state, LifecycleState::Completed);
    println!("SMOKE safe_retry_complete PASS");

    // 4) Cancellation repairs queue positions deterministically.
    q.cancel(CancelSelector::RequestId("h2".to_owned()), 9)
        .expect("h2 cancel should succeed");
    assert_eq!(q.request("h2").unwrap().state, LifecycleState::Cancelled);
    assert_eq!(q.position("h3"), Some(1));
    println!("SMOKE cancellation_position_repair PASS");

    // 5) Shared resource chooses the globally oldest eligible destination head.
    assert!(q.enqueue(req("az1", "erin", "Azshara", 10)).accepted);
    q.activate_next(&team_a, 11)
        .expect("shared team-a should select the older h3 before az1");
    assert_eq!(q.active_job_by_resource(&team_a).unwrap().request_id, "h3");
    assert_eq!(q.position("az1"), Some(1));
    println!("SMOKE deterministic_shared_resource_selection PASS");

    // 6) Crash restore must fail closed: active h3 becomes blocked and is never replayed.
    let snapshot = q.snapshot();
    let (mut restored, restore_events) = QueueEngine::restore(snapshot, 12)
        .expect("valid snapshot should restore");
    assert!(restored.active_job_by_resource(&team_a).is_none());
    assert_eq!(
        restored.request("h3").unwrap().state,
        LifecycleState::BlockedReconciliation
    );
    assert_eq!(restored.position("h3"), None);
    assert_eq!(restored.position("az1"), Some(1));
    assert!(!restore_events.is_empty());
    restored.validate_invariants().expect("restored invariants");
    println!("SMOKE crash_restore_fail_closed PASS");

    // 7) Expiry affects only queued work, and unknown destinations are rejected fail-closed.
    let expired = restored.expire(40);
    assert!(!expired.events.is_empty());
    assert_eq!(restored.request("az1").unwrap().state, LifecycleState::Expired);
    assert_eq!(restored.position("az1"), None);

    let unknown = restored.enqueue(req("u1", "frank", "Feralas", 41));
    assert!(!unknown.accepted);
    assert!(restored.request("u1").is_none());
    restored.validate_invariants().expect("final invariants");
    println!("SMOKE expiry_unknown_destination PASS");

    println!("SMOKE_PASS scenarios=7 invariants=OK");
}
