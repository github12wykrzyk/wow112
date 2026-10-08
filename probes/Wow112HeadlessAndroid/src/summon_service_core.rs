use crate::tele08_bc_adapter::classification_to_request;
use crate::tele08_whisper_parser::{
    classify_whisper, ParserConfig, WhisperIntent, WhisperObservation,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use tele08_request_queue::{
    FailureDisposition, QueueConfig, QueueEngine, QueueEvent, ResourceKey, SummonRequest,
};

pub const SERVICE_SCHEMA_VERSION: u32 = 1;
pub const DEFAULT_MAX_EVENTS: usize = 2048;
pub const DEFAULT_MAX_REQUESTS: usize = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceState {
    Starting,
    Ready,
    Paused,
    Draining,
    BlockedUncertain,
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestPhase {
    Queued,
    Inviting,
    RitualCommitted,
    PortalCommitted,
    AwaitingPayment,
    Completed,
    Failed,
    BlockedUncertain,
}

impl RequestPhase {
    fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::BlockedUncertain
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredEvent {
    pub schema_version: u32,
    pub event_id: String,
    pub ts_utc: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub session_id: String,
    pub request_id: String,
    pub customer: String,
    pub destination: String,
    pub state: String,
    pub amount_copper: u64,
    pub correlation_id: String,
    pub severity: String,
    pub metadata: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DurableRequest {
    pub request_id: String,
    pub customer: String,
    pub destination: String,
    pub received_at_ms: u64,
    pub trigger_message: String,
    pub parser_fingerprint: String,
    pub phase: RequestPhase,
    pub attempt: u32,
    pub mutation_committed: bool,
    pub summon_completed: bool,
    pub payment_received_copper: u64,
    pub correlation_id: String,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceSnapshot {
    pub schema_version: u32,
    pub session_id: String,
    pub state: ServiceState,
    pub paused: bool,
    pub stopping: bool,
    pub event_sequence: u64,
    pub requests: Vec<DurableRequest>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActiveRuntime {
    request_id: String,
    job_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OperatorCommand {
    Pause,
    Resume,
    ManualWhisper {
        customer: String,
        text: String,
        destination_context: Option<String>,
        now_ms: u64,
    },
    GracefulShutdown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoreError {
    AlreadyActive(String),
    NoActiveRequest,
    WrongActiveRequest { expected: String, got: String },
    RequestMissing(String),
    Queue(String),
    Snapshot(String),
    InvalidTransition {
        request_id: String,
        from: RequestPhase,
        action: &'static str,
    },
}

pub struct SummonServiceCore {
    parser: ParserConfig,
    queue_config: QueueConfig,
    queue: QueueEngine,
    resource: ResourceKey,
    session_id: String,
    state: ServiceState,
    paused: bool,
    stopping: bool,
    event_sequence: u64,
    active: Option<ActiveRuntime>,
    requests: BTreeMap<String, DurableRequest>,
    events: VecDeque<StructuredEvent>,
    max_events: usize,
    max_requests: usize,
}

impl SummonServiceCore {
    pub fn new(
        session_id: impl Into<String>,
        parser: ParserConfig,
        queue_config: QueueConfig,
        resource: ResourceKey,
    ) -> Self {
        let queue = QueueEngine::new(queue_config.clone());
        let mut service = Self {
            parser,
            queue_config,
            queue,
            resource,
            session_id: session_id.into(),
            state: ServiceState::Starting,
            paused: false,
            stopping: false,
            event_sequence: 0,
            active: None,
            requests: BTreeMap::new(),
            events: VecDeque::new(),
            max_events: DEFAULT_MAX_EVENTS,
            max_requests: DEFAULT_MAX_REQUESTS,
        };
        service.emit(
            "ServiceStarted",
            "",
            "",
            "",
            "starting",
            0,
            "",
            "info",
            BTreeMap::new(),
            0,
        );
        service.state = ServiceState::Ready;
        service.emit(
            "SessionReady",
            "",
            "",
            "",
            "ready",
            0,
            "",
            "info",
            BTreeMap::new(),
            0,
        );
        service
    }

    pub fn with_bounds(mut self, max_events: usize, max_requests: usize) -> Self {
        self.max_events = max_events.max(32);
        self.max_requests = max_requests.max(32);
        self.trim_events();
        self.prune_terminal_history();
        self
    }

    pub fn state(&self) -> ServiceState {
        self.state
    }

    pub fn is_paused(&self) -> bool {
        self.paused
    }

    pub fn is_stopping(&self) -> bool {
        self.stopping
    }

    pub fn active_request_id(&self) -> Option<&str> {
        self.active.as_ref().map(|active| active.request_id.as_str())
    }

    pub fn request(&self, request_id: &str) -> Option<&DurableRequest> {
        self.requests.get(request_id)
    }

    pub fn recent_events(&self) -> impl Iterator<Item = &StructuredEvent> {
        self.events.iter()
    }

    pub fn drain_events(&mut self) -> Vec<StructuredEvent> {
        self.events.drain(..).collect()
    }

    pub fn handle_operator(&mut self, command: OperatorCommand) -> Result<(), CoreError> {
        match command {
            OperatorCommand::Pause => {
                self.paused = true;
                if self.state != ServiceState::BlockedUncertain
                    && self.state != ServiceState::Stopped
                {
                    self.state = ServiceState::Paused;
                }
                Ok(())
            }
            OperatorCommand::Resume => {
                self.paused = false;
                if self.state == ServiceState::Paused {
                    self.state = if self.stopping {
                        ServiceState::Draining
                    } else {
                        ServiceState::Ready
                    };
                }
                Ok(())
            }
            OperatorCommand::ManualWhisper {
                customer,
                text,
                destination_context,
                now_ms,
            } => {
                self.on_whisper(
                    &customer,
                    &text,
                    destination_context.as_deref(),
                    Some("ManualWhisper"),
                    now_ms,
                )?;
                Ok(())
            }
            OperatorCommand::GracefulShutdown => {
                self.stopping = true;
                if self.active.is_none() {
                    self.stop_now(0);
                } else if self.state != ServiceState::BlockedUncertain {
                    self.state = ServiceState::Draining;
                }
                Ok(())
            }
        }
    }

    pub fn on_whisper(
        &mut self,
        customer: &str,
        text: &str,
        destination_context: Option<&str>,
        source_role: Option<&str>,
        now_ms: u64,
    ) -> Result<Option<String>, CoreError> {
        let mut received_meta = BTreeMap::new();
        received_meta.insert("text".into(), text.to_string());
        if let Some(source_role) = source_role {
            received_meta.insert("source_role".into(), source_role.to_string());
        }
        self.emit(
            "WhisperReceived",
            "",
            customer,
            destination_context.unwrap_or(""),
            "received",
            0,
            "",
            "info",
            received_meta,
            now_ms,
        );

        let classification = classify_whisper(
            &WhisperObservation {
                sender: customer.to_string(),
                text: text.to_string(),
                timestamp_ms: now_ms,
                source_role: source_role.map(ToString::to_string),
                destination_context: destination_context.map(ToString::to_string),
            },
            &self.parser,
        );

        let destination = classification
            .destination
            .as_ref()
            .map(|value| value.0.clone())
            .unwrap_or_default();
        let mut parser_meta = BTreeMap::new();
        parser_meta.insert("intent".into(), format!("{:?}", classification.intent));
        parser_meta.insert("confidence".into(), classification.confidence.to_string());
        parser_meta.insert("reason".into(), classification.reason.clone());
        parser_meta.insert("signals".into(), classification.signals.join("|"));
        self.emit(
            "ParserDecision",
            "",
            customer,
            &destination,
            "classified",
            0,
            "",
            if matches!(classification.intent, WhisperIntent::Unknown) {
                "warning"
            } else {
                "info"
            },
            parser_meta,
            now_ms,
        );

        let request = match classification_to_request(&classification) {
            Ok(request) => request,
            Err(_) => return Ok(None),
        };
        let request_id = request.request_id.clone();
        let outcome = self.queue.enqueue(request.clone());
        if outcome.accepted {
            let durable = durable_from_request(&request, text);
            self.requests.insert(request_id.clone(), durable);
            let mut queue_meta = BTreeMap::new();
            if let Some(position) = queue_position(&outcome.events) {
                queue_meta.insert("position".into(), position.to_string());
            }
            self.emit(
                "RequestQueued",
                &request_id,
                &request.player,
                &request.destination,
                "queued",
                0,
                "",
                "info",
                queue_meta,
                now_ms,
            );
            self.prune_terminal_history();
            Ok(Some(request_id))
        } else if let Some(original) = outcome.duplicate_of {
            Ok(Some(original))
        } else {
            Ok(None)
        }
    }

    pub fn start_next(&mut self, now_ms: u64) -> Result<Option<String>, CoreError> {
        if self.paused || self.stopping || self.state == ServiceState::BlockedUncertain {
            return Ok(None);
        }
        if let Some(active) = &self.active {
            return Err(CoreError::AlreadyActive(active.request_id.clone()));
        }
        let outcome = match self.queue.activate_next(&self.resource, now_ms) {
            Ok(value) => value,
            Err(tele08_request_queue::QueueError::NoEligibleRequest(_)) => return Ok(None),
            Err(error) => return Err(CoreError::Queue(format!("{error:?}"))),
        };
        let job = outcome
            .events
            .iter()
            .find_map(|event| match event {
                QueueEvent::JobActivated { job } => Some(job.clone()),
                _ => None,
            })
            .ok_or_else(|| CoreError::Queue("activation_missing_job_event".into()))?;
        let record = self
            .requests
            .get_mut(&job.request_id)
            .ok_or_else(|| CoreError::RequestMissing(job.request_id.clone()))?;
        record.phase = RequestPhase::Inviting;
        record.attempt = job.attempt;
        let request_id = job.request_id.clone();
        let customer = record.customer.clone();
        let destination = record.destination.clone();
        self.active = Some(ActiveRuntime {
            request_id: request_id.clone(),
            job_id: job.job_id,
        });
        self.emit(
            "SummonStarted",
            &request_id,
            &customer,
            &destination,
            "inviting",
            0,
            "",
            "info",
            BTreeMap::new(),
            now_ms,
        );
        Ok(Some(request_id))
    }

    pub fn mark_ritual_committed(
        &mut self,
        request_id: &str,
        correlation_id: &str,
    ) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let record = self.require_request_mut(request_id)?;
        if record.phase != RequestPhase::Inviting {
            return Err(invalid(record, "mark_ritual_committed"));
        }
        record.phase = RequestPhase::RitualCommitted;
        record.mutation_committed = true;
        record.correlation_id = correlation_id.to_string();
        Ok(())
    }

    pub fn mark_portal_committed(&mut self, request_id: &str) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let record = self.require_request_mut(request_id)?;
        if record.phase != RequestPhase::RitualCommitted {
            return Err(invalid(record, "mark_portal_committed"));
        }
        record.phase = RequestPhase::PortalCommitted;
        record.mutation_committed = true;
        Ok(())
    }

    pub fn mark_summon_completed(
        &mut self,
        request_id: &str,
        now_ms: u64,
    ) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let (customer, destination, correlation_id) = {
            let record = self.require_request_mut(request_id)?;
            if !matches!(
                record.phase,
                RequestPhase::RitualCommitted | RequestPhase::PortalCommitted
            ) {
                return Err(invalid(record, "mark_summon_completed"));
            }
            record.phase = RequestPhase::AwaitingPayment;
            record.summon_completed = true;
            (
                record.customer.clone(),
                record.destination.clone(),
                record.correlation_id.clone(),
            )
        };
        self.emit(
            "SummonCompleted",
            request_id,
            &customer,
            &destination,
            "awaiting_payment",
            0,
            &correlation_id,
            "info",
            BTreeMap::new(),
            now_ms,
        );
        self.emit(
            "PaymentExpected",
            request_id,
            &customer,
            &destination,
            "awaiting_payment",
            0,
            &correlation_id,
            "info",
            BTreeMap::new(),
            now_ms,
        );
        Ok(())
    }

    pub fn mark_payment_received(
        &mut self,
        request_id: &str,
        amount_copper: u64,
        correlation_id: &str,
        now_ms: u64,
    ) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let (customer, destination) = {
            let record = self.require_request_mut(request_id)?;
            if record.phase != RequestPhase::AwaitingPayment {
                return Err(invalid(record, "mark_payment_received"));
            }
            record.payment_received_copper =
                record.payment_received_copper.saturating_add(amount_copper);
            record.correlation_id = correlation_id.to_string();
            record.phase = RequestPhase::Completed;
            (record.customer.clone(), record.destination.clone())
        };
        self.complete_active_queue_job(now_ms)?;
        self.emit(
            "PaymentReceived",
            request_id,
            &customer,
            &destination,
            "completed",
            amount_copper,
            correlation_id,
            "info",
            BTreeMap::new(),
            now_ms,
        );
        self.after_terminal(now_ms);
        Ok(())
    }

    pub fn mark_payment_missing(
        &mut self,
        request_id: &str,
        reason: &str,
        now_ms: u64,
    ) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let (customer, destination, correlation_id) = {
            let record = self.require_request_mut(request_id)?;
            if record.phase != RequestPhase::AwaitingPayment {
                return Err(invalid(record, "mark_payment_missing"));
            }
            record.phase = RequestPhase::Completed;
            record.last_error = Some(reason.to_string());
            (
                record.customer.clone(),
                record.destination.clone(),
                record.correlation_id.clone(),
            )
        };
        self.complete_active_queue_job(now_ms)?;
        let mut metadata = BTreeMap::new();
        metadata.insert("reason".into(), reason.to_string());
        self.emit(
            "PaymentMissing",
            request_id,
            &customer,
            &destination,
            "completed_unpaid",
            0,
            &correlation_id,
            "warning",
            metadata,
            now_ms,
        );
        self.after_terminal(now_ms);
        Ok(())
    }

    pub fn mark_terminal_failure(
        &mut self,
        request_id: &str,
        reason: &str,
        now_ms: u64,
    ) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let (customer, destination, job_id) = {
            let active = self.active.as_ref().ok_or(CoreError::NoActiveRequest)?;
            let job_id = active.job_id.clone();
            let record = self.require_request_mut(request_id)?;
            record.phase = RequestPhase::Failed;
            record.last_error = Some(reason.to_string());
            (
                record.customer.clone(),
                record.destination.clone(),
                job_id,
            )
        };
        self.queue
            .fail(&job_id, FailureDisposition::Terminal, now_ms)
            .map_err(|error| CoreError::Queue(format!("{error:?}")))?;
        self.active = None;
        let mut metadata = BTreeMap::new();
        metadata.insert("reason".into(), reason.to_string());
        self.emit(
            "SummonFailed",
            request_id,
            &customer,
            &destination,
            "failed",
            0,
            "",
            "error",
            metadata,
            now_ms,
        );
        self.after_terminal(now_ms);
        Ok(())
    }

    pub fn mark_uncertain(
        &mut self,
        request_id: &str,
        reason: &str,
        now_ms: u64,
    ) -> Result<(), CoreError> {
        self.require_active(request_id)?;
        let (customer, destination, correlation_id, job_id) = {
            let active = self.active.as_ref().ok_or(CoreError::NoActiveRequest)?;
            let job_id = active.job_id.clone();
            let record = self.require_request_mut(request_id)?;
            record.phase = RequestPhase::BlockedUncertain;
            record.last_error = Some(reason.to_string());
            (
                record.customer.clone(),
                record.destination.clone(),
                record.correlation_id.clone(),
                job_id,
            )
        };
        self.queue
            .fail(
                &job_id,
                FailureDisposition::UncertainDoNotReplay,
                now_ms,
            )
            .map_err(|error| CoreError::Queue(format!("{error:?}")))?;
        self.active = None;
        self.state = ServiceState::BlockedUncertain;
        let mut metadata = BTreeMap::new();
        metadata.insert("reason".into(), reason.to_string());
        metadata.insert("retry_allowed".into(), "false".into());
        self.emit(
            "TradeUncertain",
            request_id,
            &customer,
            &destination,
            "blocked_uncertain",
            0,
            &correlation_id,
            "critical",
            metadata,
            now_ms,
        );
        Ok(())
    }

    pub fn on_reconnect(&mut self, reason: &str, now_ms: u64) -> Result<(), CoreError> {
        let (request_id, customer, destination, phase) = if let Some(active) = &self.active {
            let record = self
                .requests
                .get(&active.request_id)
                .ok_or_else(|| CoreError::RequestMissing(active.request_id.clone()))?;
            (
                record.request_id.clone(),
                record.customer.clone(),
                record.destination.clone(),
                Some(record.phase),
            )
        } else {
            (String::new(), String::new(), String::new(), None)
        };
        let mut metadata = BTreeMap::new();
        metadata.insert("reason".into(), reason.to_string());
        if let Some(phase) = phase {
            metadata.insert("phase".into(), format!("{phase:?}"));
        }
        self.emit(
            "Reconnect",
            &request_id,
            &customer,
            &destination,
            "reconnecting",
            0,
            "",
            "warning",
            metadata,
            now_ms,
        );

        if let Some(phase) = phase {
            if phase != RequestPhase::AwaitingPayment {
                self.mark_uncertain(
                    &request_id,
                    "reconnect_during_active_mutation_window_do_not_replay",
                    now_ms,
                )?;
            }
        }
        Ok(())
    }

    pub fn snapshot(&self) -> ServiceSnapshot {
        let mut requests: Vec<_> = self.requests.values().cloned().collect();
        requests.sort_by_key(|record| (record.received_at_ms, record.request_id.clone()));
        ServiceSnapshot {
            schema_version: SERVICE_SCHEMA_VERSION,
            session_id: self.session_id.clone(),
            state: self.state,
            paused: self.paused,
            stopping: self.stopping,
            event_sequence: self.event_sequence,
            requests,
        }
    }

    pub fn snapshot_json(&self) -> Result<String, CoreError> {
        serde_json::to_string_pretty(&self.snapshot())
            .map_err(|error| CoreError::Snapshot(error.to_string()))
    }

    pub fn restore_json(
        text: &str,
        parser: ParserConfig,
        queue_config: QueueConfig,
        resource: ResourceKey,
        now_ms: u64,
    ) -> Result<Self, CoreError> {
        let snapshot: ServiceSnapshot = serde_json::from_str(text)
            .map_err(|error| CoreError::Snapshot(error.to_string()))?;
        Self::restore(snapshot, parser, queue_config, resource, now_ms)
    }

    pub fn restore(
        snapshot: ServiceSnapshot,
        parser: ParserConfig,
        queue_config: QueueConfig,
        resource: ResourceKey,
        now_ms: u64,
    ) -> Result<Self, CoreError> {
        if snapshot.schema_version != SERVICE_SCHEMA_VERSION {
            return Err(CoreError::Snapshot(format!(
                "unsupported_schema_version={}",
                snapshot.schema_version
            )));
        }

        let mut service = Self {
            parser,
            queue_config: queue_config.clone(),
            queue: QueueEngine::new(queue_config),
            resource,
            session_id: snapshot.session_id,
            state: snapshot.state,
            paused: snapshot.paused,
            stopping: snapshot.stopping,
            event_sequence: snapshot.event_sequence,
            active: None,
            requests: snapshot
                .requests
                .into_iter()
                .map(|record| (record.request_id.clone(), record))
                .collect(),
            events: VecDeque::new(),
            max_events: DEFAULT_MAX_EVENTS,
            max_requests: DEFAULT_MAX_REQUESTS,
        };

        let mut resume_payment = None::<String>;
        let mut queued_ids = Vec::<String>::new();
        let ids: Vec<String> = service.requests.keys().cloned().collect();
        for request_id in &ids {
            let phase = service.requests[request_id].phase;
            match phase {
                RequestPhase::Queued => {
                    queued_ids.push(request_id.clone());
                }
                RequestPhase::AwaitingPayment => {
                    if resume_payment.is_some() {
                        if let Some(record) = service.requests.get_mut(request_id) {
                            record.phase = RequestPhase::BlockedUncertain;
                            record.last_error =
                                Some("multiple_active_requests_in_snapshot".to_string());
                        }
                        service.state = ServiceState::BlockedUncertain;
                    } else {
                        resume_payment = Some(request_id.clone());
                    }
                }
                RequestPhase::Inviting
                | RequestPhase::RitualCommitted
                | RequestPhase::PortalCommitted => {
                    if let Some(record) = service.requests.get_mut(request_id) {
                        record.phase = RequestPhase::BlockedUncertain;
                        record.last_error =
                            Some("restart_during_active_request_do_not_replay".to_string());
                    }
                    service.state = ServiceState::BlockedUncertain;
                }
                RequestPhase::Completed
                | RequestPhase::Failed
                | RequestPhase::BlockedUncertain => {}
            }
        }

        if let Some(request_id) = resume_payment {
            service.enqueue_durable(&request_id, Some(0))?;
            let outcome = service
                .queue
                .activate_next(&service.resource, now_ms)
                .map_err(|error| CoreError::Queue(format!("{error:?}")))?;
            let job = outcome
                .events
                .iter()
                .find_map(|event| match event {
                    QueueEvent::JobActivated { job } if job.request_id == request_id => {
                        Some(job.clone())
                    }
                    _ => None,
                })
                .ok_or_else(|| {
                    CoreError::Snapshot(
                        "could_not_restore_awaiting_payment_as_active".to_string(),
                    )
                })?;
            service.active = Some(ActiveRuntime {
                request_id,
                job_id: job.job_id,
            });
        }

        for request_id in queued_ids {
            service.enqueue_durable(&request_id, None)?;
        }

        let restored_active = service.active_request_id().unwrap_or("").to_string();
        service.emit(
            "Reconnect",
            &restored_active,
            "",
            "",
            "restored",
            0,
            "",
            "warning",
            BTreeMap::from([("reason".into(), "process_restart".into())]),
            now_ms,
        );
        Ok(service)
    }

    fn enqueue_durable(
        &mut self,
        request_id: &str,
        override_received_at: Option<u64>,
    ) -> Result<(), CoreError> {
        let record = self
            .requests
            .get(request_id)
            .ok_or_else(|| CoreError::RequestMissing(request_id.to_string()))?;
        let mut request = SummonRequest::new(
            record.request_id.clone(),
            record.customer.clone(),
            record.destination.clone(),
            override_received_at.unwrap_or(record.received_at_ms),
        );
        request.metadata.insert(
            "parser_fingerprint".into(),
            record.parser_fingerprint.clone(),
        );
        let outcome = self.queue.enqueue(request);
        if !outcome.accepted && outcome.duplicate_of.is_none() {
            return Err(CoreError::Queue(format!(
                "restore_enqueue_rejected request_id={request_id}"
            )));
        }
        Ok(())
    }

    fn complete_active_queue_job(&mut self, now_ms: u64) -> Result<(), CoreError> {
        let active = self.active.take().ok_or(CoreError::NoActiveRequest)?;
        self.queue
            .complete(&active.job_id, now_ms)
            .map_err(|error| CoreError::Queue(format!("{error:?}")))?;
        Ok(())
    }

    fn after_terminal(&mut self, now_ms: u64) {
        self.prune_terminal_history();
        self.rebuild_queue_after_terminal();
        if self.stopping && self.active.is_none() {
            self.stop_now(now_ms);
        } else if self.state != ServiceState::BlockedUncertain {
            self.state = if self.paused {
                ServiceState::Paused
            } else {
                ServiceState::Ready
            };
        }
    }

    fn rebuild_queue_after_terminal(&mut self) {
        if self.active.is_some() {
            return;
        }
        self.queue = QueueEngine::new(self.queue_config.clone());
        let ids: Vec<String> = self
            .requests
            .values()
            .filter(|record| record.phase == RequestPhase::Queued)
            .map(|record| record.request_id.clone())
            .collect();
        for request_id in ids {
            let _ = self.enqueue_durable(&request_id, None);
        }
    }

    fn prune_terminal_history(&mut self) {
        if self.requests.len() <= self.max_requests {
            return;
        }
        let mut terminal: Vec<(u64, String)> = self
            .requests
            .values()
            .filter(|record| record.phase.is_terminal())
            .map(|record| (record.received_at_ms, record.request_id.clone()))
            .collect();
        terminal.sort();
        let mut excess = self.requests.len().saturating_sub(self.max_requests);
        for (_, request_id) in terminal {
            if excess == 0 {
                break;
            }
            self.requests.remove(&request_id);
            excess -= 1;
        }
    }

    fn stop_now(&mut self, now_ms: u64) {
        if self.state == ServiceState::Stopped {
            return;
        }
        self.state = ServiceState::Stopped;
        self.emit(
            "ServiceStopped",
            "",
            "",
            "",
            "stopped",
            0,
            "",
            "info",
            BTreeMap::new(),
            now_ms,
        );
    }

    fn require_active(&self, request_id: &str) -> Result<(), CoreError> {
        let active = self.active.as_ref().ok_or(CoreError::NoActiveRequest)?;
        if active.request_id != request_id {
            return Err(CoreError::WrongActiveRequest {
                expected: active.request_id.clone(),
                got: request_id.to_string(),
            });
        }
        Ok(())
    }

    fn require_request_mut(&mut self, request_id: &str) -> Result<&mut DurableRequest, CoreError> {
        self.requests
            .get_mut(request_id)
            .ok_or_else(|| CoreError::RequestMissing(request_id.to_string()))
    }

    #[allow(clippy::too_many_arguments)]
    fn emit(
        &mut self,
        event_type: &str,
        request_id: &str,
        customer: &str,
        destination: &str,
        state: &str,
        amount_copper: u64,
        correlation_id: &str,
        severity: &str,
        metadata: BTreeMap<String, String>,
        now_ms: u64,
    ) {
        self.event_sequence = self.event_sequence.saturating_add(1);
        self.events.push_back(StructuredEvent {
            schema_version: SERVICE_SCHEMA_VERSION,
            event_id: format!("{}:{:012}", self.session_id, self.event_sequence),
            ts_utc: now_ms.to_string(),
            event_type: event_type.to_string(),
            session_id: self.session_id.clone(),
            request_id: request_id.to_string(),
            customer: customer.to_string(),
            destination: destination.to_string(),
            state: state.to_string(),
            amount_copper,
            correlation_id: correlation_id.to_string(),
            severity: severity.to_string(),
            metadata,
        });
        self.trim_events();
    }

    fn trim_events(&mut self) {
        while self.events.len() > self.max_events {
            self.events.pop_front();
        }
    }
}

fn invalid(record: &DurableRequest, action: &'static str) -> CoreError {
    CoreError::InvalidTransition {
        request_id: record.request_id.clone(),
        from: record.phase,
        action,
    }
}

fn durable_from_request(request: &SummonRequest, trigger_message: &str) -> DurableRequest {
    DurableRequest {
        request_id: request.request_id.clone(),
        customer: request.player.clone(),
        destination: request.destination.clone(),
        received_at_ms: request.received_at,
        trigger_message: trigger_message.to_string(),
        parser_fingerprint: request
            .metadata
            .get("parser_fingerprint")
            .cloned()
            .unwrap_or_default(),
        phase: RequestPhase::Queued,
        attempt: 0,
        mutation_committed: false,
        summon_completed: false,
        payment_received_copper: 0,
        correlation_id: String::new(),
        last_error: None,
    }
}

fn queue_position(events: &[QueueEvent]) -> Option<usize> {
    events.iter().find_map(|event| match event {
        QueueEvent::RequestQueued { position, .. } => Some(*position),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tele08_whisper_parser::{DestinationAlias, DestinationKey};

    fn core() -> SummonServiceCore {
        let mut parser = ParserConfig::default();
        parser.destination_aliases = vec![
            DestinationAlias {
                alias: "hyjal".into(),
                key: DestinationKey::new("hyjal"),
            },
            DestinationAlias {
                alias: "winterspring".into(),
                key: DestinationKey::new("winterspring"),
            },
        ];
        let mut queue = QueueConfig::new(10_000, 120_000);
        queue.map_destination_resource("hyjal", ResourceKey::from("summoner-a"));
        queue.map_destination_resource("winterspring", ResourceKey::from("summoner-a"));
        SummonServiceCore::new(
            "test-session",
            parser,
            queue,
            ResourceKey::from("summoner-a"),
        )
    }

    fn add(service: &mut SummonServiceCore, who: &str, dest: &str, at: u64) -> String {
        service
            .on_whisper(who, &format!("{dest} pls"), None, None, at)
            .unwrap()
            .unwrap()
    }

    fn complete_paid(service: &mut SummonServiceCore, request_id: &str, at: u64) {
        service.mark_ritual_committed(request_id, "summon-1").unwrap();
        service.mark_portal_committed(request_id).unwrap();
        service.mark_summon_completed(request_id, at + 1).unwrap();
        service
            .mark_payment_received(request_id, 40_000, "trade-1", at + 2)
            .unwrap();
    }

    #[test]
    fn three_requests_run_sequentially_in_one_process() {
        let mut service = core();
        let ids = vec![
            add(&mut service, "A", "hyjal", 10),
            add(&mut service, "B", "hyjal", 20),
            add(&mut service, "C", "hyjal", 30),
        ];
        for (index, expected) in ids.iter().enumerate() {
            assert_eq!(service.start_next(100 + index as u64).unwrap(), Some(expected.clone()));
            complete_paid(&mut service, expected, 200 + index as u64 * 10);
        }
        assert!(service.active_request_id().is_none());
        for id in ids {
            assert_eq!(service.request(&id).unwrap().phase, RequestPhase::Completed);
        }
    }

    #[test]
    fn queue_five_preserves_fifo_for_one_resource() {
        let mut service = core();
        let ids: Vec<_> = (0..5)
            .map(|index| add(&mut service, &format!("P{index}"), "hyjal", 100 + index))
            .collect();
        for (index, expected) in ids.iter().enumerate() {
            assert_eq!(
                service.start_next(200 + index as u64).unwrap(),
                Some(expected.clone())
            );
            service.mark_ritual_committed(expected, "s").unwrap();
            service.mark_summon_completed(expected, 300 + index as u64).unwrap();
            service
                .mark_payment_missing(expected, "timeout", 400 + index as u64)
                .unwrap();
        }
    }

    #[test]
    fn reconnect_between_requests_is_safe() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.on_reconnect("network", 20).unwrap();
        assert_eq!(service.start_next(30).unwrap(), Some(id));
        assert_ne!(service.state(), ServiceState::BlockedUncertain);
    }

    #[test]
    fn reconnect_during_mutating_request_blocks_replay() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        service.mark_ritual_committed(&id, "summon-x").unwrap();
        service.on_reconnect("socket_lost", 30).unwrap();
        assert_eq!(
            service.request(&id).unwrap().phase,
            RequestPhase::BlockedUncertain
        );
        assert_eq!(service.state(), ServiceState::BlockedUncertain);
        assert!(service.start_next(40).unwrap().is_none());
    }

    #[test]
    fn no_payment_finishes_request_and_allows_next_customer() {
        let mut service = core();
        let first = add(&mut service, "A", "hyjal", 10);
        let second = add(&mut service, "B", "hyjal", 11);
        service.start_next(20).unwrap();
        service.mark_ritual_committed(&first, "s1").unwrap();
        service.mark_summon_completed(&first, 21).unwrap();
        service
            .mark_payment_missing(&first, "payment_timeout", 22)
            .unwrap();
        assert_eq!(service.start_next(23).unwrap(), Some(second));
    }

    #[test]
    fn trade_cancel_is_payment_missing_not_retry_of_summon() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        service.mark_ritual_committed(&id, "s1").unwrap();
        service.mark_summon_completed(&id, 21).unwrap();
        service.mark_payment_missing(&id, "trade_cancel", 22).unwrap();
        let record = service.request(&id).unwrap();
        assert_eq!(record.phase, RequestPhase::Completed);
        assert!(record.summon_completed);
        assert_eq!(record.payment_received_copper, 0);
    }

    #[test]
    fn uncertain_send_hard_stops_without_retry() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        service
            .mark_uncertain(&id, "accept_socket_uncertain", 21)
            .unwrap();
        assert_eq!(service.state(), ServiceState::BlockedUncertain);
        let event = service
            .recent_events()
            .find(|event| event.event_type == "TradeUncertain")
            .unwrap();
        assert_eq!(event.metadata.get("retry_allowed").map(String::as_str), Some("false"));
    }

    #[test]
    fn correct_payment_records_amount_and_event() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        complete_paid(&mut service, &id, 30);
        assert_eq!(service.request(&id).unwrap().payment_received_copper, 40_000);
        assert!(service
            .recent_events()
            .any(|event| event.event_type == "PaymentReceived" && event.amount_copper == 40_000));
    }

    #[test]
    fn awaiting_payment_survives_restart_without_duplicate_summon() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        service.mark_ritual_committed(&id, "summon-proof").unwrap();
        service.mark_summon_completed(&id, 21).unwrap();
        let json = service.snapshot_json().unwrap();

        let mut restored = SummonServiceCore::restore_json(
            &json,
            service.parser.clone(),
            service.queue_config.clone(),
            service.resource.clone(),
            100,
        )
        .unwrap();
        assert_eq!(restored.active_request_id(), Some(id.as_str()));
        assert_eq!(
            restored.request(&id).unwrap().phase,
            RequestPhase::AwaitingPayment
        );
        restored
            .mark_payment_received(&id, 40_000, "trade-after-restart", 101)
            .unwrap();
        assert_eq!(restored.request(&id).unwrap().phase, RequestPhase::Completed);
        assert_eq!(
            restored
                .recent_events()
                .filter(|event| event.event_type == "SummonStarted")
                .count(),
            0
        );
    }

    #[test]
    fn restart_mid_summon_blocks_duplicate_summon() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        service.mark_ritual_committed(&id, "summon-proof").unwrap();
        let snapshot = service.snapshot();
        let restored = SummonServiceCore::restore(
            snapshot,
            service.parser.clone(),
            service.queue_config.clone(),
            service.resource.clone(),
            100,
        )
        .unwrap();
        assert_eq!(
            restored.request(&id).unwrap().phase,
            RequestPhase::BlockedUncertain
        );
    }

    #[test]
    fn graceful_stop_idle_stops_immediately() {
        let mut service = core();
        service
            .handle_operator(OperatorCommand::GracefulShutdown)
            .unwrap();
        assert_eq!(service.state(), ServiceState::Stopped);
    }

    #[test]
    fn graceful_stop_during_active_drains_then_stops() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.start_next(20).unwrap();
        service
            .handle_operator(OperatorCommand::GracefulShutdown)
            .unwrap();
        assert_eq!(service.state(), ServiceState::Draining);
        service.mark_ritual_committed(&id, "s").unwrap();
        service.mark_summon_completed(&id, 21).unwrap();
        service.mark_payment_missing(&id, "timeout", 22).unwrap();
        assert_eq!(service.state(), ServiceState::Stopped);
    }

    #[test]
    fn bounded_event_memory_discards_oldest_events() {
        let mut service = core().with_bounds(32, 64);
        for index in 0..100 {
            let _ = service.on_whisper(
                &format!("Noise{index}"),
                "hello",
                None,
                None,
                index,
            );
        }
        assert!(service.recent_events().count() <= 32);
    }

    #[test]
    fn pause_resume_blocks_only_new_activation() {
        let mut service = core();
        let id = add(&mut service, "A", "hyjal", 10);
        service.handle_operator(OperatorCommand::Pause).unwrap();
        assert!(service.start_next(20).unwrap().is_none());
        service.handle_operator(OperatorCommand::Resume).unwrap();
        assert_eq!(service.start_next(21).unwrap(), Some(id));
    }
}
