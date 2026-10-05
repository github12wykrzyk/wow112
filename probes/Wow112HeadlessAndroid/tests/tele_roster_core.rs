#[path = "../src/tele_roster.rs"]
mod tele_roster;
#[path = "../src/tele_mutation_ledger.rs"]
mod tele_mutation_ledger;

use tele_mutation_ledger::{MutationKey, MutationKind, MutationLedger, MutationState};
use tele_roster::{GroupMemberSnapshot, GroupSnapshot, RosterState, RosterTransition};

fn member(name: &str, guid: u64, online: bool) -> GroupMemberSnapshot {
    GroupMemberSnapshot {
        name: name.to_string(),
        guid,
        is_online: online,
        flags: 0,
    }
}

fn invite_key(seq: u64) -> MutationKey {
    MutationKey::normalized("hyjal", "Customer", seq, MutationKind::Invite).unwrap()
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

#[test]
fn uncertain_invite_is_never_retried_but_can_be_resolved_by_later_roster() {
    let mut ledger = MutationLedger::default();
    let mut roster = RosterState::default();
    let key = invite_key(1);

    ledger.record_attempt_before_io(key.clone(), 100).unwrap();
    ledger.mark_uncertain(&key, 101, "socket reset after write").unwrap();
    assert!(!ledger.may_attempt(&key));

    // A later full-state rebuild may prove that the first uncertain invite actually succeeded.
    roster.apply_snapshot(GroupSnapshot {
        leader_guid: 100,
        members: vec![member("Feltaxi", 100, true), member("Customer", 102, true)],
    });
    assert!(roster.confirms_membership("Customer"));
    ledger
        .observe_success(&key, 102, "GROUP_LIST contains Customer")
        .unwrap();
    assert!(matches!(ledger.state(&key), Some(MutationState::ObservedSuccess { .. })));
    assert!(!ledger.may_attempt(&key));
}

#[test]
fn explicit_new_request_sequence_is_required_for_new_invite_attempt() {
    let mut ledger = MutationLedger::default();
    let old = invite_key(1);
    ledger.record_attempt_before_io(old.clone(), 100).unwrap();
    ledger.observe_failure(&old, 101, "GROUP_FULL").unwrap();
    assert!(!ledger.may_attempt(&old));

    let fresh = invite_key(2);
    assert!(ledger.may_attempt(&fresh));
    ledger.record_attempt_before_io(fresh.clone(), 200).unwrap();
    assert!(!ledger.may_attempt(&fresh));
}
