use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LeaderCandidate {
    pub name: String,
    pub online: bool,
}

#[derive(Debug, Clone)]
pub struct LeaderPolicy {
    preferred_order: Vec<String>,
    allowed: HashSet<String>,
}

impl LeaderPolicy {
    pub fn new(preferred_order: Vec<String>) -> Result<Self, String> {
        let mut normalized = Vec::new();
        let mut allowed = HashSet::new();
        for raw in preferred_order {
            let name = raw.trim().to_ascii_lowercase();
            if name.is_empty() {
                continue;
            }
            if allowed.insert(name.clone()) {
                normalized.push(name);
            }
        }
        if normalized.is_empty() {
            return Err("leader policy needs at least one allowed service character".to_string());
        }
        Ok(Self {
            preferred_order: normalized,
            allowed,
        })
    }

    pub fn is_allowed_leader(&self, name: &str) -> bool {
        self.allowed.contains(&name.trim().to_ascii_lowercase())
    }

    /// Returns None when the current observed leader is already an allowed service
    /// character. Otherwise returns the first online preferred service character
    /// present in the observed roster. This function never performs the transfer.
    pub fn desired_transfer_target<'a>(
        &self,
        current_leader: Option<&str>,
        present: &'a [LeaderCandidate],
    ) -> Option<&'a str> {
        if current_leader
            .map(|name| self.is_allowed_leader(name))
            .unwrap_or(false)
        {
            return None;
        }

        for preferred in &self.preferred_order {
            if let Some(candidate) = present.iter().find(|candidate| {
                candidate.online && candidate.name.eq_ignore_ascii_case(preferred)
            }) {
                return Some(candidate.name.as_str());
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(name: &str, online: bool) -> LeaderCandidate {
        LeaderCandidate {
            name: name.to_string(),
            online,
        }
    }

    #[test]
    fn keeps_allowed_current_leader() {
        let policy = LeaderPolicy::new(vec!["teletanaris".into(), "bolthyjal".into()]).unwrap();
        let present = vec![c("Teletanaris", true), c("Customer", true)];
        assert_eq!(policy.desired_transfer_target(Some("TELETANARIS"), &present), None);
    }

    #[test]
    fn replaces_customer_or_level_one_leader_with_first_present_service_character() {
        let policy = LeaderPolicy::new(vec![
            "teletanaris".into(),
            "bolthyjal".into(),
            "feltaxi".into(),
        ])
        .unwrap();
        let present = vec![
            c("Customer", true),
            c("Bolthyjal", true),
            c("Feltaxi", true),
        ];
        assert_eq!(
            policy.desired_transfer_target(Some("Customer"), &present),
            Some("Bolthyjal")
        );
    }

    #[test]
    fn skips_offline_preferred_candidate() {
        let policy = LeaderPolicy::new(vec!["teletanaris".into(), "feltaxi".into()]).unwrap();
        let present = vec![c("Teletanaris", false), c("Feltaxi", true)];
        assert_eq!(
            policy.desired_transfer_target(Some("Customer"), &present),
            Some("Feltaxi")
        );
    }

    #[test]
    fn no_candidate_means_fail_closed_not_arbitrary_leader() {
        let policy = LeaderPolicy::new(vec!["teletanaris".into()]).unwrap();
        let present = vec![c("Customer", true), c("Helper", true)];
        assert_eq!(policy.desired_transfer_target(Some("Customer"), &present), None);
    }
}
