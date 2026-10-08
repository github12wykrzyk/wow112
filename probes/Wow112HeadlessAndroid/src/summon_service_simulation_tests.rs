use crate::summon_mutation_coordinator::{MutationCoordinator, MutationKind};
use crate::summon_service_core::RequestPhase;
use crate::summon_service_runtime::{ServiceRuntimeConfig, SummonServiceRuntime};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn root(tag: &str) -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "wow112_summon_service_sim_{}_{}_{}",
        std::process::id(), stamp, tag
    ))
}

fn finish_one(
    runtime: &mut SummonServiceRuntime,
    journal: &mut MutationCoordinator,
    expected_request: &str,
    now: u64,
) {
    let active = runtime.start_next(now).unwrap().unwrap();
    assert_eq!(active, expected_request);

    let ritual_op = format!("{active}:ritual:1");
    journal
        .commit_before_send(
            &active,
            MutationKind::CastRitual,
            &ritual_op,
            true,
            now + 1,
            "spell=698",
        )
        .unwrap();
    runtime
        .mark_ritual_committed(&active, &ritual_op)
        .unwrap();
    journal.mark_send_ok(&ritual_op, now + 2).unwrap();
    journal
        .confirm_from_server(&ritual_op, now + 3, "SMSG_SPELL_GO spell=698")
        .unwrap();

    let portal_op = format!("{active}:portal:1");
    journal
        .commit_before_send(
            &active,
            MutationKind::PortalUse,
            &portal_op,
            true,
            now + 4,
            "portal_use",
        )
        .unwrap();
    journal.mark_send_ok(&portal_op, now + 5).unwrap();
    journal
        .confirm_from_server(&portal_op, now + 6, "SMSG_SUMMON_REQUEST observed")
        .unwrap();
    runtime.mark_portal_committed(&active).unwrap();

    runtime.mark_summon_completed(&active, now + 7).unwrap();
    assert_eq!(
        runtime.request(&active).unwrap().phase,
        RequestPhase::AwaitingPayment
    );

    runtime
        .mark_payment_received(&active, 40_000, &format!("trade:{active}"), now + 8)
        .unwrap();
    assert_eq!(runtime.request(&active).unwrap().phase, RequestPhase::Completed);
    assert!(journal.unresolved().is_none());
}

#[test]
fn three_clients_complete_sequentially_without_process_restart() {
    let root = root("abc");
    let config = ServiceRuntimeConfig::new(&root, "session-abc");
    let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
    let mut journal = MutationCoordinator::open(root.join("mutations.json")).unwrap();

    let a = runtime
        .on_whisper("Clienta", "hyjal pls", None, Some("simulation"), 10)
        .unwrap()
        .unwrap();
    let b = runtime
        .on_whisper("Clientb", "azshara pls", None, Some("simulation"), 11)
        .unwrap()
        .unwrap();
    let c = runtime
        .on_whisper("Clientc", "winterspring pls", None, Some("simulation"), 12)
        .unwrap()
        .unwrap();

    finish_one(&mut runtime, &mut journal, &a, 100);
    finish_one(&mut runtime, &mut journal, &b, 200);
    finish_one(&mut runtime, &mut journal, &c, 300);

    assert_eq!(runtime.request(&a).unwrap().payment_received_copper, 40_000);
    assert_eq!(runtime.request(&b).unwrap().payment_received_copper, 40_000);
    assert_eq!(runtime.request(&c).unwrap().payment_received_copper, 40_000);
    assert!(runtime.active_request_id().is_none());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn unknown_and_irrelevant_whispers_do_not_create_jobs() {
    let root = root("parser_noise");
    let config = ServiceRuntimeConfig::new(&root, "session-noise");
    let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();

    assert!(runtime
        .on_whisper("Noisea", "what is going on here", None, Some("simulation"), 10)
        .unwrap()
        .is_none());
    assert!(runtime
        .on_whisper("Noiseb", "thanks mate", None, Some("simulation"), 11)
        .unwrap()
        .is_none());
    assert!(runtime.start_next(20).unwrap().is_none());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn restart_after_committed_mutation_stays_hard_blocked_and_is_not_replayed() {
    let root = root("crash_after_commit");
    let path = root.join("mutations.json");
    {
        let mut journal = MutationCoordinator::open(&path).unwrap();
        journal
            .commit_before_send(
                "request-a",
                MutationKind::PortalUse,
                "request-a:portal:1",
                true,
                10,
                "portal_guid=0x1",
            )
            .unwrap();
    }

    let mut restored = MutationCoordinator::open(&path).unwrap();
    assert!(restored.hard_block_reason().is_some());
    assert!(restored
        .commit_before_send(
            "request-a",
            MutationKind::PortalUse,
            "request-a:portal:retry",
            true,
            20,
            "must not replay",
        )
        .is_err());
    let _ = fs::remove_dir_all(root);
}
