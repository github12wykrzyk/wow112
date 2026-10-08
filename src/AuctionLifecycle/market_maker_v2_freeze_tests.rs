#[path = "market_maker_v2_saga.rs"]
mod saga;

use saga::{Mm2SagaJournal, Mm2SagaKind, Mm2SagaPhase};
use std::path::PathBuf;

fn server(tag: &str) -> String {
    format!("mm2-freeze-{tag}-{}", std::process::id())
}

fn reopen(server: &str, realm: u32, guid: u64, expected: &Mm2SagaPhase) -> Mm2SagaJournal {
    let journal = Mm2SagaJournal::open(server, realm, guid).expect("reopen saga");
    assert_eq!(&journal.state().expect("state").phase, expected);
    journal
}

fn advance_restart(
    mut journal: Mm2SagaJournal,
    server: &str,
    realm: u32,
    guid: u64,
    next: Mm2SagaPhase,
) -> Mm2SagaJournal {
    journal.advance(next.clone()).expect("advance");
    let path = journal.path().to_path_buf();
    drop(journal); // simulate process crash/restart boundary after durable append
    assert!(path.exists(), "durable saga journal missing after crash boundary");
    reopen(server, realm, guid, &next)
}

fn cleanup(mut journal: Mm2SagaJournal) {
    let path: PathBuf = journal.path().to_path_buf();
    drop(journal);
    let _ = std::fs::remove_file(path);
}

#[test]
fn undercut_saga_survives_restart_after_every_phase() {
    let s = server("undercut");
    let realm = 901;
    let guid = 0xA001;
    let mut j = Mm2SagaJournal::open(&s, realm, guid).unwrap();
    j.start(Mm2SagaKind::Undercut, 777, [1, 2, 3], Some(55)).unwrap();
    let path = j.path().to_path_buf();
    drop(j);
    assert!(path.exists());
    let mut j = reopen(&s, realm, guid, &Mm2SagaPhase::Planned);

    for phase in [
        Mm2SagaPhase::MailboxVerified { mailbox: 0x9001 },
        Mm2SagaPhase::CancelIntent { auction_id: 55 },
        Mm2SagaPhase::CancelConfirmed { auction_id: 55 },
        Mm2SagaPhase::ReturnMailFound { mail_id: 8 },
        Mm2SagaPhase::MailTakeIntent { mail_id: 8, item_id: 777, count: 2 },
        Mm2SagaPhase::ItemTaken { item_id: 777, count: 2 },
        Mm2SagaPhase::InventoryVerified { guid: 0xB001, item_id: 777, count: 2, bag: 255, slot: 23 },
        Mm2SagaPhase::SplitIntent { source_guid: 0xB001, source_bag: 255, source_slot: 23, split_count: 1, dest_bag: 255, dest_slot: 24 },
        Mm2SagaPhase::SplitProgress { source_guid: 0xB001, remaining: 1, units: vec![0xB002] },
        Mm2SagaPhase::PostIntent { guid: 0xB002, bag: 255, slot: 24, bid: 999, buyout: 1000, minutes: 120 },
        Mm2SagaPhase::PostProgress { posted: 1, remaining: vec![] },
        Mm2SagaPhase::Done,
    ] {
        j = advance_restart(j, &s, realm, guid, phase);
    }
    assert!(j.can_start_new());
    cleanup(j);
}

#[test]
fn clear_saga_survives_restart_after_every_clear_phase() {
    let s = server("clear");
    let realm = 902;
    let guid = 0xA002;
    let mut j = Mm2SagaJournal::open(&s, realm, guid).unwrap();
    j.start(Mm2SagaKind::Clear, 888, [4, 5, 6], None).unwrap();
    let path = j.path().to_path_buf();
    drop(j);
    assert!(path.exists());
    let mut j = reopen(&s, realm, guid, &Mm2SagaPhase::Planned);

    for phase in [
        Mm2SagaPhase::MailboxVerified { mailbox: 0x9002 },
        Mm2SagaPhase::ClearBuyIntent { auction_id: 70, spend: 100, units: 1 },
        Mm2SagaPhase::ClearBuyConfirmed { auction_id: 70, spend: 100, units: 1 },
        Mm2SagaPhase::ReturnMailFound { mail_id: 9 },
        Mm2SagaPhase::MailTakeIntent { mail_id: 9, item_id: 888, count: 1 },
        Mm2SagaPhase::ItemTaken { item_id: 888, count: 1 },
        Mm2SagaPhase::InventoryVerified { guid: 0xC001, item_id: 888, count: 1, bag: 255, slot: 23 },
        Mm2SagaPhase::Done,
    ] {
        j = advance_restart(j, &s, realm, guid, phase);
    }
    assert!(j.can_start_new());
    cleanup(j);
}

#[test]
fn uncertain_and_hold_remain_terminal_after_restart() {
    for (tag, terminal) in [
        ("uncertain", Mm2SagaPhase::BlockedUncertain { mutation: "POST".into(), detail: "timeout after partial send".into() }),
        ("hold", Mm2SagaPhase::Hold { reason: "stale identity before send".into() }),
    ] {
        let s = server(tag);
        let realm = if tag == "uncertain" { 903 } else { 904 };
        let guid = if tag == "uncertain" { 0xA003 } else { 0xA004 };
        let mut j = Mm2SagaJournal::open(&s, realm, guid).unwrap();
        j.start(Mm2SagaKind::Undercut, 999, [7, 8, 9], Some(91)).unwrap();
        match &terminal {
            Mm2SagaPhase::BlockedUncertain { mutation, detail } => j.block_uncertain(mutation, detail).unwrap(),
            Mm2SagaPhase::Hold { .. } => j.advance(terminal.clone()).unwrap(),
            _ => unreachable!(),
        }
        let path = j.path().to_path_buf();
        drop(j);
        let mut j = reopen(&s, realm, guid, &terminal);
        assert!(!j.can_start_new());
        assert!(!j.has_unfinished());
        assert!(j.advance(Mm2SagaPhase::Done).is_err());
        drop(j);
        let _ = std::fs::remove_file(path);
    }
}
