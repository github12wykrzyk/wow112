use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use tele08_request_queue::{
    ActiveJob, CommandOutcome, FailureDisposition, QueueConfig, QueueEngine, QueueEvent,
    ResourceKey, SummonRequest,
};

pub const TELE11_JOURNAL_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteConfig {
    pub destination: String,
    pub resource: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceCoreConfig {
    pub schema_version: u32,
    pub dedup_window_ms: u64,
    pub expiry_ms: u64,
    pub routes: Vec<RouteConfig>,
}

impl ServiceCoreConfig {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err(format!(
                "unsupported TELE11 core config schema_version={}",
                self.schema_version
            ));
        }
        if self.routes.is_empty() {
            return Err("TELE11 core config requires at least one route".to_string());
        }
        let mut destinations = BTreeMap::<String, String>::new();
        let mut resources = BTreeMap::<String, String>::new();
        for route in &self.routes {
            let destination = route.destination.trim();
            let resource = route.resource.trim();
            if destination.is_empty() || resource.is_empty() {
                return Err("TELE11 route destination/resource cannot be empty".to_string());
            }
            if destinations
                .insert(destination.to_string(), resource.to_string())
                .is_some()
            {
                return Err(format!("duplicate TELE11 destination route: {destination}"));
            }
            if let Some(existing) = resources.insert(resource.to_string(), destination.to_string()) {
                return Err(format!(
                    "resource {resource} mapped to both {existing} and {destination}"
                ));
            }
        }
        Ok(())
    }

    pub fn queue_config(&self) -> Result<QueueConfig, String> {
        self.validate()?;
        let mut config = QueueConfig::new(self.dedup_window_ms, self.expiry_ms);
        for route in &self.routes {
            config.map_destination_resource(
                route.destination.clone(),
                ResourceKey(route.resource.clone()),
            );
        }
        Ok(config)
    }

    pub fn resources(&self) -> Vec<ResourceKey> {
        self.routes
            .iter()
            .map(|route| ResourceKey(route.resource.clone()))
            .collect()
    }

    pub fn resource_for_destination(&self, destination: &str) -> Option<ResourceKey> {
        self.routes
            .iter()
            .find(|route| route.destination.eq_ignore_ascii_case(destination))
            .map(|route| ResourceKey(route.resource.clone()))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureClass {
    RetryableSafe,
    Terminal,
    UncertainDoNotReplay,
}

impl FailureClass {
    fn disposition(self) -> FailureDisposition {
        match self {
            Self::RetryableSafe => FailureDisposition::RetryableSafe,
            Self::Terminal => FailureDisposition::Terminal,
            Self::UncertainDoNotReplay => FailureDisposition::UncertainDoNotReplay,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum JournalEvent {
    RequestAccepted {
        request_id: String,
        player: String,
        destination: String,
        raw_text: String,
    },
    JobActivated {
        job_id: String,
        request_id: String,
        destination: String,
        resource: String,
        attempt: u32,
    },
    JobCompleted {
        job_id: String,
        request_id: String,
    },
    JobFailed {
        job_id: String,
        request_id: String,
        failure: FailureClass,
        detail: String,
    },
    PaymentObserved {
        request_id: String,
        payer: String,
        amount_copper: u64,
    },
    PaymentSettled {
        request_id: String,
        payer: String,
        amount_copper: u64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JournalEntry {
    pub schema_version: u32,
    pub at_ms: u64,
    pub event: JournalEvent,
}

impl JournalEntry {
    fn new(at_ms: u64, event: JournalEvent) -> Self {
        Self {
            schema_version: TELE11_JOURNAL_SCHEMA_VERSION,
            at_ms,
            event,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerRecord {
    pub request_id: String,
    pub player: String,
    pub destination: String,
    pub summon_state: String,
    pub job_id: Option<String>,
    pub payment_observed_copper: u64,
    pub payment_settled_copper: u64,
    pub last_event_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryBlock {
    pub job_id: String,
    pub request_id: String,
    pub resource: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivationResult {
    pub job: ActiveJob,
    pub events: Vec<QueueEvent>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutorOutcome {
    Pass,
    SafePreActiveFailure,
    TerminalFailure,
    Uncertain,
}

impl ExecutorOutcome {
    pub fn failure_class(self) -> Option<FailureClass> {
        match self {
            Self::Pass => None,
            Self::SafePreActiveFailure => Some(FailureClass::RetryableSafe),
            Self::TerminalFailure => Some(FailureClass::Terminal),
            Self::Uncertain => Some(FailureClass::UncertainDoNotReplay),
        }
    }
}

#[derive(Debug)]
pub struct ServiceCore {
    config: ServiceCoreConfig,
    queue: QueueEngine,
    journal_path: PathBuf,
    entries: Vec<JournalEntry>,
}

impl ServiceCore {
    pub fn create_or_open(
        journal_path: impl Into<PathBuf>,
        config: ServiceCoreConfig,
        now_ms: u64,
    ) -> Result<(Self, Vec<RecoveryBlock>), String> {
        config.validate()?;
        let journal_path = journal_path.into();
        if let Some(parent) = journal_path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent).map_err(|error| {
                    format!("create TELE11 journal directory {} failed: {error}", parent.display())
                })?;
            }
        }
        let entries = read_journal(&journal_path)?;
        let queue = replay_queue(&config, &entries)?;
        let mut core = Self {
            config,
            queue,
            journal_path,
            entries,
        };

        let mut recovered = Vec::new();
        let active = core.active_jobs();
        for job in active {
            let block = RecoveryBlock {
                job_id: job.job_id.clone(),
                request_id: job.request_id.clone(),
                resource: job.resource.0.clone(),
            };
            core.settle_job(
                &job.job_id,
                ExecutorOutcome::Uncertain,
                now_ms,
                "service restart found an executor job without a durable terminal outcome",
            )?;
            recovered.push(block);
        }
        Ok((core, recovered))
    }

    pub fn config(&self) -> &ServiceCoreConfig {
        &self.config
    }

    pub fn queue(&self) -> &QueueEngine {
        &self.queue
    }

    pub fn journal_entries(&self) -> &[JournalEntry] {
        &self.entries
    }

    pub fn enqueue_request(
        &mut self,
        request_id: impl Into<String>,
        player: impl Into<String>,
        destination: impl Into<String>,
        raw_text: impl Into<String>,
        at_ms: u64,
    ) -> Result<Vec<QueueEvent>, String> {
        let request_id = request_id.into();
        let player = player.into();
        let destination = destination.into();
        let raw_text = raw_text.into();
        let request = SummonRequest::new(
            request_id.clone(),
            player.clone(),
            destination.clone(),
            at_ms,
        );
        let mut staged = self.queue.clone();
        let outcome = staged.enqueue(request);
        if !outcome.accepted {
            return Ok(outcome.events);
        }

        let entry = JournalEntry::new(
            at_ms,
            JournalEvent::RequestAccepted {
                request_id,
                player,
                destination,
                raw_text,
            },
        );
        append_entry(&self.journal_path, &entry)?;
        self.entries.push(entry);
        self.queue = staged;
        Ok(outcome.events)
    }

    pub fn activate_next(
        &mut self,
        resource: &ResourceKey,
        at_ms: u64,
    ) -> Result<ActivationResult, String> {
        let mut staged = self.queue.clone();
        let outcome = staged
            .activate_next(resource, at_ms)
            .map_err(|error| format!("TELE11 activate_next failed: {error:?}"))?;
        let job = activated_job(&outcome)?;
        let entry = JournalEntry::new(
            at_ms,
            JournalEvent::JobActivated {
                job_id: job.job_id.clone(),
                request_id: job.request_id.clone(),
                destination: job.destination.clone(),
                resource: job.resource.0.clone(),
                attempt: job.attempt,
            },
        );
        append_entry(&self.journal_path, &entry)?;
        self.entries.push(entry);
        self.queue = staged;
        Ok(ActivationResult {
            job,
            events: outcome.events,
        })
    }

    pub fn settle_job(
        &mut self,
        job_id: &str,
        outcome: ExecutorOutcome,
        at_ms: u64,
        detail: impl Into<String>,
    ) -> Result<Vec<QueueEvent>, String> {
        let request_id = self
            .find_active_job(job_id)
            .map(|job| job.request_id.clone())
            .ok_or_else(|| format!("TELE11 active job not found: {job_id}"))?;
        let mut staged = self.queue.clone();
        let command = match outcome {
            ExecutorOutcome::Pass => staged
                .complete(job_id, at_ms)
                .map_err(|error| format!("TELE11 complete failed: {error:?}"))?,
            other => staged
                .fail(
                    job_id,
                    other
                        .failure_class()
                        .expect("non-pass executor outcome has failure class")
                        .disposition(),
                    at_ms,
                )
                .map_err(|error| format!("TELE11 fail failed: {error:?}"))?,
        };

        let event = match outcome {
            ExecutorOutcome::Pass => JournalEvent::JobCompleted {
                job_id: job_id.to_string(),
                request_id,
            },
            other => JournalEvent::JobFailed {
                job_id: job_id.to_string(),
                request_id,
                failure: other
                    .failure_class()
                    .expect("non-pass executor outcome has failure class"),
                detail: detail.into(),
            },
        };
        let entry = JournalEntry::new(at_ms, event);
        append_entry(&self.journal_path, &entry)?;
        self.entries.push(entry);
        self.queue = staged;
        Ok(command.events)
    }

    pub fn record_payment_observed(
        &mut self,
        request_id: &str,
        payer: &str,
        amount_copper: u64,
        at_ms: u64,
    ) -> Result<(), String> {
        if self.queue.request(request_id).is_none() {
            return Err(format!("TELE11 payment references unknown request: {request_id}"));
        }
        let entry = JournalEntry::new(
            at_ms,
            JournalEvent::PaymentObserved {
                request_id: request_id.to_string(),
                payer: payer.to_string(),
                amount_copper,
            },
        );
        append_entry(&self.journal_path, &entry)?;
        self.entries.push(entry);
        Ok(())
    }

    pub fn record_payment_settled(
        &mut self,
        request_id: &str,
        payer: &str,
        amount_copper: u64,
        at_ms: u64,
    ) -> Result<(), String> {
        if self.queue.request(request_id).is_none() {
            return Err(format!("TELE11 payment references unknown request: {request_id}"));
        }
        let entry = JournalEntry::new(
            at_ms,
            JournalEvent::PaymentSettled {
                request_id: request_id.to_string(),
                payer: payer.to_string(),
                amount_copper,
            },
        );
        append_entry(&self.journal_path, &entry)?;
        self.entries.push(entry);
        Ok(())
    }

    pub fn ledger(&self) -> Vec<LedgerRecord> {
        build_ledger(&self.entries)
    }

    pub fn ledger_for_player(&self, player: &str) -> Vec<LedgerRecord> {
        let wanted = player.trim().to_ascii_lowercase();
        self.ledger()
            .into_iter()
            .filter(|record| record.player.to_ascii_lowercase() == wanted)
            .collect()
    }

    pub fn active_jobs(&self) -> Vec<ActiveJob> {
        self.config
            .resources()
            .into_iter()
            .filter_map(|resource| self.queue.active_job_by_resource(&resource).cloned())
            .collect()
    }

    fn find_active_job(&self, job_id: &str) -> Option<&ActiveJob> {
        self.config.resources().into_iter().find_map(|resource| {
            self.queue
                .active_job_by_resource(&resource)
                .filter(|job| job.job_id == job_id)
        })
    }
}

fn activated_job(outcome: &CommandOutcome) -> Result<ActiveJob, String> {
    outcome
        .events
        .iter()
        .find_map(|event| match event {
            QueueEvent::JobActivated { job } => Some(job.clone()),
            _ => None,
        })
        .ok_or_else(|| "TELE11 queue activation produced no JobActivated event".to_string())
}

fn append_entry(path: &Path, entry: &JournalEntry) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("open TELE11 journal {} failed: {error}", path.display()))?;
    let line = serde_json::to_string(entry)
        .map_err(|error| format!("serialize TELE11 journal entry failed: {error}"))?;
    file.write_all(line.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .and_then(|_| file.flush())
        .map_err(|error| format!("write TELE11 journal {} failed: {error}", path.display()))?;
    file.sync_data()
        .map_err(|error| format!("sync TELE11 journal {} failed: {error}", path.display()))?;
    Ok(())
}

pub fn read_journal(path: &Path) -> Result<Vec<JournalEntry>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = File::open(path)
        .map_err(|error| format!("open TELE11 journal {} failed: {error}", path.display()))?;
    let mut entries = Vec::new();
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(|error| {
            format!("read TELE11 journal {} line {} failed: {error}", path.display(), index + 1)
        })?;
        if line.trim().is_empty() {
            continue;
        }
        let entry: JournalEntry = serde_json::from_str(&line).map_err(|error| {
            format!(
                "parse TELE11 journal {} line {} failed: {error}",
                path.display(),
                index + 1
            )
        })?;
        if entry.schema_version != TELE11_JOURNAL_SCHEMA_VERSION {
            return Err(format!(
                "unsupported TELE11 journal schema_version={} line={}",
                entry.schema_version,
                index + 1
            ));
        }
        entries.push(entry);
    }
    Ok(entries)
}

fn replay_queue(config: &ServiceCoreConfig, entries: &[JournalEntry]) -> Result<QueueEngine, String> {
    let mut queue = QueueEngine::new(config.queue_config()?);
    for entry in entries {
        match &entry.event {
            JournalEvent::RequestAccepted {
                request_id,
                player,
                destination,
                ..
            } => {
                let outcome = queue.enqueue(SummonRequest::new(
                    request_id.clone(),
                    player.clone(),
                    destination.clone(),
                    entry.at_ms,
                ));
                if !outcome.accepted && outcome.duplicate_of.is_none() {
                    return Err(format!(
                        "TELE11 replay request rejected request_id={request_id} events={:?}",
                        outcome.events
                    ));
                }
            }
            JournalEvent::JobActivated {
                job_id,
                request_id,
                destination,
                resource,
                attempt,
            } => {
                let outcome = queue
                    .activate_next(&ResourceKey(resource.clone()), entry.at_ms)
                    .map_err(|error| {
                        format!(
                            "TELE11 replay activation failed job_id={job_id}: {error:?}"
                        )
                    })?;
                let actual = activated_job(&outcome)?;
                if actual.job_id != *job_id
                    || actual.request_id != *request_id
                    || actual.destination != *destination
                    || actual.resource.0 != *resource
                    || actual.attempt != *attempt
                {
                    return Err(format!(
                        "TELE11 replay activation mismatch expected={job_id}/{request_id}/{destination}/{resource}/{attempt} actual={actual:?}"
                    ));
                }
            }
            JournalEvent::JobCompleted { job_id, .. } => {
                queue.complete(job_id, entry.at_ms).map_err(|error| {
                    format!("TELE11 replay complete failed job_id={job_id}: {error:?}")
                })?;
            }
            JournalEvent::JobFailed {
                job_id, failure, ..
            } => {
                queue
                    .fail(job_id, failure.disposition(), entry.at_ms)
                    .map_err(|error| {
                        format!("TELE11 replay fail failed job_id={job_id}: {error:?}")
                    })?;
            }
            JournalEvent::PaymentObserved { .. } | JournalEvent::PaymentSettled { .. } => {}
        }
    }
    Ok(queue)
}

pub fn build_ledger(entries: &[JournalEntry]) -> Vec<LedgerRecord> {
    let mut records = BTreeMap::<String, LedgerRecord>::new();
    for entry in entries {
        match &entry.event {
            JournalEvent::RequestAccepted {
                request_id,
                player,
                destination,
                ..
            } => {
                records.entry(request_id.clone()).or_insert(LedgerRecord {
                    request_id: request_id.clone(),
                    player: player.clone(),
                    destination: destination.clone(),
                    summon_state: "queued".to_string(),
                    job_id: None,
                    payment_observed_copper: 0,
                    payment_settled_copper: 0,
                    last_event_at_ms: entry.at_ms,
                });
            }
            JournalEvent::JobActivated {
                request_id, job_id, ..
            } => {
                if let Some(record) = records.get_mut(request_id) {
                    record.summon_state = "active".to_string();
                    record.job_id = Some(job_id.clone());
                    record.last_event_at_ms = entry.at_ms;
                }
            }
            JournalEvent::JobCompleted { request_id, job_id } => {
                if let Some(record) = records.get_mut(request_id) {
                    record.summon_state = "completed".to_string();
                    record.job_id = Some(job_id.clone());
                    record.last_event_at_ms = entry.at_ms;
                }
            }
            JournalEvent::JobFailed {
                request_id,
                job_id,
                failure,
                ..
            } => {
                if let Some(record) = records.get_mut(request_id) {
                    record.summon_state = match failure {
                        FailureClass::RetryableSafe => "queued_retry".to_string(),
                        FailureClass::Terminal => "failed_terminal".to_string(),
                        FailureClass::UncertainDoNotReplay => "blocked_reconciliation".to_string(),
                    };
                    record.job_id = Some(job_id.clone());
                    record.last_event_at_ms = entry.at_ms;
                }
            }
            JournalEvent::PaymentObserved {
                request_id,
                amount_copper,
                ..
            } => {
                if let Some(record) = records.get_mut(request_id) {
                    record.payment_observed_copper = record
                        .payment_observed_copper
                        .saturating_add(*amount_copper);
                    record.last_event_at_ms = entry.at_ms;
                }
            }
            JournalEvent::PaymentSettled {
                request_id,
                amount_copper,
                ..
            } => {
                if let Some(record) = records.get_mut(request_id) {
                    record.payment_settled_copper = record
                        .payment_settled_copper
                        .saturating_add(*amount_copper);
                    record.last_event_at_ms = entry.at_ms;
                }
            }
        }
    }
    records.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_config() -> ServiceCoreConfig {
        ServiceCoreConfig {
            schema_version: 1,
            dedup_window_ms: 30_000,
            expiry_ms: 180_000,
            routes: vec![
                RouteConfig {
                    destination: "winterspring".to_string(),
                    resource: "summon/winterspring".to_string(),
                },
                RouteConfig {
                    destination: "hyjal".to_string(),
                    resource: "summon/hyjal".to_string(),
                },
            ],
        }
    }

    fn temp_journal(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("tele11-{label}-{}-{unique}.jsonl", std::process::id()))
    }

    #[test]
    fn crash_after_activation_blocks_instead_of_replaying() {
        let path = temp_journal("crash-block");
        let config = test_config();
        {
            let (mut core, recovered) =
                ServiceCore::create_or_open(&path, config.clone(), 1).unwrap();
            assert!(recovered.is_empty());
            core.enqueue_request("req-1", "Customer", "winterspring", "winterspring pls", 10)
                .unwrap();
            let activation = core
                .activate_next(&ResourceKey("summon/winterspring".into()), 20)
                .unwrap();
            assert_eq!(activation.job.request_id, "req-1");
        }

        let (core, recovered) = ServiceCore::create_or_open(&path, config, 30).unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].request_id, "req-1");
        assert_eq!(core.queue().request("req-1").unwrap().state, tele08_request_queue::LifecycleState::BlockedReconciliation);
        assert!(core.active_jobs().is_empty());

        let entries = read_journal(&path).unwrap();
        assert!(entries.iter().any(|entry| matches!(
            entry.event,
            JournalEvent::JobFailed {
                failure: FailureClass::UncertainDoNotReplay,
                ..
            }
        )));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn pass_and_payment_are_queryable_from_ledger() {
        let path = temp_journal("ledger");
        let config = test_config();
        let (mut core, _) = ServiceCore::create_or_open(&path, config, 1).unwrap();
        core.enqueue_request("req-2", "Payingone", "hyjal", "+ hyjal", 10)
            .unwrap();
        let activation = core
            .activate_next(&ResourceKey("summon/hyjal".into()), 20)
            .unwrap();
        core.settle_job(&activation.job.job_id, ExecutorOutcome::Pass, 30, "teleport complete")
            .unwrap();
        core.record_payment_observed("req-2", "Payingone", 40_000, 40)
            .unwrap();
        core.record_payment_settled("req-2", "Payingone", 40_000, 50)
            .unwrap();
        let rows = core.ledger_for_player("payingone");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].summon_state, "completed");
        assert_eq!(rows[0].payment_observed_copper, 40_000);
        assert_eq!(rows[0].payment_settled_copper, 40_000);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn safe_pre_active_failure_requeues_same_request() {
        let path = temp_journal("safe-retry");
        let config = test_config();
        let (mut core, _) = ServiceCore::create_or_open(&path, config, 1).unwrap();
        core.enqueue_request("req-3", "Retryme", "winterspring", "winterspring", 10)
            .unwrap();
        let activation = core
            .activate_next(&ResourceKey("summon/winterspring".into()), 20)
            .unwrap();
        core.settle_job(
            &activation.job.job_id,
            ExecutorOutcome::SafePreActiveFailure,
            30,
            "acceptors never reached ready gate",
        )
        .unwrap();
        assert_eq!(core.queue().position("req-3"), Some(1));
        assert!(core.active_jobs().is_empty());
        let _ = fs::remove_file(path);
    }
}
