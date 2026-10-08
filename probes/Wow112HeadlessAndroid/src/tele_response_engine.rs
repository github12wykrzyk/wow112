use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub const UNKNOWN_WHISPER_SCHEMA_VERSION: u32 = 1;
pub const DEFAULT_UNKNOWN_WHISPER_PATH: &str = "tele08_unknown_whispers.jsonl";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResponseKind {
    Accepted,
    Queued,
    AlreadyGrouped,
    InCombat,
    UnsupportedDestination,
    DestinationUnavailable,
    SummonStarted,
    SummonCompleted,
    RequestExpired,
    JobFailedSafe,
    Competition,
    Unknown,
}

impl ResponseKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Queued => "queued",
            Self::AlreadyGrouped => "already_grouped",
            Self::InCombat => "in_combat",
            Self::UnsupportedDestination => "unsupported_destination",
            Self::DestinationUnavailable => "destination_unavailable",
            Self::SummonStarted => "summon_started",
            Self::SummonCompleted => "summon_completed",
            Self::RequestExpired => "request_expired",
            Self::JobFailedSafe => "job_failed_safe",
            Self::Competition => "competition",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecisionReason {
    Allowed,
    GlobalCooldown,
    RecipientCooldown,
    ResponseKindCooldown,
    CompetitionCooldown,
    DuplicateTextSuppressed,
    CompetitionDisabled,
    UnknownNoReply,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResponseDecision {
    pub should_send: bool,
    pub recipient: String,
    pub response_kind: ResponseKind,
    pub text: String,
    pub cooldown_key: String,
    pub reason: DecisionReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DestinationUnavailableReason {
    LowShards,
    ManualOffOrMaintenance,
    UnhealthyTeam,
    Temporary,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResponseContext {
    RequestAccepted {
        recipient: String,
        destination: String,
    },
    RequestQueued {
        recipient: String,
        destination: String,
        queue_position: Option<usize>,
        queue_length: Option<usize>,
    },
    AlreadyGrouped {
        recipient: String,
    },
    InCombat {
        recipient: String,
    },
    UnsupportedDestination {
        recipient: String,
        requested_destination: String,
        alternatives: Vec<String>,
    },
    DestinationUnavailable {
        recipient: String,
        destination: String,
        reason: DestinationUnavailableReason,
        alternatives: Vec<String>,
    },
    SummonStarted {
        recipient: String,
        destination: String,
    },
    SummonCompleted {
        recipient: String,
        alternatives: Vec<String>,
    },
    RequestExpired {
        recipient: String,
        timeout_seconds: Option<u64>,
    },
    JobFailedSafe {
        recipient: String,
        retry_seconds: Option<u64>,
    },
    CompetitionMessage {
        recipient: String,
    },
    Unknown {
        recipient: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CooldownConfig {
    pub global_min_interval_secs: Option<u64>,
    pub per_recipient_secs: Option<u64>,
    pub per_response_kind_secs: Option<u64>,
    pub competition_secs: Option<u64>,
    pub duplicate_text_secs: Option<u64>,
}

impl Default for CooldownConfig {
    fn default() -> Self {
        Self {
            global_min_interval_secs: None,
            per_recipient_secs: Some(5),
            per_response_kind_secs: Some(5),
            competition_secs: Some(30),
            duplicate_text_secs: Some(15),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateConfig {
    pub accepted: String,
    pub queued: String,
    pub queued_with_position: String,
    pub queued_with_position_and_length: String,
    pub already_grouped: String,
    pub in_combat: String,
    pub unsupported_with_alternatives: String,
    pub unsupported_without_alternatives: String,
    pub unavailable_low_shards: String,
    pub unavailable_maintenance: String,
    pub unavailable_unhealthy_team: String,
    pub unavailable_temporary: String,
    pub summon_started: String,
    pub summon_completed: String,
    pub summon_completed_with_alternatives: String,
    pub request_expired: String,
    pub request_expired_with_timeout: String,
    pub job_failed_safe: String,
    pub job_failed_safe_with_retry: String,
    pub competition: String,
}

impl Default for TemplateConfig {
    fn default() -> Self {
        Self {
            accepted: "Request accepted for {destination}.".to_string(),
            queued: "Queued for {destination}.".to_string(),
            queued_with_position: "Queued for {destination}. Position: {queue_position}.".to_string(),
            queued_with_position_and_length:
                "Queued for {destination}. Position: {queue_position}/{queue_length}.".to_string(),
            already_grouped: "Please leave your current party so I can summon you.".to_string(),
            in_combat: "You are in combat. Try again when combat ends.".to_string(),
            unsupported_with_alternatives:
                "I don't have {destination}. Available: {alternatives}.".to_string(),
            unsupported_without_alternatives: "I don't have {destination}.".to_string(),
            unavailable_low_shards: "{destination} is temporarily unavailable: low shards.".to_string(),
            unavailable_maintenance: "{destination} is temporarily unavailable.".to_string(),
            unavailable_unhealthy_team: "{destination} is temporarily unavailable.".to_string(),
            unavailable_temporary: "{destination} is temporarily unavailable.".to_string(),
            summon_started: "Summon started for {destination}.".to_string(),
            summon_completed: "Done. Thank you.".to_string(),
            summon_completed_with_alternatives: "Done. Also available: {alternatives}.".to_string(),
            request_expired: "Your summon request expired. Send a new request if needed.".to_string(),
            request_expired_with_timeout:
                "Your summon request expired after {timeout_seconds}s. Send a new request if needed."
                    .to_string(),
            job_failed_safe: "Summon failed temporarily. Please try again.".to_string(),
            job_failed_safe_with_retry:
                "Summon failed temporarily. Please try again in {retry_seconds}s.".to_string(),
            competition: "Please keep whispers to summon requests.".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResponseEngineConfig {
    pub cooldowns: CooldownConfig,
    pub templates: TemplateConfig,
    pub competition_response_enabled: bool,
    pub completion_mentions_alternatives: bool,
}

impl Default for ResponseEngineConfig {
    fn default() -> Self {
        Self {
            cooldowns: CooldownConfig::default(),
            templates: TemplateConfig::default(),
            competition_response_enabled: true,
            completion_mentions_alternatives: false,
        }
    }
}

#[derive(Debug, Default, Clone)]
struct RateLimitState {
    last_global: Option<u64>,
    last_recipient: HashMap<String, u64>,
    last_kind: HashMap<(String, ResponseKind), u64>,
    last_competition: HashMap<String, u64>,
    last_text: HashMap<(String, u64), u64>,
}

#[derive(Debug, Clone)]
pub struct ResponseEngine {
    config: ResponseEngineConfig,
    state: RateLimitState,
}

impl ResponseEngine {
    pub fn new(config: ResponseEngineConfig) -> Self {
        Self {
            config,
            state: RateLimitState::default(),
        }
    }

    pub fn config(&self) -> &ResponseEngineConfig {
        &self.config
    }

    pub fn handle_context(&mut self, context: ResponseContext, now: u64) -> Vec<ResponseDecision> {
        let candidate = match context {
            ResponseContext::RequestAccepted {
                recipient,
                destination,
            } => self.candidate(
                recipient,
                ResponseKind::Accepted,
                render_template_values(
                    &self.config.templates.accepted,
                    &[TemplateValue::new("destination", &destination)],
                ),
            ),
            ResponseContext::RequestQueued {
                recipient,
                destination,
                queue_position,
                queue_length,
            } => {
                let pos = queue_position.map(|value| value.to_string());
                let len = queue_length.map(|value| value.to_string());
                let template = match (queue_position, queue_length) {
                    (Some(_), Some(_)) => &self.config.templates.queued_with_position_and_length,
                    (Some(_), None) => &self.config.templates.queued_with_position,
                    _ => &self.config.templates.queued,
                };
                let mut values = vec![TemplateValue::new("destination", &destination)];
                if let Some(ref pos) = pos {
                    values.push(TemplateValue::new("queue_position", pos));
                }
                if let Some(ref len) = len {
                    values.push(TemplateValue::new("queue_length", len));
                }
                self.candidate(
                    recipient,
                    ResponseKind::Queued,
                    render_template_values(template, &values),
                )
            }
            ResponseContext::AlreadyGrouped { recipient } => self.candidate(
                recipient,
                ResponseKind::AlreadyGrouped,
                self.config.templates.already_grouped.clone(),
            ),
            ResponseContext::InCombat { recipient } => self.candidate(
                recipient,
                ResponseKind::InCombat,
                self.config.templates.in_combat.clone(),
            ),
            ResponseContext::UnsupportedDestination {
                recipient,
                requested_destination,
                alternatives,
            } => {
                let alternatives = clean_alternatives(&alternatives);
                let alternatives_text = alternatives.join(", ");
                let template = if alternatives.is_empty() {
                    &self.config.templates.unsupported_without_alternatives
                } else {
                    &self.config.templates.unsupported_with_alternatives
                };
                self.candidate(
                    recipient,
                    ResponseKind::UnsupportedDestination,
                    render_template_values(
                        template,
                        &[
                            TemplateValue::new("destination", &requested_destination),
                            TemplateValue::new("alternatives", &alternatives_text),
                        ],
                    ),
                )
            }
            ResponseContext::DestinationUnavailable {
                recipient,
                destination,
                reason,
                alternatives,
            } => {
                let template = match reason {
                    DestinationUnavailableReason::LowShards => {
                        &self.config.templates.unavailable_low_shards
                    }
                    DestinationUnavailableReason::ManualOffOrMaintenance => {
                        &self.config.templates.unavailable_maintenance
                    }
                    DestinationUnavailableReason::UnhealthyTeam => {
                        &self.config.templates.unavailable_unhealthy_team
                    }
                    DestinationUnavailableReason::Temporary => {
                        &self.config.templates.unavailable_temporary
                    }
                };
                let alternatives = clean_alternatives(&alternatives);
                let alternatives_text = alternatives.join(", ");
                self.candidate(
                    recipient,
                    ResponseKind::DestinationUnavailable,
                    render_template_values(
                        template,
                        &[
                            TemplateValue::new("destination", &destination),
                            TemplateValue::new("alternatives", &alternatives_text),
                        ],
                    ),
                )
            }
            ResponseContext::SummonStarted {
                recipient,
                destination,
            } => self.candidate(
                recipient,
                ResponseKind::SummonStarted,
                render_template_values(
                    &self.config.templates.summon_started,
                    &[TemplateValue::new("destination", &destination)],
                ),
            ),
            ResponseContext::SummonCompleted {
                recipient,
                alternatives,
            } => {
                let alternatives = clean_alternatives(&alternatives);
                let alternatives_text = alternatives.join(", ");
                let use_alternatives =
                    self.config.completion_mentions_alternatives && !alternatives.is_empty();
                let template = if use_alternatives {
                    &self.config.templates.summon_completed_with_alternatives
                } else {
                    &self.config.templates.summon_completed
                };
                self.candidate(
                    recipient,
                    ResponseKind::SummonCompleted,
                    render_template_values(
                        template,
                        &[TemplateValue::new("alternatives", &alternatives_text)],
                    ),
                )
            }
            ResponseContext::RequestExpired {
                recipient,
                timeout_seconds,
            } => {
                let timeout = timeout_seconds.map(|value| value.to_string());
                let template = if timeout.is_some() {
                    &self.config.templates.request_expired_with_timeout
                } else {
                    &self.config.templates.request_expired
                };
                let values = timeout
                    .as_ref()
                    .map(|value| vec![TemplateValue::new("timeout_seconds", value)])
                    .unwrap_or_default();
                self.candidate(
                    recipient,
                    ResponseKind::RequestExpired,
                    render_template_values(template, &values),
                )
            }
            ResponseContext::JobFailedSafe {
                recipient,
                retry_seconds,
            } => {
                let retry = retry_seconds.map(|value| value.to_string());
                let template = if retry.is_some() {
                    &self.config.templates.job_failed_safe_with_retry
                } else {
                    &self.config.templates.job_failed_safe
                };
                let values = retry
                    .as_ref()
                    .map(|value| vec![TemplateValue::new("retry_seconds", value)])
                    .unwrap_or_default();
                self.candidate(
                    recipient,
                    ResponseKind::JobFailedSafe,
                    render_template_values(template, &values),
                )
            }
            ResponseContext::CompetitionMessage { recipient } => {
                if !self.config.competition_response_enabled {
                    return vec![ResponseDecision {
                        should_send: false,
                        cooldown_key: cooldown_key(&recipient, ResponseKind::Competition),
                        recipient,
                        response_kind: ResponseKind::Competition,
                        text: String::new(),
                        reason: DecisionReason::CompetitionDisabled,
                    }];
                }
                self.candidate(
                    recipient,
                    ResponseKind::Competition,
                    self.config.templates.competition.clone(),
                )
            }
            ResponseContext::Unknown { recipient } => {
                return vec![ResponseDecision {
                    should_send: false,
                    cooldown_key: cooldown_key(&recipient, ResponseKind::Unknown),
                    recipient,
                    response_kind: ResponseKind::Unknown,
                    text: String::new(),
                    reason: DecisionReason::UnknownNoReply,
                }];
            }
        };

        vec![self.apply_rate_limits(candidate, now)]
    }

    fn candidate(
        &self,
        recipient: String,
        response_kind: ResponseKind,
        text: String,
    ) -> ResponseDecision {
        ResponseDecision {
            should_send: true,
            cooldown_key: cooldown_key(&recipient, response_kind),
            recipient,
            response_kind,
            text,
            reason: DecisionReason::Allowed,
        }
    }

    fn apply_rate_limits(&mut self, mut decision: ResponseDecision, now: u64) -> ResponseDecision {
        let recipient_key = normalize_recipient(&decision.recipient);
        let text_hash = stable_text_hash(&decision.text);

        if is_blocked(
            self.state.last_global,
            now,
            self.config.cooldowns.global_min_interval_secs,
        ) {
            decision.should_send = false;
            decision.reason = DecisionReason::GlobalCooldown;
            return decision;
        }

        if is_blocked(
            self.state.last_recipient.get(&recipient_key).copied(),
            now,
            self.config.cooldowns.per_recipient_secs,
        ) {
            decision.should_send = false;
            decision.reason = DecisionReason::RecipientCooldown;
            return decision;
        }

        if is_blocked(
            self.state
                .last_kind
                .get(&(recipient_key.clone(), decision.response_kind))
                .copied(),
            now,
            self.config.cooldowns.per_response_kind_secs,
        ) {
            decision.should_send = false;
            decision.reason = DecisionReason::ResponseKindCooldown;
            return decision;
        }

        if decision.response_kind == ResponseKind::Competition
            && is_blocked(
                self.state.last_competition.get(&recipient_key).copied(),
                now,
                self.config.cooldowns.competition_secs,
            )
        {
            decision.should_send = false;
            decision.reason = DecisionReason::CompetitionCooldown;
            return decision;
        }

        if is_blocked(
            self.state
                .last_text
                .get(&(recipient_key.clone(), text_hash))
                .copied(),
            now,
            self.config.cooldowns.duplicate_text_secs,
        ) {
            decision.should_send = false;
            decision.reason = DecisionReason::DuplicateTextSuppressed;
            return decision;
        }

        self.state.last_global = Some(now);
        self.state.last_recipient.insert(recipient_key.clone(), now);
        self.state
            .last_kind
            .insert((recipient_key.clone(), decision.response_kind), now);
        if decision.response_kind == ResponseKind::Competition {
            self.state
                .last_competition
                .insert(recipient_key.clone(), now);
        }
        self.state.last_text.insert((recipient_key, text_hash), now);
        decision
    }
}

fn is_blocked(last: Option<u64>, now: u64, duration: Option<u64>) -> bool {
    match (last, duration) {
        (Some(last), Some(duration)) => now.saturating_sub(last) < duration,
        _ => false,
    }
}

fn normalize_recipient(recipient: &str) -> String {
    recipient.trim().to_ascii_lowercase()
}

fn cooldown_key(recipient: &str, response_kind: ResponseKind) -> String {
    format!(
        "{}:{}",
        normalize_recipient(recipient),
        response_kind.as_str()
    )
}

fn stable_text_hash(text: &str) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

struct TemplateValue<'a> {
    key: &'a str,
    value: &'a str,
}

impl<'a> TemplateValue<'a> {
    fn new(key: &'a str, value: &'a str) -> Self {
        Self { key, value }
    }
}

pub fn render_template(template: &str, values: &[(&str, &str)]) -> String {
    let converted: Vec<TemplateValue<'_>> = values
        .iter()
        .map(|(key, value)| TemplateValue::new(key, value))
        .collect();
    render_template_values(template, &converted)
}

fn render_template_values(template: &str, values: &[TemplateValue<'_>]) -> String {
    let mut out = String::with_capacity(template.len() + 32);
    let bytes = template.as_bytes();
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'{' {
            if let Some(relative_end) = template[index + 1..].find('}') {
                let end = index + 1 + relative_end;
                let key = &template[index + 1..end];
                if let Some(value) = values.iter().find(|value| value.key == key) {
                    out.push_str(&sanitize_whisper_value(value.value));
                    index = end + 1;
                    continue;
                }
            }
        }

        let ch = template[index..]
            .chars()
            .next()
            .expect("valid UTF-8 boundary");
        out.push(ch);
        index += ch.len_utf8();
    }

    out
}

fn sanitize_whisper_value(value: &str) -> String {
    value
        .chars()
        .map(|ch| if ch.is_control() { ' ' } else { ch })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn clean_alternatives(alternatives: &[String]) -> Vec<String> {
    alternatives
        .iter()
        .map(|value| sanitize_whisper_value(value))
        .filter(|value| !value.is_empty())
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnknownCategory {
    Unknown,
    LowConfidence,
    Competition,
}

impl UnknownCategory {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::LowConfidence => "low-confidence",
            Self::Competition => "competition",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownWhisperRecord {
    pub schema_version: u32,
    pub timestamp: String,
    pub sender: String,
    pub raw_text: String,
    pub normalized_text: Option<String>,
    pub source_role: Option<String>,
    pub source_destination: Option<String>,
    pub parser_signals: Vec<String>,
    pub parser_reason: Option<String>,
    pub current_destination_context: Option<String>,
    pub category: UnknownCategory,
}

impl UnknownWhisperRecord {
    pub fn new(
        timestamp: impl Into<String>,
        sender: impl Into<String>,
        raw_text: impl Into<String>,
    ) -> Self {
        Self {
            schema_version: UNKNOWN_WHISPER_SCHEMA_VERSION,
            timestamp: timestamp.into(),
            sender: sender.into(),
            raw_text: raw_text.into(),
            normalized_text: None,
            source_role: None,
            source_destination: None,
            parser_signals: Vec::new(),
            parser_reason: None,
            current_destination_context: None,
            category: UnknownCategory::Unknown,
        }
    }

    pub fn to_json_line(&self) -> String {
        let signals = self
            .parser_signals
            .iter()
            .map(|value| json_string(value))
            .collect::<Vec<_>>()
            .join(",");

        format!(
            "{{\"schema_version\":{},\"timestamp\":{},\"sender\":{},\"raw_text\":{},\"normalized_text\":{},\"source_role\":{},\"source_destination\":{},\"parser_signals\":[{}],\"parser_reason\":{},\"current_destination_context\":{},\"category\":{}}}\n",
            self.schema_version,
            json_string(&self.timestamp),
            json_string(&self.sender),
            json_string(&self.raw_text),
            json_optional_string(self.normalized_text.as_deref()),
            json_optional_string(self.source_role.as_deref()),
            json_optional_string(self.source_destination.as_deref()),
            signals,
            json_optional_string(self.parser_reason.as_deref()),
            json_optional_string(self.current_destination_context.as_deref()),
            json_string(self.category.as_str())
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownWhisperDumpConfig {
    pub path: PathBuf,
    pub max_bytes: Option<u64>,
}

impl Default for UnknownWhisperDumpConfig {
    fn default() -> Self {
        Self {
            path: PathBuf::from(DEFAULT_UNKNOWN_WHISPER_PATH),
            max_bytes: Some(8 * 1024 * 1024),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UnknownWhisperDumper {
    config: UnknownWhisperDumpConfig,
}

impl UnknownWhisperDumper {
    pub fn new(config: UnknownWhisperDumpConfig) -> Self {
        Self { config }
    }

    pub fn config(&self) -> &UnknownWhisperDumpConfig {
        &self.config
    }

    pub fn record_unknown(&self, record: &UnknownWhisperRecord) -> io::Result<()> {
        let line = record.to_json_line();
        self.rotate_if_needed(line.len() as u64)?;
        if let Some(parent) = self.config.path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)?;
            }
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.config.path)?;
        file.write_all(line.as_bytes())?;
        file.flush()
    }

    fn rotate_if_needed(&self, incoming_bytes: u64) -> io::Result<()> {
        let Some(max_bytes) = self.config.max_bytes else {
            return Ok(());
        };
        let Ok(metadata) = fs::metadata(&self.config.path) else {
            return Ok(());
        };
        if metadata.len().saturating_add(incoming_bytes) <= max_bytes {
            return Ok(());
        }

        let rotated = rotated_path(&self.config.path);
        match fs::remove_file(&rotated) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        fs::rename(&self.config.path, rotated)
    }
}

fn rotated_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".1");
    PathBuf::from(value)
}

fn json_optional_string(value: Option<&str>) -> String {
    value.map(json_string).unwrap_or_else(|| "null".to_string())
}

fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            ch if ch <= '\u{1F}' => {
                use std::fmt::Write as _;
                let _ = write!(&mut out, "\\u{:04x}", ch as u32);
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn no_cooldowns() -> ResponseEngineConfig {
        ResponseEngineConfig {
            cooldowns: CooldownConfig {
                global_min_interval_secs: None,
                per_recipient_secs: None,
                per_response_kind_secs: None,
                competition_secs: None,
                duplicate_text_secs: None,
            },
            ..ResponseEngineConfig::default()
        }
    }

    fn first(engine: &mut ResponseEngine, context: ResponseContext, now: u64) -> ResponseDecision {
        engine.handle_context(context, now).remove(0)
    }

    #[test]
    fn covers_every_response_context() {
        let mut engine = ResponseEngine::new(no_cooldowns());
        let cases = vec![
            ResponseContext::RequestAccepted {
                recipient: "A".into(),
                destination: "Hyjal".into(),
            },
            ResponseContext::RequestQueued {
                recipient: "B".into(),
                destination: "Hyjal".into(),
                queue_position: None,
                queue_length: None,
            },
            ResponseContext::AlreadyGrouped {
                recipient: "C".into(),
            },
            ResponseContext::InCombat {
                recipient: "D".into(),
            },
            ResponseContext::UnsupportedDestination {
                recipient: "E".into(),
                requested_destination: "Feralas".into(),
                alternatives: vec!["Hyjal".into()],
            },
            ResponseContext::DestinationUnavailable {
                recipient: "F".into(),
                destination: "Hyjal".into(),
                reason: DestinationUnavailableReason::Temporary,
                alternatives: Vec::new(),
            },
            ResponseContext::SummonStarted {
                recipient: "G".into(),
                destination: "Hyjal".into(),
            },
            ResponseContext::SummonCompleted {
                recipient: "H".into(),
                alternatives: Vec::new(),
            },
            ResponseContext::RequestExpired {
                recipient: "I".into(),
                timeout_seconds: None,
            },
            ResponseContext::JobFailedSafe {
                recipient: "J".into(),
                retry_seconds: None,
            },
            ResponseContext::CompetitionMessage {
                recipient: "K".into(),
            },
        ];
        for (index, context) in cases.into_iter().enumerate() {
            let decision = first(&mut engine, context, index as u64);
            assert!(decision.should_send, "{:?}", decision.response_kind);
            assert!(!decision.text.is_empty());
        }

        let unknown = first(
            &mut engine,
            ResponseContext::Unknown {
                recipient: "L".into(),
            },
            99,
        );
        assert!(!unknown.should_send);
        assert_eq!(unknown.reason, DecisionReason::UnknownNoReply);
    }

    #[test]
    fn unsupported_uses_supplied_alternatives_only() {
        let mut engine = ResponseEngine::new(no_cooldowns());
        let decision = first(
            &mut engine,
            ResponseContext::UnsupportedDestination {
                recipient: "Sam".into(),
                requested_destination: "Feralas".into(),
                alternatives: vec!["Winterspring".into(), "Azshara".into(), "Hyjal".into()],
            },
            0,
        );
        assert_eq!(
            decision.text,
            "I don't have Feralas. Available: Winterspring, Azshara, Hyjal."
        );
    }

    #[test]
    fn unsupported_without_alternatives_does_not_invent_any() {
        let mut engine = ResponseEngine::new(no_cooldowns());
        let decision = first(
            &mut engine,
            ResponseContext::UnsupportedDestination {
                recipient: "Sam".into(),
                requested_destination: "Feralas".into(),
                alternatives: Vec::new(),
            },
            0,
        );
        assert_eq!(decision.text, "I don't have Feralas.");
    }

    #[test]
    fn grouped_and_combat_are_short_and_useful() {
        let mut engine = ResponseEngine::new(no_cooldowns());
        let grouped = first(
            &mut engine,
            ResponseContext::AlreadyGrouped {
                recipient: "A".into(),
            },
            0,
        );
        let combat = first(
            &mut engine,
            ResponseContext::InCombat {
                recipient: "B".into(),
            },
            0,
        );
        assert!(grouped.text.contains("leave your current party"));
        assert!(combat.text.contains("combat"));
    }

    #[test]
    fn queue_position_variants_are_deterministic() {
        let mut engine = ResponseEngine::new(no_cooldowns());
        let with_both = first(
            &mut engine,
            ResponseContext::RequestQueued {
                recipient: "A".into(),
                destination: "Hyjal".into(),
                queue_position: Some(2),
                queue_length: Some(5),
            },
            0,
        );
        assert_eq!(with_both.text, "Queued for Hyjal. Position: 2/5.");

        let position_only = first(
            &mut engine,
            ResponseContext::RequestQueued {
                recipient: "B".into(),
                destination: "Hyjal".into(),
                queue_position: Some(3),
                queue_length: None,
            },
            0,
        );
        assert_eq!(position_only.text, "Queued for Hyjal. Position: 3.");
    }

    #[test]
    fn cooldown_blocks_repeat_and_allows_at_boundary() {
        let mut config = no_cooldowns();
        config.cooldowns.per_recipient_secs = Some(10);
        let mut engine = ResponseEngine::new(config);
        let context = || ResponseContext::InCombat {
            recipient: "Sam".into(),
        };

        assert!(first(&mut engine, context(), 100).should_send);
        let blocked = first(&mut engine, context(), 109);
        assert!(!blocked.should_send);
        assert_eq!(blocked.reason, DecisionReason::RecipientCooldown);
        assert!(first(&mut engine, context(), 110).should_send);
    }

    #[test]
    fn recipients_are_independent_without_global_limit() {
        let mut config = no_cooldowns();
        config.cooldowns.per_recipient_secs = Some(60);
        config.cooldowns.per_response_kind_secs = Some(60);
        config.cooldowns.duplicate_text_secs = Some(60);
        let mut engine = ResponseEngine::new(config);

        assert!(
            first(
                &mut engine,
                ResponseContext::InCombat {
                    recipient: "A".into(),
                },
                0,
            )
            .should_send
        );
        assert!(
            first(
                &mut engine,
                ResponseContext::InCombat {
                    recipient: "B".into(),
                },
                1,
            )
            .should_send
        );
    }

    #[test]
    fn competition_has_its_own_cooldown() {
        let mut config = no_cooldowns();
        config.cooldowns.competition_secs = Some(30);
        let mut engine = ResponseEngine::new(config);
        let context = || ResponseContext::CompetitionMessage {
            recipient: "Rival".into(),
        };

        assert!(first(&mut engine, context(), 0).should_send);
        let blocked = first(&mut engine, context(), 29);
        assert!(!blocked.should_send);
        assert_eq!(blocked.reason, DecisionReason::CompetitionCooldown);
        assert!(first(&mut engine, context(), 30).should_send);
    }

    #[test]
    fn duplicate_text_suppression_is_per_recipient() {
        let mut config = no_cooldowns();
        config.cooldowns.duplicate_text_secs = Some(20);
        let mut engine = ResponseEngine::new(config);

        assert!(
            first(
                &mut engine,
                ResponseContext::InCombat {
                    recipient: "A".into(),
                },
                10,
            )
            .should_send
        );
        let duplicate = first(
            &mut engine,
            ResponseContext::InCombat {
                recipient: "A".into(),
            },
            15,
        );
        assert!(!duplicate.should_send);
        assert_eq!(duplicate.reason, DecisionReason::DuplicateTextSuppressed);
        assert!(
            first(
                &mut engine,
                ResponseContext::InCombat {
                    recipient: "B".into(),
                },
                15,
            )
            .should_send
        );
    }

    #[test]
    fn template_values_are_single_pass_and_control_chars_are_removed() {
        let rendered = render_template(
            "I don't have {destination}. Available: {alternatives}.",
            &[
                ("destination", "Feralas {alternatives}\nnext"),
                ("alternatives", "Hyjal\rAzshara"),
            ],
        );
        assert_eq!(
            rendered,
            "I don't have Feralas {alternatives} next. Available: Hyjal Azshara."
        );
    }

    #[test]
    fn completion_alternatives_are_opt_in() {
        let mut default_engine = ResponseEngine::new(no_cooldowns());
        let default = first(
            &mut default_engine,
            ResponseContext::SummonCompleted {
                recipient: "A".into(),
                alternatives: vec!["Winterspring".into(), "Azshara".into()],
            },
            0,
        );
        assert_eq!(default.text, "Done. Thank you.");

        let mut config = no_cooldowns();
        config.completion_mentions_alternatives = true;
        let mut opt_in = ResponseEngine::new(config);
        let mentioned = first(
            &mut opt_in,
            ResponseContext::SummonCompleted {
                recipient: "A".into(),
                alternatives: vec!["Winterspring".into(), "Azshara".into()],
            },
            0,
        );
        assert_eq!(
            mentioned.text,
            "Done. Also available: Winterspring, Azshara."
        );
    }

    #[test]
    fn explicit_time_behavior_repeats_exactly() {
        let mut config = no_cooldowns();
        config.cooldowns.per_recipient_secs = Some(10);
        let mut left = ResponseEngine::new(config.clone());
        let mut right = ResponseEngine::new(config);
        let context = || ResponseContext::InCombat {
            recipient: "Sam".into(),
        };

        assert_eq!(
            first(&mut left, context(), 100),
            first(&mut right, context(), 100)
        );
        assert_eq!(
            first(&mut left, context(), 105),
            first(&mut right, context(), 105)
        );
    }

    #[test]
    fn jsonl_escapes_quotes_newlines_unicode_and_controls() {
        let mut record = UnknownWhisperRecord::new(
            "2026-10-07T07:00:00+02:00",
            "S\"am",
            "one\ntwo\\three 💬\u{0001}",
        );
        record.normalized_text = Some("one two 💬".into());
        record.parser_signals = vec!["signal\"1".into(), "żółć".into()];
        let line = record.to_json_line();

        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        assert!(line.contains("S\\\"am"));
        assert!(line.contains("one\\ntwo\\\\three 💬\\u0001"));
        assert!(line.contains("żółć"));
    }

    #[test]
    fn multiple_records_append_as_independent_lines() {
        let path = temp_path("append.jsonl");
        cleanup(&path);
        let dumper = UnknownWhisperDumper::new(UnknownWhisperDumpConfig {
            path: path.clone(),
            max_bytes: None,
        });

        dumper
            .record_unknown(&UnknownWhisperRecord::new("t1", "A", "first"))
            .unwrap();
        dumper
            .record_unknown(&UnknownWhisperRecord::new("t2", "B", "second"))
            .unwrap();

        let data = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = data.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("\"raw_text\":\"first\""));
        assert!(lines[1].contains("\"raw_text\":\"second\""));
        cleanup(&path);
    }

    #[test]
    fn rotation_keeps_previous_file_as_single_backup() {
        let path = temp_path("rotate.jsonl");
        cleanup(&path);
        cleanup(&rotated_path(&path));
        fs::write(&path, "old-record\n").unwrap();
        let dumper = UnknownWhisperDumper::new(UnknownWhisperDumpConfig {
            path: path.clone(),
            max_bytes: Some(12),
        });

        dumper
            .record_unknown(&UnknownWhisperRecord::new("t", "A", "new"))
            .unwrap();

        assert_eq!(
            fs::read_to_string(rotated_path(&path)).unwrap(),
            "old-record\n"
        );
        assert!(fs::read_to_string(&path)
            .unwrap()
            .contains("\"raw_text\":\"new\""));
        cleanup(&path);
        cleanup(&rotated_path(&path));
    }

    #[test]
    fn no_internal_failure_detail_is_accepted_by_job_failed_context() {
        let mut engine = ResponseEngine::new(no_cooldowns());
        let decision = first(
            &mut engine,
            ResponseContext::JobFailedSafe {
                recipient: "A".into(),
                retry_seconds: Some(20),
            },
            0,
        );
        assert_eq!(
            decision.text,
            "Summon failed temporarily. Please try again in 20s."
        );
    }

    fn temp_path(suffix: &str) -> PathBuf {
        let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "tele08_response_engine_{}_{}_{}",
            std::process::id(),
            n,
            suffix
        ))
    }

    fn cleanup(path: &Path) {
        let _ = fs::remove_file(path);
    }
}
