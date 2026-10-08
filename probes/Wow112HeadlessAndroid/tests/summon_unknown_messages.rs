use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use wow112_headless_android_probe::summon_mutation_coordinator::MutationCoordinator;
use wow112_headless_android_probe::summon_service_runtime::{
    ServiceRuntimeConfig, SummonServiceRuntime,
};

fn root() -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "wow112_summon_unknown_{}_{}",
        std::process::id(), stamp
    ))
}

#[test]
fn weird_and_ambiguous_messages_never_enqueue_or_create_mutations() {
    let root = root();
    let config = ServiceRuntimeConfig::new(&root, "unknown-matrix");
    let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
    let cases = [
        "sumon plz???",
        "hello + hyjal",
        "invoice please",
        "invitees are here",
        "plus sign + in middle",
        "need gold",
        "portal looks nice",
        "azsharalalala",
        "hyjacking",
        "winter is coming",
        "what level are you?",
        "random words 123",
        "can you maybe perhaps do the thing",
        "invitation sent",
        "invisible now",
    ];

    for (index, text) in cases.iter().enumerate() {
        let result = runtime
            .on_whisper(
                &format!("Odd{index}"),
                text,
                None,
                Some("integration-test"),
                100 + index as u64,
            )
            .unwrap();
        assert!(result.is_none(), "unsafe enqueue for input={text:?}");
    }

    assert!(runtime.active_request_id().is_none());
    assert!(runtime.start_next(1_000).unwrap().is_none());
    let journal = MutationCoordinator::open(root.join("summon_mutations.json")).unwrap();
    assert!(journal.records().is_empty());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn competition_message_never_becomes_customer_request() {
    let root = root();
    let config = ServiceRuntimeConfig::new(&root, "competition-safe");
    let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();

    for text in [
        "selling summons cheaper today",
        "+ selling summons",
        "cheap ports here",
    ] {
        let result = runtime
            .on_whisper("Competitor", text, Some("hyjal"), Some("live_world"), 10)
            .unwrap();
        assert!(result.is_none(), "competition message queued: {text:?}");
    }

    assert!(runtime.start_next(100).unwrap().is_none());
    let _ = fs::remove_dir_all(root);
}
