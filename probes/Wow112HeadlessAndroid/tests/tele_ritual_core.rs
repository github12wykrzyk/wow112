#[path = "../src/tele_ritual.rs"]
mod tele_ritual;

use tele_ritual::{RitualCore, RitualRequest, RitualState};

fn request(seq: u64) -> RitualRequest {
    RitualRequest::new("hyjal", "Customer", seq).unwrap()
}

#[test]
fn no_shards_never_reaches_cast_attempt() {
    let mut core = RitualCore::new(1, 2).unwrap();
    core.arm(request(1), 0).unwrap();
    assert!(matches!(core.state(), RitualState::HardPausedNoShards { .. }));
    assert!(core.begin_cast_before_io().is_err());
}

#[test]
fn network_uncertainty_after_cast_is_terminal_for_automatic_retry() {
    let mut core = RitualCore::new(1, 2).unwrap();
    core.arm(request(1), 3).unwrap();
    let epoch = core.begin_cast_before_io().unwrap();
    assert_eq!(epoch, 1);
    core.fail_safe("world socket reset after cast attempt").unwrap();
    assert!(matches!(core.state(), RitualState::FailedSafe { .. }));
    assert!(core.begin_cast_before_io().is_err());
}

#[test]
fn target_combat_retry_requires_explicit_ready_transition_and_is_bounded() {
    let mut core = RitualCore::new(1, 2).unwrap();
    core.arm(request(1), 3).unwrap();
    assert_eq!(core.begin_cast_before_io().unwrap(), 1);
    core.observe_explicit_target_combat().unwrap();
    assert!(matches!(core.state(), RitualState::WaitingTargetCombat { .. }));
    assert!(core.begin_cast_before_io().is_err());
    core.rearm_after_target_ready(3).unwrap();
    assert_eq!(core.begin_cast_before_io().unwrap(), 2);
    core.observe_explicit_target_combat().unwrap();
    core.rearm_after_target_ready(3).unwrap();
    assert!(matches!(core.state(), RitualState::FailedSafe { .. }));
}

#[test]
fn helpers_are_idempotent_per_portal_guid_and_epoch() {
    let mut core = RitualCore::new(1, 2).unwrap();
    core.arm(request(1), 3).unwrap();
    core.begin_cast_before_io().unwrap();
    core.observe_spell_start().unwrap();
    core.observe_portal(0x1234).unwrap();

    assert!(core.helper_use_allowed("HelperA"));
    let first = core.record_helper_use_before_io("HelperA").unwrap();
    assert_eq!(first.ritual_epoch, 1);
    assert_eq!(first.portal_guid, 0x1234);
    assert!(!core.helper_use_allowed("helpera"));
    assert!(core.record_helper_use_before_io("HELPERA").is_err());

    assert!(core.helper_use_allowed("HelperB"));
    core.record_helper_use_before_io("HelperB").unwrap();
    core.observe_completion().unwrap();
    assert!(matches!(core.state(), RitualState::Completed { ritual_epoch: 1, .. }));
}
