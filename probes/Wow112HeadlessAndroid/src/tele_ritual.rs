use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RitualRequest {
    pub station: String,
    pub player: String,
    pub request_seq: u64,
}

impl RitualRequest {
    pub fn new(station: &str, player: &str, request_seq: u64) -> Result<Self, String> {
        let station = station.trim().to_ascii_lowercase();
        let player = player.trim().to_ascii_lowercase();
        if station.is_empty() {
            return Err("ritual station must not be empty".to_string());
        }
        if player.is_empty() {
            return Err("ritual player must not be empty".to_string());
        }
        if request_seq == 0 {
            return Err("ritual request_seq must be > 0".to_string());
        }
        Ok(Self {
            station,
            player,
            request_seq,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RitualState {
    Idle,
    Armed {
        request: RitualRequest,
        attempt: u8,
    },
    HardPausedNoShards {
        request: RitualRequest,
        observed_shards: u32,
        required_shards: u32,
    },
    CastAttempted {
        request: RitualRequest,
        attempt: u8,
        ritual_epoch: u64,
    },
    SpellStartObserved {
        request: RitualRequest,
        attempt: u8,
        ritual_epoch: u64,
    },
    WaitingTargetCombat {
        request: RitualRequest,
        attempt: u8,
    },
    PortalObserved {
        request: RitualRequest,
        attempt: u8,
        ritual_epoch: u64,
        portal_guid: u64,
    },
    Completed {
        request: RitualRequest,
        ritual_epoch: u64,
    },
    FailedSafe {
        request: RitualRequest,
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PortalServiceKey {
    pub ritual_epoch: u64,
    pub portal_guid: u64,
    pub helper: String,
}

#[derive(Debug)]
pub struct RitualCore {
    state: RitualState,
    min_shards: u32,
    max_cast_attempts: u8,
    next_ritual_epoch: u64,
    serviced_helpers: HashSet<PortalServiceKey>,
}

impl RitualCore {
    pub fn new(min_shards: u32, max_cast_attempts: u8) -> Result<Self, String> {
        if min_shards == 0 {
            return Err("min_shards must be > 0".to_string());
        }
        if max_cast_attempts == 0 {
            return Err("max_cast_attempts must be > 0".to_string());
        }
        Ok(Self {
            state: RitualState::Idle,
            min_shards,
            max_cast_attempts,
            next_ritual_epoch: 1,
            serviced_helpers: HashSet::new(),
        })
    }

    pub fn state(&self) -> &RitualState {
        &self.state
    }

    pub fn arm(&mut self, request: RitualRequest, shards: u32) -> Result<(), String> {
        if !matches!(self.state, RitualState::Idle) {
            return Err(format!("cannot arm ritual from state {:?}", self.state));
        }
        if shards < self.min_shards {
            self.state = RitualState::HardPausedNoShards {
                request,
                observed_shards: shards,
                required_shards: self.min_shards,
            };
            return Ok(());
        }
        self.state = RitualState::Armed {
            request,
            attempt: 1,
        };
        Ok(())
    }

    /// Must be called before the spell-cast packet/API call. The state transition
    /// happens first, so a disconnect after I/O can never silently re-send the cast.
    pub fn begin_cast_before_io(&mut self) -> Result<u64, String> {
        let (request, attempt) = match &self.state {
            RitualState::Armed { request, attempt } => (request.clone(), *attempt),
            _ => return Err(format!("cast not allowed from state {:?}", self.state)),
        };
        let epoch = self.next_ritual_epoch;
        self.next_ritual_epoch = self.next_ritual_epoch.saturating_add(1);
        self.state = RitualState::CastAttempted {
            request,
            attempt,
            ritual_epoch: epoch,
        };
        Ok(epoch)
    }

    pub fn observe_spell_start(&mut self) -> Result<(), String> {
        let (request, attempt, ritual_epoch) = match &self.state {
            RitualState::CastAttempted {
                request,
                attempt,
                ritual_epoch,
            } => (request.clone(), *attempt, *ritual_epoch),
            _ => return Err(format!("spell start invalid from state {:?}", self.state)),
        };
        self.state = RitualState::SpellStartObserved {
            request,
            attempt,
            ritual_epoch,
        };
        Ok(())
    }

    /// Only an explicit, classified target-combat failure may make the same request
    /// eligible for a bounded later retry. Timeouts/disconnects must use fail_safe().
    pub fn observe_explicit_target_combat(&mut self) -> Result<(), String> {
        let (request, attempt) = match &self.state {
            RitualState::CastAttempted { request, attempt, .. }
            | RitualState::SpellStartObserved { request, attempt, .. } => {
                (request.clone(), *attempt)
            }
            _ => return Err(format!("target-combat invalid from state {:?}", self.state)),
        };
        self.state = RitualState::WaitingTargetCombat { request, attempt };
        Ok(())
    }

    pub fn rearm_after_target_ready(&mut self, shards: u32) -> Result<(), String> {
        let (request, previous_attempt) = match &self.state {
            RitualState::WaitingTargetCombat { request, attempt } => {
                (request.clone(), *attempt)
            }
            _ => return Err(format!("target-ready invalid from state {:?}", self.state)),
        };
        if previous_attempt >= self.max_cast_attempts {
            self.state = RitualState::FailedSafe {
                request,
                reason: format!("max cast attempts reached: {}", self.max_cast_attempts),
            };
            return Ok(());
        }
        if shards < self.min_shards {
            self.state = RitualState::HardPausedNoShards {
                request,
                observed_shards: shards,
                required_shards: self.min_shards,
            };
            return Ok(());
        }
        self.state = RitualState::Armed {
            request,
            attempt: previous_attempt.saturating_add(1),
        };
        Ok(())
    }

    pub fn observe_portal(&mut self, portal_guid: u64) -> Result<u64, String> {
        if portal_guid == 0 {
            return Err("portal guid must not be zero".to_string());
        }
        let (request, attempt, ritual_epoch) = match &self.state {
            RitualState::CastAttempted {
                request,
                attempt,
                ritual_epoch,
            }
            | RitualState::SpellStartObserved {
                request,
                attempt,
                ritual_epoch,
            } => (request.clone(), *attempt, *ritual_epoch),
            RitualState::PortalObserved {
                ritual_epoch,
                portal_guid: current,
                ..
            } if *current == portal_guid => return Ok(*ritual_epoch),
            _ => return Err(format!("portal observation invalid from state {:?}", self.state)),
        };
        self.state = RitualState::PortalObserved {
            request,
            attempt,
            ritual_epoch,
            portal_guid,
        };
        Ok(ritual_epoch)
    }

    pub fn helper_use_allowed(&self, helper: &str) -> bool {
        let helper = helper.trim().to_ascii_lowercase();
        if helper.is_empty() {
            return false;
        }
        let RitualState::PortalObserved {
            ritual_epoch,
            portal_guid,
            ..
        } = &self.state
        else {
            return false;
        };
        !self.serviced_helpers.contains(&PortalServiceKey {
            ritual_epoch: *ritual_epoch,
            portal_guid: *portal_guid,
            helper,
        })
    }

    /// Must run before GAMEOBJ_USE I/O for a helper.
    pub fn record_helper_use_before_io(&mut self, helper: &str) -> Result<PortalServiceKey, String> {
        let helper = helper.trim().to_ascii_lowercase();
        if helper.is_empty() {
            return Err("helper must not be empty".to_string());
        }
        let (ritual_epoch, portal_guid) = match &self.state {
            RitualState::PortalObserved {
                ritual_epoch,
                portal_guid,
                ..
            } => (*ritual_epoch, *portal_guid),
            _ => return Err(format!("portal use not allowed from state {:?}", self.state)),
        };
        let key = PortalServiceKey {
            ritual_epoch,
            portal_guid,
            helper,
        };
        if !self.serviced_helpers.insert(key.clone()) {
            return Err(format!("duplicate helper portal use blocked: {key:?}"));
        }
        Ok(key)
    }

    pub fn observe_completion(&mut self) -> Result<(), String> {
        let (request, ritual_epoch) = match &self.state {
            RitualState::PortalObserved {
                request,
                ritual_epoch,
                ..
            } => (request.clone(), *ritual_epoch),
            _ => return Err(format!("completion invalid from state {:?}", self.state)),
        };
        self.state = RitualState::Completed {
            request,
            ritual_epoch,
        };
        Ok(())
    }

    pub fn fail_safe(&mut self, reason: impl Into<String>) -> Result<(), String> {
        let request = match &self.state {
            RitualState::Idle => return Err("cannot fail-safe an idle ritual".to_string()),
            RitualState::Armed { request, .. }
            | RitualState::HardPausedNoShards { request, .. }
            | RitualState::CastAttempted { request, .. }
            | RitualState::SpellStartObserved { request, .. }
            | RitualState::WaitingTargetCombat { request, .. }
            | RitualState::PortalObserved { request, .. }
            | RitualState::Completed { request, .. }
            | RitualState::FailedSafe { request, .. } => request.clone(),
        };
        self.state = RitualState::FailedSafe {
            request,
            reason: reason.into(),
        };
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(seq: u64) -> RitualRequest {
        RitualRequest::new("hyjal", "Customer", seq).unwrap()
    }

    #[test]
    fn no_shards_is_hard_pause_not_cast() {
        let mut core = RitualCore::new(1, 2).unwrap();
        core.arm(request(1), 0).unwrap();
        assert!(matches!(core.state(), RitualState::HardPausedNoShards { .. }));
        assert!(core.begin_cast_before_io().is_err());
    }

    #[test]
    fn cast_is_one_shot_until_explicit_server_outcome() {
        let mut core = RitualCore::new(1, 2).unwrap();
        core.arm(request(1), 2).unwrap();
        assert_eq!(core.begin_cast_before_io().unwrap(), 1);
        assert!(core.begin_cast_before_io().is_err());
        core.fail_safe("disconnect after cast write").unwrap();
        assert!(core.begin_cast_before_io().is_err());
    }

    #[test]
    fn explicit_target_combat_can_rearm_bounded_retry() {
        let mut core = RitualCore::new(1, 2).unwrap();
        core.arm(request(1), 2).unwrap();
        assert_eq!(core.begin_cast_before_io().unwrap(), 1);
        core.observe_explicit_target_combat().unwrap();
        core.rearm_after_target_ready(2).unwrap();
        assert_eq!(core.begin_cast_before_io().unwrap(), 2);
        core.observe_explicit_target_combat().unwrap();
        core.rearm_after_target_ready(2).unwrap();
        assert!(matches!(core.state(), RitualState::FailedSafe { .. }));
    }

    #[test]
    fn helper_click_is_once_per_portal_epoch_and_helper() {
        let mut core = RitualCore::new(1, 2).unwrap();
        core.arm(request(1), 2).unwrap();
        core.begin_cast_before_io().unwrap();
        core.observe_spell_start().unwrap();
        assert_eq!(core.observe_portal(0xABC).unwrap(), 1);
        assert!(core.helper_use_allowed("helper-a"));
        core.record_helper_use_before_io("helper-a").unwrap();
        assert!(!core.helper_use_allowed("HELPER-A"));
        assert!(core.record_helper_use_before_io("helper-a").is_err());
        assert!(core.helper_use_allowed("helper-b"));
        core.record_helper_use_before_io("helper-b").unwrap();
    }

    #[test]
    fn duplicate_portal_observation_is_idempotent() {
        let mut core = RitualCore::new(1, 2).unwrap();
        core.arm(request(1), 1).unwrap();
        core.begin_cast_before_io().unwrap();
        assert_eq!(core.observe_portal(0xABC).unwrap(), 1);
        assert_eq!(core.observe_portal(0xABC).unwrap(), 1);
    }
}
