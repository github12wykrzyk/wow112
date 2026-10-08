//! TELE-06A sequential party convergence (pure state machine, no I/O).
//!
//! Replaces the one-shot "3 invites, 350 ms apart, then wait for a full roster"
//! batch.  Members are invited strictly one at a time; the next invite is only
//! released after the previous member is membership-confirmed (SMSG_GROUP_LIST)
//! or unambiguously classified (SERVER_REJECT / TIMEOUT).
//!
//! Mutation safety:
//! * `next_action` moves a member to `InviteSent` BEFORE the caller touches the
//!   socket, so a crash/reconnect can never replay the same invite.
//! * There is NO automatic re-invite.  A member that was never confirmed ends
//!   the whole sequence (fail closed) with a classified reason.
//!
//! The module has no dependencies on purpose so it can be unit-tested anywhere.

#![allow(dead_code)]

pub const SMSG_GROUP_DECLINE_OPCODE: u16 = 0x0074;
pub const SMSG_PARTY_COMMAND_RESULT_OPCODE: u16 = 0x007F;

/// PARTY_OP_INVITE in SMSG_PARTY_COMMAND_RESULT.
const PARTY_OP_INVITE: u32 = 0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemberState {
    Waiting,
    InviteSent,
    /// Member appeared in a SMSG_GROUP_LIST (accept happened server-side).
    AcceptObserved,
    /// Member is in the latest roster and the engine moved on.
    RosterConfirmed,
    ServerReject,
    Timeout,
}

