//! TELE10 guarded clarification fallback for ambiguous operational whispers.
//!
//! The base whisper parser intentionally remains stateless and conservative.
//! This gate adds a short-lived per-sender conversation state so an ambiguous
//! operational message may be clarified without widening fuzzy matching or
//! turning a bare confirmation into an action outside that context.

use std::collections::BTreeMap;

use crate::tele08_whisper_parser::{
    normalize_whisper_text, DestinationKey, WhisperClassification, WhisperIntent,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClarificationConfig {
    pub timeout_ms: u64,
    pub reprompt_cooldown_ms: u64,
}

impl Default for ClarificationConfig {
    fn default() -> Self {
        Self {
            timeout_ms: 45_000,
            reprompt_cooldown_ms: 60_000,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingClarification {
    pub sender: String,
    pub destination: Option<DestinationKey>,
    pub created_ms: u64,
    pub expires_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClarificationDecision {
    /// No clarification-specific handling; preserve the original classification.
    PassThrough,
    /// Send exactly one clarification prompt and wait for a bounded reply.
    Prompt {
        recipient: String,
        text: String,
        destination: Option<DestinationKey>,
    },
    /// A reply confirmed a pending clarification. This synthetic classification
    /// is safe to feed into the existing B->C admission path.
    Confirmed(WhisperClassification),
    /// Explicit negative reply closed the pending clarification.
    Declined,
    /// The message stays non-actionable and no repeated clarification is sent.
    Suppressed,
}

#[derive(Debug, Clone)]
pub struct ClarificationGate {
    config: ClarificationConfig,
    pending: BTreeMap<String, PendingClarification>,
    last_prompt_ms: BTreeMap<String, u64>,
}

impl Default for ClarificationGate {
    fn default() -> Self {
        Self::new(ClarificationConfig::default())
    }
}

impl ClarificationGate {
    pub fn new(config: ClarificationConfig) -> Self {
        Self {
            config,
            pending: BTreeMap::new(),
            last_prompt_ms: BTreeMap::new(),
        }
    }

    pub fn process(&mut self, classification: &WhisperClassification) -> ClarificationDecision {
        let sender_key = sender_key(&classification.sender);
        if sender_key.is_empty() {
            return ClarificationDecision::PassThrough;
        }

        self.expire_sender(&sender_key, classification.timestamp_ms);

        if let Some(pending) = self.pending.get(&sender_key).cloned() {
            if classification.intent == WhisperIntent::CompetitionMessage {
                self.pending.remove(&sender_key);
                return ClarificationDecision::PassThrough;
            }

            if is_confirmation(&classification.normalized_text) {
                self.pending.remove(&sender_key);
                return ClarificationDecision::Confirmed(confirmed_classification(
                    classification,
                    pending.destination,
                ));
            }

            if is_decline(&classification.normalized_text) {
                self.pending.remove(&sender_key);
                return ClarificationDecision::Declined;
            }

            if is_explicit_action(&classification.intent) {
                self.pending.remove(&sender_key);
                return ClarificationDecision::PassThrough;
            }

            if is_clarifiable_unknown(classification) {
                return ClarificationDecision::Suppressed;
            }

            return ClarificationDecision::PassThrough;
        }

        if !is_clarifiable_unknown(classification) {
            return ClarificationDecision::PassThrough;
        }

        if self.cooldown_active(&sender_key, classification.timestamp_ms) {
            return ClarificationDecision::Suppressed;
        }

        let pending = PendingClarification {
            sender: classification.sender.clone(),
            destination: classification.destination.clone(),
            created_ms: classification.timestamp_ms,
            expires_ms: classification
                .timestamp_ms
                .saturating_add(self.config.timeout_ms),
        };
        let text = clarification_text(pending.destination.as_ref());
        self.last_prompt_ms
            .insert(sender_key.clone(), classification.timestamp_ms);
        self.pending.insert(sender_key, pending.clone());

        ClarificationDecision::Prompt {
            recipient: classification.sender.clone(),
            text,
            destination: pending.destination,
        }
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    pub fn pending_for(&self, sender: &str) -> Option<&PendingClarification> {
        self.pending.get(&sender_key(sender))
    }

    fn expire_sender(&mut self, sender_key: &str, now_ms: u64) {
        let expired = self
            .pending
            .get(sender_key)
            .map(|pending| now_ms > pending.expires_ms)
            .unwrap_or(false);
        if expired {
            self.pending.remove(sender_key);
        }
    }

    fn cooldown_active(&self, sender_key: &str, now_ms: u64) -> bool {
        self.last_prompt_ms
            .get(sender_key)
            .map(|last| now_ms.saturating_sub(*last) < self.config.reprompt_cooldown_ms)
            .unwrap_or(false)
    }
}

fn sender_key(sender: &str) -> String {
    normalize_whisper_text(sender)
}

fn is_clarifiable_unknown(classification: &WhisperClassification) -> bool {
    classification.intent == WhisperIntent::Unknown
        && classification.reason == "operational_hint_below_action_threshold"
}

fn is_explicit_action(intent: &WhisperIntent) -> bool {
    matches!(
        intent,
        WhisperIntent::SummonRequest
            | WhisperIntent::InviteRequest
            | WhisperIntent::GenericPositive
    )
}

fn is_confirmation(text: &str) -> bool {
    matches!(
        text,
        "+"
            | "y"
            | "yes"
            | "yea"
            | "yeah"
            | "yep"
            | "yup"
            | "sure"
            | "ok"
            | "okay"
            | "pls"
            | "please"
            | "yes pls"
            | "yes please"
            | "ofc"
    )
}

fn is_decline(text: &str) -> bool {
    matches!(text, "n" | "no" | "nope" | "nah" | "not now")
}

fn clarification_text(destination: Option<&DestinationKey>) -> String {
    match destination.map(|destination| destination.0.as_str()) {
        Some("hyjal") => "Do you want a summon to Hyjal?".into(),
        Some("winterspring") => "Do you want a summon to Winterspring?".into(),
        Some("azshara") => "Do you want a summon to Azshara?".into(),
        Some(other) if !other.is_empty() => format!("Do you want a summon to {other}?"),
        _ => "Do you want a summon?".into(),
    }
}

fn confirmed_classification(
    reply: &WhisperClassification,
    destination: Option<DestinationKey>,
) -> WhisperClassification {
    let mut signals = reply.signals.clone();
    signals.push("clarification_confirmed".into());
    WhisperClassification {
        sender: reply.sender.clone(),
        raw_text: reply.raw_text.clone(),
        normalized_text: reply.normalized_text.clone(),
        timestamp_ms: reply.timestamp_ms,
        intent: WhisperIntent::SummonRequest,
        destination: destination.or_else(|| reply.destination.clone()),
        confidence: 97,
        signals,
        reason: "clarification_confirmed".into(),
    }
}
