#[path = "../src/tele_roster.rs"]
mod tele_roster;

use tele_roster::{GroupMemberSnapshot, GroupSnapshot, RosterState, RosterTransition};

fn member(name: &str, guid: u64, online: bool) -> GroupMemberSnapshot {
    GroupMemberSnapshot {
        name: name.to_string(),
        guid,
        is_online: online,
        flags: 0,
    }
}

#[test]
fn invite_command_success_alone_cannot_create_grouped_state() {
    let roster = RosterState::default();
    // There is intentionally no API to mark a member grouped from a command result.
    assert!(!roster.confirms_membership("Customer"));
}

#[test]
fn roster_snapshot_is_authoritative_for_customer_and_leader() {
    let mut roster = RosterState::default();
    assert_eq!(
        roster.apply_snapshot(GroupSnapshot {
            leader_guid: 100,
            members: vec![
                member("Feltaxi", 100, true),
                member("Helperone", 101, true),
                member("Customer", 102, true),
            ],
        }),
        RosterTransition::Changed { epoch: 1 }
    );
    assert!(roster.confirms_membership("customer"));
    assert!(roster.is_leader_name("FELTAXI"));
    assert_eq!(roster.leader_guid(), Some(100));
}

#[test]
fn reconnect_rebuild_can_reapply_same_snapshot_without_false_transition() {
    let mut roster = RosterState::default();
    let snapshot = GroupSnapshot {
        leader_guid: 100,
        members: vec![member("Feltaxi", 100, true), member("Customer", 102, true)],
    };
    assert_eq!(roster.apply_snapshot(snapshot.clone()), RosterTransition::Changed { epoch: 1 });
    assert_eq!(roster.apply_snapshot(snapshot), RosterTransition::Unchanged { epoch: 1 });
}

#[test]
fn removal_from_snapshot_revokes_membership_immediately() {
    let mut roster = RosterState::default();
    roster.apply_snapshot(GroupSnapshot {
        leader_guid: 100,
        members: vec![member("Feltaxi", 100, true), member("Customer", 102, true)],
    });
    assert!(roster.confirms_membership("Customer"));
    roster.apply_snapshot(GroupSnapshot {
        leader_guid: 100,
        members: vec![member("Feltaxi", 100, true)],
    });
    assert!(!roster.confirms_membership("Customer"));
    assert_eq!(roster.epoch(), 2);
}
