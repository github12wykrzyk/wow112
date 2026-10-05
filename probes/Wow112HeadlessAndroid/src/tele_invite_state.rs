#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InviteState {
    Idle,
    Armed { target: String },
    Attempted { target: String },
    ConfirmedGrouped { target: String },
    Rejected { target: String, reason: String },
    Uncertain { target: String, reason: String },
}

impl Default for InviteState {
    fn default() -> Self {
        Self::Idle
    }
}

impl InviteState {
    pub fn arm(&mut self, target: &str) -> Result<(), String> {
        if !matches!(self, Self::Idle) {
            return Err(format!("cannot arm invite from state {self:?}"));
        }
        if target.trim().is_empty() {
            return Err("cannot arm empty invite target".to_string());
        }
        *self = Self::Armed {
            target: target.trim().to_string(),
        };
        Ok(())
    }

    /// Must be called before the socket write. This makes any later disconnect
    /// fail closed: an attempted mutation is never automatically repeated.
    pub fn mark_attempt_before_send(&mut self) -> Result<String, String> {
        let target = match self {
            Self::Armed { target } => target.clone(),
            _ => return Err(format!("invite send not allowed from state {self:?}")),
        };
        *self = Self::Attempted {
            target: target.clone(),
        };
        Ok(target)
    }

    pub fn observe_group_member(&mut self, member_name: &str) -> bool {
        let target = match self {
            Self::Attempted { target } | Self::Uncertain { target, .. } => target.clone(),
            _ => return false,
        };
        if !target.eq_ignore_ascii_case(member_name) {
            return false;
        }
        *self = Self::ConfirmedGrouped { target };
        true
    }

    pub fn observe_rejection(&mut self, reason: impl Into<String>) -> Result<(), String> {
        let target = match self {
            Self::Attempted { target } => target.clone(),
            _ => return Err(format!("rejection not valid from state {self:?}")),
        };
        *self = Self::Rejected {
            target,
            reason: reason.into(),
        };
        Ok(())
    }

    pub fn disconnect_after_attempt(&mut self, reason: impl Into<String>) -> bool {
        let target = match self {
            Self::Attempted { target } => target.clone(),
            _ => return false,
        };
        *self = Self::Uncertain {
            target,
            reason: reason.into(),
        };
        true
    }

    pub fn retry_allowed(&self) -> bool {
        matches!(self, Self::Idle | Self::Armed { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disconnect_after_attempt_never_rearms() {
        let mut state = InviteState::default();
        state.arm("Somebody").unwrap();
        assert_eq!(state.mark_attempt_before_send().unwrap(), "Somebody");
        assert!(state.disconnect_after_attempt("socket reset"));
        assert!(!state.retry_allowed());
        assert!(state.mark_attempt_before_send().is_err());
    }

    #[test]
    fn roster_confirmation_finishes_attempt() {
        let mut state = InviteState::default();
        state.arm("Somebody").unwrap();
        state.mark_attempt_before_send().unwrap();
        assert!(!state.observe_group_member("SomeoneElse"));
        assert!(state.observe_group_member("somebody"));
        assert_eq!(
            state,
            InviteState::ConfirmedGrouped {
                target: "Somebody".to_string()
            }
        );
        assert!(!state.retry_allowed());
    }
}