impl MemberState {
    pub fn name(self) -> &'static str {
        match self {
            MemberState::Waiting => "WAITING",
            MemberState::InviteSent => "INVITE_SENT",
            MemberState::AcceptObserved => "ACCEPT_OBSERVED",
            MemberState::RosterConfirmed => "ROSTER_CONFIRMED",
            MemberState::ServerReject => "SERVER_REJECT",
            MemberState::Timeout => "TIMEOUT",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FailReason {
    ServerReject { member: String, detail: String },
    Timeout { member: String, waited_ms: u64 },
    MemberLost { member: String },
    WriteUncertain { member: String },
}

impl FailReason {
    pub fn describe(&self) -> String {
        match self {
            FailReason::ServerReject { member, detail } => {
                format!("member={member:?} state=SERVER_REJECT detail={detail}")
            }
            FailReason::Timeout { member, waited_ms } => {
                format!("member={member:?} state=TIMEOUT waited_ms={waited_ms}")
            }
            FailReason::MemberLost { member } => {
                format!("member={member:?} state=MEMBER_LOST left roster after confirmation")
            }
            FailReason::WriteUncertain { member } => {
                format!("member={member:?} state=WRITE_UNCERTAIN no retry allowed")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// The member was ALREADY marked `InviteSent`; the caller must now write
    /// exactly one CMSG_GROUP_INVITE for `name`.
    SendInvite { index: usize, name: String },
    Wait,
    Done,
    Fail(FailReason),
}

#[derive(Clone, Debug)]
struct Member {
    name: String,
    key: String,
    state: MemberState,
    sent_at_ms: Option<u64>,
    /// SMSG_PARTY_COMMAND_RESULT(op=invite, OK) seen for this member.
    invite_acked: bool,
    detail: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PartyCommandResult {
    pub operation: u32,
    pub member: String,
    pub result: u32,
}

pub fn party_result_name(result: u32) -> &'static str {
    match result {
        0 => "OK",
        1 => "BAD_PLAYER_NAME",
        2 => "TARGET_NOT_IN_GROUP",
        3 => "GROUP_FULL",
        4 => "ALREADY_IN_GROUP",
        5 => "NOT_IN_GROUP",
        6 => "NOT_LEADER",
        7 => "PLAYER_WRONG_FACTION",
        8 => "IGNORING_YOU",
        _ => "UNKNOWN",
    }
}

/// payload = u32 operation, cstring member, u32 result (vanilla 1.12).
pub fn parse_party_command_result(payload: &[u8]) -> Result<PartyCommandResult, String> {
    if payload.len() < 4 + 1 + 4 {
        return Err(format!("party command result too short: {}", payload.len()));
    }
    let operation = u32::from_le_bytes(payload[0..4].try_into().unwrap());
    let rest = &payload[4..];
    let nul = rest
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| "party command result name not terminated".to_string())?;
    let member = String::from_utf8_lossy(&rest[..nul]).to_string();
    let tail = &rest[nul + 1..];
    if tail.len() < 4 {
        return Err("party command result missing result code".to_string());
    }
    let result = u32::from_le_bytes(tail[0..4].try_into().unwrap());
    Ok(PartyCommandResult { operation, member, result })
}

/// SMSG_GROUP_DECLINE payload = cstring name.
pub fn parse_group_decline(payload: &[u8]) -> Result<String, String> {
    let nul = payload
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| "group decline name not terminated".to_string())?;
    Ok(String::from_utf8_lossy(&payload[..nul]).to_string())
}

pub struct PartySeq {
    members: Vec<Member>,
    roster: Vec<String>,
    member_timeout_ms: u64,
    failed: Option<FailReason>,
}

impl PartySeq {
    pub fn new(names: &[String], member_timeout_ms: u64) -> Self {
        let members = names
            .iter()
            .map(|name| name.trim())
            .filter(|name| !name.is_empty())
            .map(|name| Member {
                name: name.to_string(),
                key: name.to_ascii_lowercase(),
                state: MemberState::Waiting,
                sent_at_ms: None,
                invite_acked: false,
                detail: String::new(),
            })
            .collect();
        PartySeq { members, roster: Vec::new(), member_timeout_ms, failed: None }
    }

    pub fn len(&self) -> usize {
        self.members.len()
    }

    pub fn failure(&self) -> Option<&FailReason> {
        self.failed.as_ref()
    }

    pub fn state_of(&self, name: &str) -> Option<MemberState> {
        let key = name.to_ascii_lowercase();
        self.members.iter().find(|m| m.key == key).map(|m| m.state)
    }

    pub fn is_complete(&self) -> bool {
        self.failed.is_none()
            && !self.members.is_empty()
            && self.members.iter().all(|m| m.state == MemberState::RosterConfirmed)
    }

    fn fail(&mut self, reason: FailReason) -> Action {
        if self.failed.is_none() {
            self.failed = Some(reason);
        }
        Action::Fail(self.failed.clone().unwrap())
    }

    fn in_roster(&self, key: &str) -> bool {
        self.roster.iter().any(|name| name == key)
    }

    /// Feed every SMSG_GROUP_LIST: `names` are the members listed by the server.
    pub fn on_group_list(&mut self, names: &[String]) {
        self.roster = names.iter().map(|name| name.to_ascii_lowercase()).collect();
        let roster = self.roster.clone();
        let mut lost: Option<String> = None;
        for member in self.members.iter_mut() {
            let present = roster.iter().any(|name| *name == member.key);
            match member.state {
                MemberState::InviteSent if present => member.state = MemberState::AcceptObserved,
                MemberState::RosterConfirmed if !present => lost = Some(member.name.clone()),
                _ => {}
            }
        }
        if let Some(member) = lost {
            if self.failed.is_none() {
                self.failed = Some(FailReason::MemberLost { member });
            }
        }
    }

    /// Feed SMSG_PARTY_COMMAND_RESULT.  Returns the parsed packet for logging.
    pub fn on_party_command_result(&mut self, payload: &[u8]) -> Result<PartyCommandResult, String> {
        let parsed = parse_party_command_result(payload)?;
        if parsed.operation != PARTY_OP_INVITE {
            return Ok(parsed);
        }
        let key = parsed.member.to_ascii_lowercase();
        let mut reject: Option<FailReason> = None;
        if let Some(member) = self.members.iter_mut().find(|m| m.key == key) {
            if parsed.result == 0 {
                member.invite_acked = true;
            } else if member.state == MemberState::InviteSent {
                member.state = MemberState::ServerReject;
                member.detail = format!(
                    "result=0x{:02X} {}",
                    parsed.result,
                    party_result_name(parsed.result)
                );
                reject = Some(FailReason::ServerReject {
                    member: member.name.clone(),
                    detail: member.detail.clone(),
                });
            }
        }
        if let Some(reason) = reject {
            if self.failed.is_none() {
                self.failed = Some(reason);
            }
        }
        Ok(parsed)
    }

    /// Feed SMSG_GROUP_DECLINE.  Returns the decliner's name for logging.
    pub fn on_group_decline(&mut self, payload: &[u8]) -> Result<String, String> {
        let name = parse_group_decline(payload)?;
        let key = name.to_ascii_lowercase();
        let mut reject: Option<FailReason> = None;
        if let Some(member) = self.members.iter_mut().find(|m| m.key == key) {
            if member.state == MemberState::InviteSent {
                member.state = MemberState::ServerReject;
                member.detail = "declined".to_string();
                reject = Some(FailReason::ServerReject {
                    member: member.name.clone(),
                    detail: "declined".to_string(),
                });
            }
        }
        if let Some(reason) = reject {
            if self.failed.is_none() {
                self.failed = Some(reason);
            }
        }
        Ok(name)
    }

    /// The socket write for `index` had an uncertain outcome: fail closed.
    pub fn on_write_uncertain(&mut self, index: usize) -> Action {
        let member = self
            .members
            .get(index)
            .map(|m| m.name.clone())
            .unwrap_or_default();
        self.fail(FailReason::WriteUncertain { member })
    }

    /// Drive the machine.  `now_ms` is any monotonic millisecond clock.
    pub fn next_action(&mut self, now_ms: u64) -> Action {
        if let Some(reason) = self.failed.clone() {
            return Action::Fail(reason);
        }
        for index in 0..self.members.len() {
            // Promote members that were observed in the roster.
            if self.members[index].state == MemberState::AcceptObserved {
                let key = self.members[index].key.clone();
                if self.in_roster(&key) {
                    self.members[index].state = MemberState::RosterConfirmed;
                }
            }
            match self.members[index].state {
                MemberState::RosterConfirmed => continue,
                MemberState::Waiting => {
                    let key = self.members[index].key.clone();
                    if self.in_roster(&key) {
                        // Already in the group: observed outcome, no invite needed.
                        self.members[index].state = MemberState::RosterConfirmed;
                        self.members[index].detail = "already_in_roster".to_string();
                        continue;
                    }
                    // Guard/state transition BEFORE any socket I/O.
                    self.members[index].state = MemberState::InviteSent;
                    self.members[index].sent_at_ms = Some(now_ms);
                    return Action::SendInvite {
                        index,
                        name: self.members[index].name.clone(),
                    };
                }
                MemberState::InviteSent | MemberState::AcceptObserved => {
                    let sent = self.members[index].sent_at_ms.unwrap_or(now_ms);
                    let waited = now_ms.saturating_sub(sent);
                    if waited >= self.member_timeout_ms {
                        self.members[index].state = MemberState::Timeout;
                        let member = self.members[index].name.clone();
                        return self.fail(FailReason::Timeout { member, waited_ms: waited });
                    }
                    return Action::Wait;
                }
                MemberState::ServerReject | MemberState::Timeout => {
                    let member = self.members[index].name.clone();
                    let detail = self.members[index].detail.clone();
                    return self.fail(FailReason::ServerReject { member, detail });
                }
            }
        }
        if self.members.is_empty() {
            return Action::Wait;
        }
        Action::Done
    }

    /// One line per member for diagnostics (never contains credentials).
    pub fn report(&self) -> Vec<String> {
        self.members
            .iter()
            .enumerate()
            .map(|(index, m)| {
                format!(
                    "[TELE-06A-PARTY] member[{}]={:?} state={} invite_acked={} detail={}",
                    index,
                    m.name,
                    m.state.name(),
                    m.invite_acked,
                    if m.detail.is_empty() { "-" } else { &m.detail }
                )
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names() -> Vec<String> {
        ["Smokinpole", "Winterone", "Wintertwoo"].iter().map(|s| s.to_string()).collect()
    }

    fn list(members: &[&str]) -> Vec<String> {
        members.iter().map(|s| s.to_string()).collect()
    }

    fn result_payload(op: u32, name: &str, result: u32) -> Vec<u8> {
        let mut p = Vec::new();
        p.extend_from_slice(&op.to_le_bytes());
        p.extend_from_slice(name.as_bytes());
        p.push(0);
        p.extend_from_slice(&result.to_le_bytes());
        p
    }

    #[test]
    fn invites_one_at_a_time_and_waits_for_confirmation() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert_eq!(
            seq.next_action(0),
            Action::SendInvite { index: 0, name: "Smokinpole".into() }
        );
        // No second invite while the first is unconfirmed.
        assert_eq!(seq.next_action(350), Action::Wait);
        assert_eq!(seq.next_action(5_000), Action::Wait);
        assert_eq!(seq.state_of("smokinpole"), Some(MemberState::InviteSent));
        assert_eq!(seq.state_of("Winterone"), Some(MemberState::Waiting));
    }

    #[test]
    fn full_sequence_reaches_done() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { index: 0, .. }));
        seq.on_group_list(&list(&["Smokinpole"]));
        assert_eq!(seq.state_of("Smokinpole"), Some(MemberState::AcceptObserved));
        assert!(matches!(seq.next_action(1_000), Action::SendInvite { index: 1, .. }));
        assert_eq!(seq.state_of("Smokinpole"), Some(MemberState::RosterConfirmed));
        seq.on_group_list(&list(&["Smokinpole", "Winterone"]));
        assert!(matches!(seq.next_action(2_000), Action::SendInvite { index: 2, .. }));
        seq.on_group_list(&list(&["Smokinpole", "Winterone", "Wintertwoo"]));
        assert_eq!(seq.next_action(3_000), Action::Done);
        assert!(seq.is_complete());
    }

    #[test]
    fn group_list_is_case_insensitive() {
        let mut seq = PartySeq::new(&list(&["Smokinpole"]), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { .. }));
        seq.on_group_list(&list(&["SMOKINPOLE"]));
        assert_eq!(seq.next_action(10), Action::Done);
    }

    #[test]
    fn timeout_fails_closed_without_reinvite() {
        let mut seq = PartySeq::new(&names(), 10_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { index: 0, .. }));
        seq.on_group_list(&list(&["Smokinpole"]));
        assert!(matches!(seq.next_action(500), Action::SendInvite { index: 1, .. }));
        // Winterone never shows up (the observed live failure).
        assert_eq!(seq.next_action(9_000), Action::Wait);
        match seq.next_action(10_500) {
            Action::Fail(FailReason::Timeout { member, waited_ms }) => {
                assert_eq!(member, "Winterone");
                assert_eq!(waited_ms, 10_000);
            }
            other => panic!("expected timeout, got {other:?}"),
        }
        // Stays failed; Wintertwoo is never invited.
        assert!(matches!(seq.next_action(20_000), Action::Fail(_)));
        assert_eq!(seq.state_of("Wintertwoo"), Some(MemberState::Waiting));
    }

