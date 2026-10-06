//! TELE08 Track B: deterministic, side-effect-free whisper classification.

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhisperObservation {
    pub sender: String,
    pub text: String,
    pub timestamp_ms: u64,
    pub source_role: Option<String>,
    pub destination_context: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum WhisperIntent {
    SummonRequest,
    InviteRequest,
    PresenceReady,
    DestinationQuery,
    GenericPositive,
    CompetitionMessage,
    Irrelevant,
    Unknown,
}

impl WhisperIntent {
    fn stable_name(&self) -> &'static str {
        match self {
            Self::SummonRequest => "SummonRequest",
            Self::InviteRequest => "InviteRequest",
            Self::PresenceReady => "PresenceReady",
            Self::DestinationQuery => "DestinationQuery",
            Self::GenericPositive => "GenericPositive",
            Self::CompetitionMessage => "CompetitionMessage",
            Self::Irrelevant => "Irrelevant",
            Self::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DestinationKey(pub String);
impl DestinationKey { pub fn new(value: impl Into<String>) -> Self { Self(value.into()) } }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhisperClassification {
    pub sender: String,
    pub raw_text: String,
    pub normalized_text: String,
    pub timestamp_ms: u64,
    pub intent: WhisperIntent,
    pub destination: Option<DestinationKey>,
    pub confidence: u8,
    pub signals: Vec<String>,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DestinationAlias { pub alias: String, pub key: DestinationKey }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FuzzyRule {
    pub canonical: String,
    pub intent: WhisperIntent,
    pub max_distance: usize,
    pub max_input_len: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParserConfig {
    pub positive_phrases: Vec<String>,
    pub invite_aliases: Vec<String>,
    pub presence_phrases: Vec<String>,
    pub destination_aliases: Vec<DestinationAlias>,
    pub competition_patterns: Vec<String>,
    pub fuzzy_rules: Vec<FuzzyRule>,
}

fn strings(values: &[&str]) -> Vec<String> { values.iter().map(|v| (*v).to_string()).collect() }

impl Default for ParserConfig {
    fn default() -> Self {
        Self {
            positive_phrases: strings(&["i need one", "need one", "summon me", "sum me", "need summon", "one pls", "one please", "summon pls", "summon please"]),
            invite_aliases: strings(&["inv", "inv pls", "inv please", "inv me", "invite", "invite me", "invite pls", "invite please"]),
            presence_phrases: strings(&["here", "im here", "i m here"]),
            destination_aliases: ["hyjal", "winterspring", "azshara"].iter().map(|name| DestinationAlias { alias: (*name).into(), key: DestinationKey::new(*name) }).collect(),
            competition_patterns: strings(&["selling summons", "selling summon", "wts summon", "wts summons", "our summon service", "i am summoning", "we are summoning"]),
            fuzzy_rules: vec![FuzzyRule { canonical: "inv".into(), intent: WhisperIntent::InviteRequest, max_distance: 1, max_input_len: 4 }],
        }
    }
}

impl ParserConfig {
    pub fn with_destination_alias(mut self, alias: impl Into<String>, key: impl Into<String>) -> Self {
        self.destination_aliases.push(DestinationAlias { alias: alias.into(), key: DestinationKey::new(key) });
        self
    }
}

pub fn normalize_whisper_text(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut gap = false;
    for ch in input.chars().flat_map(char::to_lowercase) {
        if ch.is_alphanumeric() || ch == '+' {
            if gap && !out.is_empty() { out.push(' '); }
            out.push(ch);
            gap = false;
        } else { gap = true; }
    }
    out.trim().to_string()
}

pub fn classify_whisper(observation: &WhisperObservation, config: &ParserConfig) -> WhisperClassification {
    let normalized = normalize_whisper_text(&observation.text);
    let mut signals = Vec::new();
    if normalized.is_empty() {
        return make(observation, normalized, WhisperIntent::Irrelevant, None, 100, signals, "empty_after_normalization");
    }

    let explicit = find_destination(&normalized, config);
    if let Some((alias, key)) = &explicit { signals.push(format!("destination_alias:{alias}->{}", key.0)); }
    let context = if explicit.is_none() {
        observation.destination_context.as_deref().and_then(|value| resolve_destination(value, config)).map(|(alias, key)| {
            signals.push(format!("destination_context:{alias}->{}", key.0));
            key
        })
    } else { None };
    let destination = explicit.as_ref().map(|(_, key)| key.clone()).or(context);

    if let Some(pattern) = competition_match(&normalized, config) {
        signals.push(format!("competition_pattern:{pattern}"));
        return make(observation, normalized, WhisperIntent::CompetitionMessage, destination, 96, signals, "configured_competition_pattern");
    }
    if exact(&normalized, &config.presence_phrases) {
        signals.push(format!("presence_phrase:{normalized}"));
        return make(observation, normalized, WhisperIntent::PresenceReady, destination, 99, signals, "exact_presence_phrase");
    }
    if destination_query(&normalized) {
        if destination.is_some() { signals.push("destination_query:configured".into()); }
        else if let Some(candidate) = unknown_destination_candidate(&normalized) { signals.push(format!("destination_query:unconfigured_candidate:{candidate}")); }
        else { signals.push("destination_query:no_configured_match".into()); }
        return make(observation, normalized, WhisperIntent::DestinationQuery, destination, 92, signals, "destination_question_shape");
    }
    if observation.text.trim_start().starts_with('+') {
        signals.push("leading_plus".into());
        return make(observation, normalized, WhisperIntent::GenericPositive, destination, 98, signals, "leading_plus_request_signal");
    }
    if exact(&normalized, &config.invite_aliases) {
        signals.push(format!("invite_alias:{normalized}"));
        return make(observation, normalized, WhisperIntent::InviteRequest, destination, 99, signals, "exact_invite_alias");
    }
    if let Some((candidate, canonical, distance, intent)) = bounded_fuzzy(&normalized, config) {
        signals.push(format!("fuzzy:{candidate}->{canonical}:distance={distance}"));
        return make(observation, normalized, intent, destination, 90, signals, "bounded_short_operational_fuzzy_match");
    }
    if exact(&normalized, &config.positive_phrases) {
        signals.push(format!("positive_phrase:{normalized}"));
        return make(observation, normalized, WhisperIntent::SummonRequest, destination, 98, signals, "exact_positive_phrase");
    }
    if let Some((alias, _)) = explicit.as_ref() {
        if destination_request_envelope(&normalized, alias) {
            signals.push(format!("destination_request_envelope:{alias}"));
            return make(observation, normalized, WhisperIntent::SummonRequest, destination, 95, signals, "configured_destination_request");
        }
    }
    if operationally_ambiguous(&normalized) {
        signals.push("operational_hint_without_safe_match".into());
        return make(observation, normalized, WhisperIntent::Unknown, destination, 35, signals, "operational_hint_below_action_threshold");
    }
    make(observation, normalized, WhisperIntent::Irrelevant, destination, 92, signals, "no_operational_signal")
}

pub fn request_fingerprint(c: &WhisperClassification) -> String {
    let destination = c.destination.as_ref().map(|v| v.0.as_str()).unwrap_or("");
    let canonical = format!("{}\u{1f}{}\u{1f}{}\u{1f}{}", normalize_whisper_text(&c.sender), c.normalized_text, c.intent.stable_name(), destination);
    format!("{:016x}", fnv1a64(canonical.as_bytes()))
}

pub fn destination_alias_map(config: &ParserConfig) -> BTreeMap<String, DestinationKey> {
    config.destination_aliases.iter().map(|e| (normalize_whisper_text(&e.alias), e.key.clone())).collect()
}

fn make(o: &WhisperObservation, normalized_text: String, intent: WhisperIntent, destination: Option<DestinationKey>, confidence: u8, signals: Vec<String>, reason: &str) -> WhisperClassification {
    WhisperClassification { sender: o.sender.clone(), raw_text: o.text.clone(), normalized_text, timestamp_ms: o.timestamp_ms, intent, destination, confidence, signals, reason: reason.into() }
}

fn exact(text: &str, values: &[String]) -> bool { values.iter().any(|v| text == normalize_whisper_text(v)) }

fn contains_phrase(text: &str, phrase: &str) -> bool {
    let text_tokens: Vec<&str> = text.split_whitespace().collect();
    let phrase_tokens: Vec<&str> = phrase.split_whitespace().collect();
    !phrase_tokens.is_empty() && phrase_tokens.len() <= text_tokens.len() && text_tokens.windows(phrase_tokens.len()).any(|w| w == phrase_tokens.as_slice())
}

fn find_destination(text: &str, config: &ParserConfig) -> Option<(String, DestinationKey)> {
    let mut best: Option<(String, DestinationKey)> = None;
    for entry in &config.destination_aliases {
        let alias = normalize_whisper_text(&entry.alias);
        if alias.is_empty() || !contains_phrase(text, &alias) { continue; }
        let replace = best.as_ref().map(|(old, _)| alias.len() > old.len() || (alias.len() == old.len() && alias.as_str() < old.as_str())).unwrap_or(true);
        if replace { best = Some((alias, entry.key.clone())); }
    }
    best
}

fn resolve_destination(value: &str, config: &ParserConfig) -> Option<(String, DestinationKey)> {
    let value = normalize_whisper_text(value);
    config.destination_aliases.iter().find_map(|entry| {
        let alias = normalize_whisper_text(&entry.alias);
        (alias == value).then(|| (alias, entry.key.clone()))
    })
}

fn competition_match(text: &str, config: &ParserConfig) -> Option<String> {
    config.competition_patterns.iter().find_map(|value| {
        let pattern = normalize_whisper_text(value);
        (!pattern.is_empty() && contains_phrase(text, &pattern)).then_some(pattern)
    })
}

fn destination_query(text: &str) -> bool {
    ["do you have ", "have you got ", "can you do ", "can i get ", "got ", "any destination", "any destinations", "where can ", "where to ", "what destination", "what destinations", "what locations", "which destination", "which destinations", "which locations"]
        .iter().any(|prefix| text.starts_with(prefix))
}

fn unknown_destination_candidate(text: &str) -> Option<String> {
    const STOP: &[&str] = &["do", "you", "have", "got", "can", "i", "get", "any", "where", "is", "to", "what", "which", "destinations", "destination", "locations", "location", "pls", "please", "a", "an", "the", "for", "summon", "summons"];
    text.split_whitespace().filter(|token| !STOP.contains(token) && *token != "+").next_back().map(str::to_string)
}

fn destination_request_envelope(text: &str, alias: &str) -> bool {
    const ALLOWED: &[&str] = &["pls", "please", "summon", "sum", "inv", "invite", "me", "one", "need", "to", "for"];
    let tokens: Vec<&str> = text.split_whitespace().collect();
    let dest: Vec<&str> = alias.split_whitespace().collect();
    if dest.is_empty() || dest.len() > tokens.len() { return false; }
    for start in 0..=tokens.len() - dest.len() {
        if tokens[start..start + dest.len()] == dest[..] {
            return tokens[..start].iter().chain(tokens[start + dest.len()..].iter()).all(|token| ALLOWED.contains(token));
        }
    }
    false
}

fn bounded_fuzzy(text: &str, config: &ParserConfig) -> Option<(String, String, usize, WhisperIntent)> {
    let tokens: Vec<&str> = text.split_whitespace().collect();
    if tokens.is_empty() || tokens.len() > 3 { return None; }
    if tokens.len() > 1 && !tokens[1..].iter().all(|token| matches!(*token, "pls" | "please" | "me" | "now" | "ty")) { return None; }
    let candidate = tokens[0];
    for rule in &config.fuzzy_rules {
        let canonical = normalize_whisper_text(&rule.canonical);
        if canonical.is_empty() || candidate.len() > rule.max_input_len || candidate.chars().next() != canonical.chars().next() { continue; }
        let distance = levenshtein(candidate, &canonical);
        if distance > 0 && distance <= rule.max_distance { return Some((candidate.into(), canonical, distance, rule.intent.clone())); }
    }
    None
}

fn operationally_ambiguous(text: &str) -> bool {
    const HINTS: &[&str] = &["summ", "sumon", "summon", "port", "tele", "inv", "ritual"];
    text.split_whitespace().any(|token| HINTS.iter().any(|hint| token == *hint || (token.starts_with(hint) && token.len() <= hint.len() + 2)))
}

fn levenshtein(a: &str, b: &str) -> usize {
    if a == b { return 0; }
    let b_chars: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b_chars.len()).collect();
    let mut curr = vec![0; b_chars.len() + 1];
    for (i, ac) in a.chars().enumerate() {
        curr[0] = i + 1;
        for (j, bc) in b_chars.iter().enumerate() {
            curr[j + 1] = (prev[j] + usize::from(ac != *bc)).min(curr[j] + 1).min(prev[j + 1] + 1);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[b_chars.len()]
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf29ce484222325;
    const PRIME: u64 = 0x100000001b3;
    bytes.iter().fold(OFFSET, |hash, byte| (hash ^ u64::from(*byte)).wrapping_mul(PRIME))
}
