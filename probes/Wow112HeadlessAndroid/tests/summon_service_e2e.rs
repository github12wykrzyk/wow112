use std::cell::Cell;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use wow112_headless_android_probe::summon_portal_worker::PortalWorker;
use wow112_headless_android_probe::summon_service_control::{
    apply_control, ControlInbox, ServiceControlCommand,
};
use wow112_headless_android_probe::summon_service_core::{RequestPhase, ServiceState};
use wow112_headless_android_probe::summon_service_runtime::{
    ServiceRuntimeConfig, SummonServiceRuntime,
};

fn root(tag: &str) -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "wow112_summon_e2e_{}_{}_{}",
        std::process::id(), stamp, tag
    ))
}

fn queue(runtime: &mut SummonServiceRuntime, who: &str, dest: &str, at: u64) -> String {
    runtime
        .on_whisper(who, &format!("{dest} pls"), None, Some("integration-test"), at)
        .unwrap()
        .unwrap()
}

fn consume_control(root: &Path, runtime: &mut SummonServiceRuntime) {
    let inbox = ControlInbox::open(root).unwrap();
    let pending = inbox.next().unwrap().expect("control command");
    apply_control(runtime, &pending.command).unwrap();
    inbox.ack(pending).unwrap();
}

fn summon_with_portal(
    root: &Path,
    runtime: &mut SummonServiceRuntime,
    request_id: &str,
    portal_guid: u64,
    now: u64,
) {
    runtime
        .mark_ritual_committed(request_id, &format!("ritual-{request_id}"))
        .unwrap();
    let worker = PortalWorker::open(root).unwrap();
    let sends = Cell::new(0u32);
    worker
        .execute_portal_use_once(portal_guid, now, |_| {
            sends.set(sends.get() + 1);
            Ok(())
        })
        .unwrap()
        .expect("portal claim");
    assert_eq!(sends.get(), 1);
    consume_control(root, runtime);
    assert_eq!(
        runtime.request(request_id).unwrap().phase,
        RequestPhase::PortalCommitted
    );
    ControlInbox::submit(
        root,
        &ServiceControlCommand::SummonCompleted {
            request_id: request_id.to_string(),
            now_ms: now + 1,
        },
    )
    .unwrap();
    consume_control(root, runtime);
    assert_eq!(
        runtime.request(request_id).unwrap().phase,
        RequestPhase::AwaitingPayment
    );
}

#[test]
fn abc_runs_in_one_process_with_portal_proof_and_mixed_payment_outcomes() {
    let root = root("abc");
    let config = ServiceRuntimeConfig::new(&root, "e2e-abc");
    let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();

    let a = queue(&mut runtime, "ClientA", "hyjal", 10);
    let b = queue(&mut runtime, "ClientB", "azshara", 11);
    let c = queue(&mut runtime, "ClientC", "winterspring", 12);

    assert_eq!(runtime.start_next(20).unwrap(), Some(a.clone()));
    summon_with_portal(&root, &mut runtime, &a, 0xAAA, 30);
    runtime
        .mark_payment_received(&a, 40_000, "settlement-a", 32)
        .unwrap();
    assert_eq!(runtime.request(&a).unwrap().phase, RequestPhase::Completed);

    assert_eq!(runtime.start_next(40).unwrap(), Some(b.clone()));
    summon_with_portal(&root, &mut runtime, &b, 0xBBB, 50);
    runtime
        .mark_payment_missing(&b, "payment_grace_elapsed", 52)
        .unwrap();
    assert_eq!(runtime.request(&b).unwrap().phase, RequestPhase::Completed);
    assert_eq!(runtime.request(&b).unwrap().payment_received_copper, 0);

    assert_eq!(runtime.start_next(60).unwrap(), Some(c.clone()));
    summon_with_portal(&root, &mut runtime, &c, 0xCCC, 70);
    runtime
        .mark_payment_received(&c, 50_000, "settlement-c-overpay", 72)
        .unwrap();

    assert!(runtime.active_request_id().is_none());
    assert_eq!(runtime.request(&a).unwrap().payment_received_copper, 40_000);
    assert_eq!(runtime.request(&c).unwrap().payment_received_copper, 50_000);
    assert_ne!(runtime.core().state(), ServiceState::BlockedUncertain);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn portal_transport_uncertainty_survives_worker_restart_and_never_replays() {
    let root = root("portal-uncertain");
    let config = ServiceRuntimeConfig::new(&root, "e2e-uncertain");
    let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
    let id = queue(&mut runtime, "ClientA", "hyjal", 10);
    runtime.start_next(20).unwrap();
    runtime.mark_ritual_committed(&id, "ritual-a").unwrap();

    let worker = PortalWorker::open(&root).unwrap();
    let sends = Cell::new(0u32);
    let error = worker
        .execute_portal_use_once(0xDEAD, 30, |_| {
            sends.set(sends.get() + 1);
            Err("ambiguous socket result".to_string())
        })
        .unwrap_err();
    assert!(error.contains("retry_allowed=false"));
    assert_eq!(sends.get(), 1);
    drop(worker);

    let restored = PortalWorker::open(&root).unwrap();
    let replay = restored.execute_portal_use_once(0xDEAD, 40, |_| {
        panic!("uncertain portal write must never be replayed")
    });
    assert!(replay.unwrap_err().contains("blocked by unresolved mutation"));
    assert_eq!(
        runtime.request(&id).unwrap().phase,
        RequestPhase::RitualCommitted
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn restart_after_confirmed_summon_resumes_payment_only() {
    let root = root("payment-resume");
    let config = ServiceRuntimeConfig::new(&root, "e2e-resume");
    let mut runtime = SummonServiceRuntime::open(config.clone(), 1).unwrap();
    let id = queue(&mut runtime, "ClientA", "hyjal", 10);
    runtime.start_next(20).unwrap();
    summon_with_portal(&root, &mut runtime, &id, 0xA11, 30);
    drop(runtime);

    let mut restored = SummonServiceRuntime::open(config, 100).unwrap();
    assert_eq!(restored.active_request_id(), Some(id.as_str()));
    assert_eq!(
        restored.request(&id).unwrap().phase,
        RequestPhase::AwaitingPayment
    );
    restored
        .mark_payment_received(&id, 40_000, "settlement-after-restart", 101)
        .unwrap();
    assert_eq!(restored.request(&id).unwrap().phase, RequestPhase::Completed);
    let _ = fs::remove_dir_all(root);
}
