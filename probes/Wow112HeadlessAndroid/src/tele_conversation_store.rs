use std::collections::HashMap;

use crate::tele_conversation::{ConversationContext, ConversationPhase, Destination};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlayerConversation {
    pub player: String,
    pub context: ConversationContext,
    pub created_at_s: u64,
    pub updated_at_s: u64,
    pub expires_at_s: u64,
    pub manual_lock_until_s: u64,
    pub request_seq: u64,
}

impl PlayerConversation {
    pub fn manual_locked(&self, now_s: u64) -> bool {
        now_s < self.manual_lock_until_s
    }

    pub fn expired(&self, now_s: u64) -> bool {
        now_s >= self.expires_at_s
    }
}

#[derive(Debug)]
pub struct ConversationStore {
    entries: HashMap<String, PlayerConversation>,
    ttl_s: u64,
    manual_lock_s: u64,
    next_request_seq: u64,
}

impl ConversationStore {
    pub fn new(ttl_s: u64, manual_lock_s: u64) -> Result<Self, String> {
        if ttl_s == 0 {
            return Err("conversation ttl must be > 0".to_string());
        }
        if manual_lock_s == 0 {
            return Err("manual lock duration must be > 0".to_string());
        }
        Ok(Self {
            entries: HashMap::new(),
            ttl_s,
            manual_lock_s,
            next_request_seq: 1,
        })
    }

    fn key(player: &str) -> String {
        player.trim().to_ascii_lowercase()
    }

    pub fn get(&self, player: &str, now_s: u64) -> Option<&PlayerConversation> {
        let entry = self.entries.get(&Self::key(player))?;
        (!entry.expired(now_s)).then_some(entry)
    }

    pub fn touch_destination(
        &mut self,
        player: &str,
        destination: Destination,
        now_s: u64,
    ) -> Result<&PlayerConversation, String> {
        let player = player.trim();
        if player.is_empty() {
            return Err("player must not be empty".to_string());
        }
        let key = Self::key(player);
        let expires_at_s = now_s.saturating_add(self.ttl_s);

        let request_seq = match self.entries.get(&key) {
            Some(entry) if !entry.expired(now_s) => entry.request_seq,
            _ => {
                let seq = self.next_request_seq;
                self.next_request_seq = self.next_request_seq.saturating_add(1);
                seq
            }
        };

        let created_at_s = self
            .entries
            .get(&key)
            .filter(|entry| !entry.expired(now_s))
            .map(|entry| entry.created_at_s)
            .unwrap_or(now_s);
        let manual_lock_until_s = self
            .entries
            .get(&key)
            .filter(|entry| !entry.expired(now_s))
            .map(|entry| entry.manual_lock_until_s)
            .unwrap_or(0);

        self.entries.insert(
            key.clone(),
            PlayerConversation {
                player: player.to_string(),
                context: ConversationContext {
                    destination: Some(destination),
                    phase: ConversationPhase::DestinationKnown,
                },
                created_at_s,
                updated_at_s: now_s,
                expires_at_s,
                manual_lock_until_s,
                request_seq,
            },
        );
        Ok(self.entries.get(&key).unwrap())
    }

    pub fn set_phase(
        &mut self,
        player: &str,
        phase: ConversationPhase,
        now_s: u64,
    ) -> Result<(), String> {
        let key = Self::key(player);
        let entry = self
            .entries
            .get_mut(&key)
            .ok_or_else(|| format!("no active conversation for {player}"))?;
        if entry.expired(now_s) {
            return Err(format!("conversation expired for {player}"));
        }
        entry.context.phase = phase;
        entry.updated_at_s = now_s;
        entry.expires_at_s = now_s.saturating_add(self.ttl_s);
        Ok(())
    }

    pub fn manual_lock(&mut self, player: &str, now_s: u64) -> Result<u64, String> {
        let key = Self::key(player);
        let entry = self
            .entries
            .get_mut(&key)
            .ok_or_else(|| format!("no active conversation for {player}"))?;
        if entry.expired(now_s) {
            return Err(format!("conversation expired for {player}"));
        }
        entry.manual_lock_until_s = now_s.saturating_add(self.manual_lock_s);
        entry.updated_at_s = now_s;
        Ok(entry.manual_lock_until_s)
    }

    pub fn release_manual_lock(&mut self, player: &str) -> bool {
        let Some(entry) = self.entries.get_mut(&Self::key(player)) else {
            return false;
        };
        entry.manual_lock_until_s = 0;
        true
    }

    pub fn automation_allowed(&self, player: &str, now_s: u64) -> bool {
        self.get(player, now_s)
            .map(|entry| !entry.manual_locked(now_s))
            .unwrap_or(false)
    }

    pub fn purge_expired(&mut self, now_s: u64) -> usize {
        let before = self.entries.len();
        self.entries.retain(|_, entry| !entry.expired(now_s));
        before - self.entries.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_lock_blocks_automation_then_expires() {
        let mut store = ConversationStore::new(300, 60).unwrap();
        store.touch_destination("Somebody", Destination::Hyjal, 100).unwrap();
        assert!(store.automation_allowed("somebody", 100));
        assert_eq!(store.manual_lock("Somebody", 110).unwrap(), 170);
        assert!(!store.automation_allowed("SOMEBODY", 169));
        assert!(store.automation_allowed("Somebody", 170));
    }

    #[test]
    fn expired_conversation_gets_new_request_sequence() {
        let mut store = ConversationStore::new(10, 5).unwrap();
        let first = store
            .touch_destination("Somebody", Destination::Hyjal, 100)
            .unwrap()
            .request_seq;
        assert_eq!(store.purge_expired(111), 1);
        let second = store
            .touch_destination("Somebody", Destination::Winterspring, 111)
            .unwrap()
            .request_seq;
        assert!(second > first);
    }

    #[test]
    fn active_conversation_keeps_same_request_sequence() {
        let mut store = ConversationStore::new(300, 60).unwrap();
        let first = store
            .touch_destination("Somebody", Destination::Hyjal, 100)
            .unwrap()
            .request_seq;
        let second = store
            .touch_destination("somebody", Destination::Hyjal, 120)
            .unwrap()
            .request_seq;
        assert_eq!(first, second);
    }
}
