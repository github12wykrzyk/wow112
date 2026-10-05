#[path = "../src/tele_invite_wire.rs"]
mod tele_invite_wire;
#[path = "../src/tele_invite_state.rs"]
mod tele_invite_state;

use tele_invite_state::InviteState;
use tele_invite_wire::{encode_group_invite_target, OneShotInviteGuard, CMSG_GROUP_INVITE_OPCODE};

#[test]
fn protocol_contract_is_vanilla_group_invite_cstring() {
    assert_eq!(CMSG_GROUP_INVITE_OPCODE, 0x006E);
    assert_eq!(encode_group_invite_target("Target").unwrap(), b"Target\0");
}

#[test]
fn guard_and_state_machine_fail_closed_together() {
    let mut guard = OneShotInviteGuard::default();
    let mut state = InviteState::default();

    state.arm("Target").unwrap();
    let target = state.mark_attempt_before_send().unwrap();
    guard.arm_attempt().unwrap();
    assert_eq!(target, "Target");

    state.disconnect_after_attempt("connection reset after write");
    assert!(!state.retry_allowed());
    assert!(guard.arm_attempt().is_err());
    assert!(state.mark_attempt_before_send().is_err());
}
