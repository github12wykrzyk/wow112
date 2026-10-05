use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StationId {
    Hyjal,
    Winterspring,
    Hydraxian,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StationOwnership {
    pub station: StationId,
    pub player: String,
    pub request_seq: u64,
    pub acquired_at_s: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AcquireResult {
    Acquired(StationOwnership),
    Idempotent(StationOwnership),
    Conflict {
        existing: StationOwnership,
        requested_station: StationId,
        requested_seq: u64,
    },
}

#[derive(Debug, Default)]
pub struct StationOwnershipRegistry {
    by_player: HashMap<String, StationOwnership>,
}

impl StationOwnershipRegistry {
    fn key(player: &str) -> String {
        player.trim().to_ascii_lowercase()
    }

    pub fn owner(&self, player: &str) -> Option<&StationOwnership> {
        self.by_player.get(&Self::key(player))
    }

    pub fn acquire(
        &mut self,
        station: StationId,
        player: &str,
        request_seq: u64,
        now_s: u64,
    ) -> Result<AcquireResult, String> {
        let player = player.trim();
        if player.is_empty() {
            return Err("ownership player must not be empty".to_string());
        }
        if request_seq == 0 {
            return Err("ownership request_seq must be > 0".to_string());
        }
        let key = Self::key(player);
        if let Some(existing) = self.by_player.get(&key).cloned() {
            if existing.station == station && existing.request_seq == request_seq {
                return Ok(AcquireResult::Idempotent(existing));
            }
            return Ok(AcquireResult::Conflict {
                existing,
                requested_station: station,
                requested_seq: request_seq,
            });
        }

        let ownership = StationOwnership {
            station,
            player: player.to_string(),
            request_seq,
            acquired_at_s: now_s,
        };
        self.by_player.insert(key, ownership.clone());
        Ok(AcquireResult::Acquired(ownership))
    }

    pub fn release_exact(
        &mut self,
        station: StationId,
        player: &str,
        request_seq: u64,
    ) -> bool {
        let key = Self::key(player);
        let matches = self
            .by_player
            .get(&key)
            .map(|entry| entry.station == station && entry.request_seq == request_seq)
            .unwrap_or(false);
        if matches {
            self.by_player.remove(&key);
        }
        matches
    }

    /// Station changes are explicit. A destination reclassification cannot silently
    /// steal ownership from another station or from an older active request.
    pub fn transfer_exact(
        &mut self,
        player: &str,
        request_seq: u64,
        from: StationId,
        to: StationId,
        now_s: u64,
    ) -> Result<StationOwnership, String> {
        if from == to {
            return Err("ownership transfer requires a different station".to_string());
        }
        let key = Self::key(player);
        let existing = self
            .by_player
            .get(&key)
            .cloned()
            .ok_or_else(|| format!("no ownership for {player}"))?;
        if existing.station != from || existing.request_seq != request_seq {
            return Err(format!(
                "ownership lease mismatch for {player}: existing={existing:?}"
            ));
        }
        let moved = StationOwnership {
            station: to,
            player: existing.player,
            request_seq,
            acquired_at_s: now_s,
        };
        self.by_player.insert(key, moved.clone());
        Ok(moved)
    }

    pub fn len(&self) -> usize {
        self.by_player.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_station_cannot_steal_player() {
        let mut registry = StationOwnershipRegistry::default();
        assert!(matches!(
            registry.acquire(StationId::Hyjal, "Customer", 1, 100).unwrap(),
            AcquireResult::Acquired(_)
        ));
        let conflict = registry
            .acquire(StationId::Winterspring, "customer", 1, 101)
            .unwrap();
        assert!(matches!(conflict, AcquireResult::Conflict { .. }));
        assert_eq!(registry.owner("CUSTOMER").unwrap().station, StationId::Hyjal);
    }

    #[test]
    fn same_request_same_station_is_idempotent() {
        let mut registry = StationOwnershipRegistry::default();
        registry.acquire(StationId::Hydraxian, "Customer", 7, 100).unwrap();
        assert!(matches!(
            registry.acquire(StationId::Hydraxian, "customer", 7, 999).unwrap(),
            AcquireResult::Idempotent(_)
        ));
        assert_eq!(registry.len(), 1);
    }

    #[test]
    fn transfer_requires_exact_existing_lease() {
        let mut registry = StationOwnershipRegistry::default();
        registry.acquire(StationId::Hyjal, "Customer", 1, 100).unwrap();
        assert!(registry
            .transfer_exact("Customer", 2, StationId::Hyjal, StationId::Winterspring, 110)
            .is_err());
        let moved = registry
            .transfer_exact("Customer", 1, StationId::Hyjal, StationId::Winterspring, 111)
            .unwrap();
        assert_eq!(moved.station, StationId::Winterspring);
    }
}
