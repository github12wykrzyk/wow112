use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum MutationKind {
    Invite,
    SummonCast,
    PortalUse { helper: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MutationKey {
    pub station: String,
    pub player: String,
    pub request_seq: u64,
    pub kind: MutationKind,
}

impl MutationKey {
    pub fn normalized(
        station: &str,
        player: &str,
        request_seq: u64,
        kind: MutationKind,
    ) -> Result<Self, String> {
        let station = station.trim().to_ascii_lowercase();
        let player = player.trim().to_ascii_lowercase();
        if station.is_empty() {
            return Err("mutation station must not be empty".to_string());
        }
        if player.is_empty() {
            return Err("mutation player must not be empty".to_string());
        }
        if request_seq == 0 {
            return Err("mutation request_seq must be > 0".to_string());
        }
        Ok(Self {
            station,
            player,
            request_seq,
            kind,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MutationState {
    Attempted { at_s: u64 },
    ObservedSuccess { at_s: u64, evidence: String },
    ObservedFailure { at_s: u64, evidence: String },
    Uncertain { at_s: u64, evidence: String },
}

#[derive(Debug, Default)]
pub struct MutationLedger {
    entries: HashMap<MutationKey, MutationState>,
}

impl MutationLedger {
    pub fn state(&self, key: &MutationKey) -> Option<&MutationState> {
        self.entries.get(key)
    }

    pub fn may_attempt(&self, key: &MutationKey) -> bool {
        !self.entries.contains_key(key)
    }

    /// Must run before socket I/O. Once recorded, the same logical mutation
    /// may never be blindly retried, regardless of reconnect behavior.
    pub fn record_attempt_before_io(
        &mut self,
        key: MutationKey,
        at_s: u64,
    ) -> Result<(), String> {
        if let Some(existing) = self.entries.get(&key) {
            return Err(format!("duplicate mutation blocked: {key:?} state={existing:?}"));
        }
        self.entries.insert(key, MutationState::Attempted { at_s });
        Ok(())
    }

    pub fn observe_success(
        &mut self,
        key: &MutationKey,
        at_s: u64,
        evidence: impl Into<String>,
    ) -> Result<(), String> {
        match self.entries.get(key) {
            Some(MutationState::Attempted { .. }) | Some(MutationState::Uncertain { .. }) => {}
            Some(other) => return Err(format!("cannot mark success from {other:?}")),
            None => return Err("cannot mark success before mutation attempt".to_string()),
        }
        self.entries.insert(
            key.clone(),
            MutationState::ObservedSuccess {
                at_s,
                evidence: evidence.into(),
            },
        );
        Ok(())
    }

    pub fn observe_failure(
        &mut self,
        key: &MutationKey,
        at_s: u64,
        evidence: impl Into<String>,
    ) -> Result<(), String> {
        match self.entries.get(key) {
            Some(MutationState::Attempted { .. }) => {}
            Some(other) => return Err(format!("cannot mark failure from {other:?}")),
            None => return Err("cannot mark failure before mutation attempt".to_string()),
        }
        self.entries.insert(
            key.clone(),
            MutationState::ObservedFailure {
                at_s,
                evidence: evidence.into(),
            },
        );
        Ok(())
    }

    pub fn mark_uncertain(
        &mut self,
        key: &MutationKey,
        at_s: u64,
        evidence: impl Into<String>,
    ) -> Result<(), String> {
        match self.entries.get(key) {
            Some(MutationState::Attempted { .. }) => {}
            Some(other) => return Err(format!("cannot mark uncertain from {other:?}")),
            None => return Err("cannot mark uncertain before mutation attempt".to_string()),
        }
        self.entries.insert(
            key.clone(),
            MutationState::Uncertain {
                at_s,
                evidence: evidence.into(),
            },
        );
        Ok(())
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invite_key(seq: u64) -> MutationKey {
        MutationKey::normalized("hyjal", "Customer", seq, MutationKind::Invite).unwrap()
    }

    #[test]
    fn attempted_or_uncertain_same_request_can_never_retry() {
        let mut ledger = MutationLedger::default();
        let key = invite_key(1);
        assert!(ledger.may_attempt(&key));
        ledger.record_attempt_before_io(key.clone(), 100).unwrap();
        assert!(!ledger.may_attempt(&key));
        ledger.mark_uncertain(&key, 101, "connection reset after write").unwrap();
        assert!(!ledger.may_attempt(&key));
        assert!(ledger.record_attempt_before_io(key, 102).is_err());
    }

    #[test]
    fn new_request_sequence_is_a_new_logical_mutation() {
        let mut ledger = MutationLedger::default();
        let old = invite_key(1);
        let fresh = invite_key(2);
        ledger.record_attempt_before_io(old.clone(), 100).unwrap();
        ledger.observe_failure(&old, 101, "GROUP_FULL").unwrap();
        assert!(!ledger.may_attempt(&old));
        assert!(ledger.may_attempt(&fresh));
    }

    #[test]
    fn portal_helpers_are_deduped_independently() {
        let mut ledger = MutationLedger::default();
        let a = MutationKey::normalized(
            "hyjal",
            "Customer",
            1,
            MutationKind::PortalUse { helper: "helper-a".to_string() },
        )
        .unwrap();
        let b = MutationKey::normalized(
            "hyjal",
            "Customer",
            1,
            MutationKind::PortalUse { helper: "helper-b".to_string() },
        )
        .unwrap();
        ledger.record_attempt_before_io(a.clone(), 100).unwrap();
        assert!(!ledger.may_attempt(&a));
        assert!(ledger.may_attempt(&b));
    }
}
