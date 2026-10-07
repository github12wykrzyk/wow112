use crate::ah_history_observer::{configure_realm, HistoryAuction, HistoryObserver};
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp(name: &str) -> std::path::PathBuf {
    let ns = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("wow112-{name}-{}-{ns}", std::process::id()))
}

#[test]
fn same_session_writer_emits_ingestable_scopes_and_storage_failure_is_nonfatal() {
    configure_realm("test-server:3724", 7, "TestRealm");
    std::env::set_var("WOW112_AH_HISTORY_CAPTURE", "1");
    std::env::set_var("WOW112_SERVER_ID", "test-server");
    std::env::set_var("WOW112_MARKET_EPOCH", "fixture-epoch-v1");
    std::env::set_var("WOW112_MARKET_IDENTITY_VERIFIED", "YES");

    let dir = unique_temp("history-good");
    std::env::set_var("WOW112_AH_HISTORY_CAPTURE_DIR", &dir);
    let mut observer = HistoryObserver::start("full_market", 2, None).expect("observer should start");
    observer.page(0, 1, &[HistoryAuction {
        auction_id: 10,
        item_id: 10940,
        count: 2,
        buyout_total_copper: 300,
        start_bid_copper: 200,
        current_bid_copper: 0,
        min_increment_copper: 0,
        time_left_raw: 1,
    }]);
    observer.finish_best_effort("completed", "offline_test");
    let files = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect::<Vec<_>>();
    let final_file = files.iter().find(|p| p.extension().and_then(|x| x.to_str()) == Some("ndjson")).expect("final ndjson");
    let text = fs::read_to_string(final_file).unwrap();
    assert!(text.contains("\"scope\":\"full_market\""));
    assert!(text.contains("\"identity_status\":\"verified\""));
    assert!(text.contains("\"event_type\":\"PageObserved\""));
    assert!(text.contains("\"status\":\"completed\""));

    let bad = unique_temp("history-bad");
    fs::write(&bad, b"not a directory").unwrap();
    std::env::set_var("WOW112_AH_HISTORY_CAPTURE_DIR", &bad);
    assert!(HistoryObserver::start("full_market", 2, None).is_none(), "storage setup failure must disable history, not fail trading flow");

    let _ = fs::remove_dir_all(&dir);
    let _ = fs::remove_file(&bad);
}