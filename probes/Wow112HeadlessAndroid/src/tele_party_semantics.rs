use wow_world_messages::vanilla::{PartyOperation, PartyResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PartyCommandOutcome {
    InviteAcceptedByServer,
    BadPlayerName,
    TargetNotInGroup,
    GroupFull,
    AlreadyInGroup,
    NotInGroup,
    NotLeader,
    WrongFaction,
    IgnoringYou,
    UnexpectedOperation,
}

impl PartyCommandOutcome {
    pub fn is_terminal_failure(self) -> bool {
        !matches!(self, Self::InviteAcceptedByServer)
    }

    /// A server-side SUCCESS only means the invite command was accepted for processing.
    /// TELE must still wait for SMSG_GROUP_LIST containing the target before treating
    /// the customer as grouped.
    pub fn confirms_group_membership(self) -> bool {
        false
    }
}

pub fn classify_party_command(
    operation: PartyOperation,
    result: PartyResult,
) -> PartyCommandOutcome {
    if operation != PartyOperation::Invite {
        return PartyCommandOutcome::UnexpectedOperation;
    }

    match result {
        PartyResult::Success => PartyCommandOutcome::InviteAcceptedByServer,
        PartyResult::BadPlayerName => PartyCommandOutcome::BadPlayerName,
        PartyResult::TargetNotInGroup => PartyCommandOutcome::TargetNotInGroup,
        PartyResult::GroupFull => PartyCommandOutcome::GroupFull,
        PartyResult::AlreadyInGroup => PartyCommandOutcome::AlreadyInGroup,
        PartyResult::NotInGroup => PartyCommandOutcome::NotInGroup,
        PartyResult::NotLeader => PartyCommandOutcome::NotLeader,
        PartyResult::PlayerWrongFaction => PartyCommandOutcome::WrongFaction,
        PartyResult::IgnoringYou => PartyCommandOutcome::IgnoringYou,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_is_not_roster_confirmation() {
        let outcome = classify_party_command(PartyOperation::Invite, PartyResult::Success);
        assert_eq!(outcome, PartyCommandOutcome::InviteAcceptedByServer);
        assert!(!outcome.confirms_group_membership());
        assert!(!outcome.is_terminal_failure());
    }

    #[test]
    fn invite_failures_are_terminal_for_same_request() {
        for result in [
            PartyResult::BadPlayerName,
            PartyResult::GroupFull,
            PartyResult::AlreadyInGroup,
            PartyResult::NotLeader,
            PartyResult::PlayerWrongFaction,
            PartyResult::IgnoringYou,
        ] {
            assert!(classify_party_command(PartyOperation::Invite, result).is_terminal_failure());
        }
    }
}