    #[test]
    fn invite_is_never_issued_twice_for_the_same_member() {
        let mut seq = PartySeq::new(&list(&["A", "B"]), 60_000);
        let mut sends = 0;
        for tick in 0..50u64 {
            if let Action::SendInvite { .. } = seq.next_action(tick * 100) {
                sends += 1;
            }
        }
        assert_eq!(sends, 1);
    }

    #[test]
    fn server_reject_is_classified() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { .. }));
        seq.on_group_list(&list(&["Smokinpole"]));
        assert!(matches!(seq.next_action(100), Action::SendInvite { index: 1, .. }));
        let parsed = seq
            .on_party_command_result(&result_payload(0, "Winterone", 4))
            .unwrap();
        assert_eq!(parsed.result, 4);
        assert_eq!(seq.state_of("Winterone"), Some(MemberState::ServerReject));
        match seq.next_action(200) {
            Action::Fail(FailReason::ServerReject { member, detail }) => {
                assert_eq!(member, "Winterone");
                assert!(detail.contains("ALREADY_IN_GROUP"), "{detail}");
            }
            other => panic!("expected reject, got {other:?}"),
        }
    }

    #[test]
    fn ok_result_only_acks_and_keeps_waiting() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { .. }));
        seq.on_party_command_result(&result_payload(0, "Smokinpole", 0)).unwrap();
        assert_eq!(seq.state_of("Smokinpole"), Some(MemberState::InviteSent));
        assert_eq!(seq.next_action(10), Action::Wait);
        assert!(seq.report()[0].contains("invite_acked=true"));
    }

    #[test]
    fn non_invite_operations_and_unknown_names_are_ignored() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { .. }));
        seq.on_party_command_result(&result_payload(2, "Smokinpole", 6)).unwrap();
        seq.on_party_command_result(&result_payload(0, "Nobody", 1)).unwrap();
        assert_eq!(seq.next_action(10), Action::Wait);
        assert!(seq.failure().is_none());
    }

    #[test]
    fn decline_is_classified() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { .. }));
        let mut payload = b"Smokinpole".to_vec();
        payload.push(0);
        assert_eq!(seq.on_group_decline(&payload).unwrap(), "Smokinpole");
        assert!(matches!(
            seq.next_action(10),
            Action::Fail(FailReason::ServerReject { .. })
        ));
    }

    #[test]
    fn member_already_in_roster_is_not_reinvited() {
        let mut seq = PartySeq::new(&list(&["A", "B"]), 30_000);
        seq.on_group_list(&list(&["A"]));
        assert!(matches!(seq.next_action(0), Action::SendInvite { index: 1, .. }));
        assert_eq!(seq.state_of("A"), Some(MemberState::RosterConfirmed));
    }

    #[test]
    fn confirmed_member_leaving_fails_closed() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { .. }));
        seq.on_group_list(&list(&["Smokinpole"]));
        assert!(matches!(seq.next_action(10), Action::SendInvite { index: 1, .. }));
        seq.on_group_list(&list(&[]));
        assert!(matches!(
            seq.next_action(20),
            Action::Fail(FailReason::MemberLost { .. })
        ));
    }

    #[test]
    fn uncertain_write_fails_closed() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(matches!(seq.next_action(0), Action::SendInvite { index: 0, .. }));
        assert!(matches!(
            seq.on_write_uncertain(0),
            Action::Fail(FailReason::WriteUncertain { .. })
        ));
        assert!(matches!(seq.next_action(1), Action::Fail(_)));
    }

    #[test]
    fn short_or_bad_payloads_do_not_panic() {
        let mut seq = PartySeq::new(&names(), 30_000);
        assert!(seq.on_party_command_result(&[1, 2, 3]).is_err());
        assert!(seq.on_group_decline(b"no-nul").is_err());
        assert!(parse_party_command_result(&result_payload(0, "X", 0)[..8]).is_err());
    }
}
