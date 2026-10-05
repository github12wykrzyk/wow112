#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupMemberSnapshot {
    pub name: String,
    pub guid: u64,
    pub is_online: bool,
    pub flags: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupSnapshot {
    pub leader_guid: u64,
    pub members: Vec<GroupMemberSnapshot>,
}

impl GroupSnapshot {
    fn canonicalized(mut self) -> Self {
        self.members.sort_by(|a, b| {
            a.guid
                .cmp(&b.guid)
                .then_with(|| a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase()))
        });
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RosterTransition {
    Unchanged { epoch: u64 },
    Changed { epoch: u64 },
    Destroyed { epoch: u64 },
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RosterState {
    epoch: u64,
    snapshot: Option<GroupSnapshot>,
}

impl RosterState {
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    pub fn snapshot(&self) -> Option<&GroupSnapshot> {
        self.snapshot.as_ref()
    }

    pub fn is_grouped(&self) -> bool {
        self.snapshot.is_some()
    }

    pub fn apply_snapshot(&mut self, snapshot: GroupSnapshot) -> RosterTransition {
        let snapshot = snapshot.canonicalized();
        if self.snapshot.as_ref() == Some(&snapshot) {
            return RosterTransition::Unchanged { epoch: self.epoch };
        }

        self.epoch = self.epoch.saturating_add(1);
        self.snapshot = Some(snapshot);
        RosterTransition::Changed { epoch: self.epoch }
    }

    pub fn destroy_group(&mut self) -> RosterTransition {
        if self.snapshot.is_none() {
            return RosterTransition::Unchanged { epoch: self.epoch };
        }
        self.epoch = self.epoch.saturating_add(1);
        self.snapshot = None;
        RosterTransition::Destroyed { epoch: self.epoch }
    }

    pub fn contains_name(&self, player: &str) -> bool {
        let wanted = player.trim();
        if wanted.is_empty() {
            return false;
        }
        self.snapshot
            .as_ref()
            .map(|snapshot| {
                snapshot
                    .members
                    .iter()
                    .any(|member| member.name.eq_ignore_ascii_case(wanted))
            })
            .unwrap_or(false)
    }

    pub fn contains_guid(&self, guid: u64) -> bool {
        self.snapshot
            .as_ref()
            .map(|snapshot| snapshot.members.iter().any(|member| member.guid == guid))
            .unwrap_or(false)
    }

    pub fn leader_guid(&self) -> Option<u64> {
        self.snapshot.as_ref().map(|snapshot| snapshot.leader_guid)
    }

    pub fn leader_name(&self) -> Option<&str> {
        let snapshot = self.snapshot.as_ref()?;
        snapshot
            .members
            .iter()
            .find(|member| member.guid == snapshot.leader_guid)
            .map(|member| member.name.as_str())
    }

    pub fn is_leader_name(&self, player: &str) -> bool {
        self.leader_name()
            .map(|name| name.eq_ignore_ascii_case(player.trim()))
            .unwrap_or(false)
    }

    /// Group membership is proven only by an observed roster snapshot.
    /// A PARTY_COMMAND_RESULT Success must never call this method indirectly.
    pub fn confirms_membership(&self, player: &str) -> bool {
        self.contains_name(player)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn member(name: &str, guid: u64) -> GroupMemberSnapshot {
        GroupMemberSnapshot {
            name: name.to_string(),
            guid,
            is_online: true,
            flags: 0,
        }
    }

    #[test]
    fn only_roster_snapshot_confirms_membership() {
        let mut roster = RosterState::default();
        assert!(!roster.confirms_membership("Customer"));
        roster.apply_snapshot(GroupSnapshot {
            leader_guid: 1,
            members: vec![member("Warlock", 1), member("Customer", 2)],
        });
        assert!(roster.confirms_membership("customer"));
    }

    #[test]
    fn duplicate_snapshot_is_idempotent_even_if_member_order_differs() {
        let mut roster = RosterState::default();
        assert_eq!(
            roster.apply_snapshot(GroupSnapshot {
                leader_guid: 1,
                members: vec![member("Warlock", 1), member("Customer", 2)],
            }),
            RosterTransition::Changed { epoch: 1 }
        );
        assert_eq!(
            roster.apply_snapshot(GroupSnapshot {
                leader_guid: 1,
                members: vec![member("Customer", 2), member("Warlock", 1)],
            }),
            RosterTransition::Unchanged { epoch: 1 }
        );
    }

    #[test]
    fn leader_change_advances_epoch() {
        let mut roster = RosterState::default();
        roster.apply_snapshot(GroupSnapshot {
            leader_guid: 1,
            members: vec![member("Warlock", 1), member("Helper", 2)],
        });
        assert!(roster.is_leader_name("Warlock"));
        assert_eq!(
            roster.apply_snapshot(GroupSnapshot {
                leader_guid: 2,
                members: vec![member("Warlock", 1), member("Helper", 2)],
            }),
            RosterTransition::Changed { epoch: 2 }
        );
        assert!(roster.is_leader_name("helper"));
    }

    #[test]
    fn destroyed_group_clears_all_membership() {
        let mut roster = RosterState::default();
        roster.apply_snapshot(GroupSnapshot {
            leader_guid: 1,
            members: vec![member("Warlock", 1), member("Customer", 2)],
        });
        assert_eq!(roster.destroy_group(), RosterTransition::Destroyed { epoch: 2 });
        assert!(!roster.is_grouped());
        assert!(!roster.contains_name("Customer"));
        assert_eq!(roster.destroy_group(), RosterTransition::Unchanged { epoch: 2 });
    }
}
