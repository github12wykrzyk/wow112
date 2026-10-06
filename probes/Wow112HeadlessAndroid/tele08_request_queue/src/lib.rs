use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub type Timestamp = u64;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ResourceKey(pub String);

impl From<&str> for ResourceKey {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SummonRequest {
    pub request_id: String,
    pub player: String,
    pub destination: String,
    pub received_at: Timestamp,
    pub metadata: BTreeMap<String, String>,
}

impl SummonRequest {
    pub fn new(
        request_id: impl Into<String>,
        player: impl Into<String>,
        destination: impl Into<String>,
        received_at: Timestamp,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            player: player.into(),
            destination: destination.into(),
            received_at,
            metadata: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleState {
    Received,
    Queued,
    Active,
    Completed,
    Failed,
    Cancelled,
    Expired,
    BlockedReconciliation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureDisposition {
    RetryableSafe,
    Terminal,
    UncertainDoNotReplay,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RejectionReason {
    UnknownDestination,
    RequestIdConflict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestRecord {
    pub request: SummonRequest,
    pub state: LifecycleState,
    pub last_seen_at: Timestamp,
    pub sequence: u64,
    pub attempts: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveJob {
    pub job_id: String,
    pub request_id: String,
    pub destination: String,
    pub resource: ResourceKey,
    pub attempt: u32,
    pub activated_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueEvent {
    RequestAccepted { request_id: String },
    RequestRejected { request_id: String, reason: RejectionReason },
    DuplicateSuppressed { original_request_id: String, incoming_request_id: String },
    RequestQueued { request_id: String, destination: String, position: usize },
    RequestCancelled { request_id: String },
    RequestExpired { request_id: String },
    JobActivated { job: ActiveJob },
    JobCompleted { job_id: String, request_id: String },
    JobFailed { job_id: String, request_id: String, disposition: FailureDisposition },
    JobBlockedUncertain { job_id: String, request_id: String },
    QueuePositionChanged {
        request_id: String,
        destination: String,
        old_position: Option<usize>,
        new_position: Option<usize>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransitionCause {
    Accepted,
    Enqueued,
    Activated { job_id: String, resource: ResourceKey },
    Completed { job_id: String },
    RetryableFailure { job_id: String },
    RetryQueued { job_id: String },
    TerminalFailure { job_id: String },
    UncertainFailure { job_id: String },
    Cancelled,
    Expired,
    RestoredActiveBlocked { job_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditEntry {
    pub at: Timestamp,
    pub request_id: String,
    pub from: Option<LifecycleState>,
    pub to: LifecycleState,
    pub cause: TransitionCause,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueConfig {
    pub dedup_window: Timestamp,
    pub expiry: Timestamp,
    destination_resources: BTreeMap<String, Vec<ResourceKey>>,
}

impl QueueConfig {
    pub fn new(dedup_window: Timestamp, expiry: Timestamp) -> Self {
        Self { dedup_window, expiry, destination_resources: BTreeMap::new() }
    }

    pub fn map_destination_resource(
        &mut self,
        destination: impl Into<String>,
        resource: impl Into<ResourceKey>,
    ) -> &mut Self {
        let resources = self.destination_resources.entry(destination.into()).or_default();
        resources.push(resource.into());
        resources.sort();
        resources.dedup();
        self
    }

    pub fn resources_for(&self, destination: &str) -> &[ResourceKey] {
        self.destination_resources.get(destination).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn destination_is_configured(&self, destination: &str) -> bool {
        !self.resources_for(destination).is_empty()
    }

    fn resource_allows_destination(&self, resource: &ResourceKey, destination: &str) -> bool {
        self.resources_for(destination).binary_search(resource).is_ok()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CancelSelector {
    RequestId(String),
    PlayerDestination { player: String, destination: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnqueueOutcome {
    pub effective_request_id: Option<String>,
    pub accepted: bool,
    pub duplicate_of: Option<String>,
    pub events: Vec<QueueEvent>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutcome {
    pub affected_request_id: Option<String>,
    pub events: Vec<QueueEvent>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueError {
    RequestNotFound(String),
    RequestNotQueued(String),
    ActiveJobNotFound(String),
    ResourceBusy(ResourceKey),
    NoEligibleRequest(ResourceKey),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InvariantViolation {
    RequestMapKeyMismatch(String),
    DuplicateQueueEntry(String),
    QueueRecordMissing(String),
    QueueStateMismatch(String),
    QueueDestinationMismatch(String),
    QueuedRecordMissingFromQueue(String),
    ActiveRecordMissing(String),
    ActiveStateMismatch(String),
    ActiveResourceMismatch(String),
    ActiveDestinationMismatch(String),
    ActiveRecordCount(String),
    ActiveOnUnconfiguredResource(String),
    TerminalRecordInLiveStructure(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RestoreError {
    UnsupportedVersion(u32),
    InvalidSnapshot(InvariantViolation),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueSnapshot {
    pub version: u32,
    pub config: QueueConfig,
    pub requests: BTreeMap<String, RequestRecord>,
    pub queues: BTreeMap<String, VecDeque<String>>,
    pub active_by_resource: BTreeMap<ResourceKey, ActiveJob>,
    pub audit: Vec<AuditEntry>,
    pub next_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueEngine {
    config: QueueConfig,
    requests: BTreeMap<String, RequestRecord>,
    queues: BTreeMap<String, VecDeque<String>>,
    active_by_resource: BTreeMap<ResourceKey, ActiveJob>,
    audit: Vec<AuditEntry>,
    next_sequence: u64,
}

impl QueueEngine {
    pub fn new(config: QueueConfig) -> Self {
        Self {
            config,
            requests: BTreeMap::new(),
            queues: BTreeMap::new(),
            active_by_resource: BTreeMap::new(),
            audit: Vec::new(),
            next_sequence: 0,
        }
    }

    pub fn config(&self) -> &QueueConfig { &self.config }
    pub fn request(&self, request_id: &str) -> Option<&RequestRecord> { self.requests.get(request_id) }
    pub fn audit_log(&self) -> &[AuditEntry] { &self.audit }

    pub fn enqueue(&mut self, request: SummonRequest) -> EnqueueOutcome {
        if let Some(existing) = self.requests.get(&request.request_id) {
            if existing.request.player != request.player || existing.request.destination != request.destination {
                return EnqueueOutcome {
                    effective_request_id: None,
                    accepted: false,
                    duplicate_of: None,
                    events: vec![QueueEvent::RequestRejected {
                        request_id: request.request_id,
                        reason: RejectionReason::RequestIdConflict,
                    }],
                };
            }
            let original_id = existing.request.request_id.clone();
            let incoming_id = request.request_id.clone();
            let last_seen = existing.last_seen_at.max(request.received_at);
            if let Some(record) = self.requests.get_mut(&original_id) { record.last_seen_at = last_seen; }
            return EnqueueOutcome {
                effective_request_id: Some(original_id.clone()),
                accepted: false,
                duplicate_of: Some(original_id.clone()),
                events: vec![QueueEvent::DuplicateSuppressed {
                    original_request_id: original_id,
                    incoming_request_id: incoming_id,
                }],
            };
        }

        if !self.config.destination_is_configured(&request.destination) {
            return EnqueueOutcome {
                effective_request_id: None,
                accepted: false,
                duplicate_of: None,
                events: vec![QueueEvent::RequestRejected {
                    request_id: request.request_id,
                    reason: RejectionReason::UnknownDestination,
                }],
            };
        }

        if let Some(original_id) = self.find_duplicate(&request) {
            let incoming_id = request.request_id.clone();
            if let Some(record) = self.requests.get_mut(&original_id) {
                record.last_seen_at = record.last_seen_at.max(request.received_at);
            }
            return EnqueueOutcome {
                effective_request_id: Some(original_id.clone()),
                accepted: false,
                duplicate_of: Some(original_id.clone()),
                events: vec![QueueEvent::DuplicateSuppressed {
                    original_request_id: original_id,
                    incoming_request_id: incoming_id,
                }],
            };
        }

        let request_id = request.request_id.clone();
        let destination = request.destination.clone();
        let at = request.received_at;
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.requests.insert(request_id.clone(), RequestRecord {
            request,
            state: LifecycleState::Received,
            last_seen_at: at,
            sequence,
            attempts: 0,
        });
        self.audit.push(AuditEntry {
            at,
            request_id: request_id.clone(),
            from: None,
            to: LifecycleState::Received,
            cause: TransitionCause::Accepted,
        });
        self.transition(&request_id, LifecycleState::Queued, at, TransitionCause::Enqueued);
        self.queues.entry(destination.clone()).or_default().push_back(request_id.clone());
        let position = self.position(&request_id).expect("new request is queued");
        EnqueueOutcome {
            effective_request_id: Some(request_id.clone()),
            accepted: true,
            duplicate_of: None,
            events: vec![
                QueueEvent::RequestAccepted { request_id: request_id.clone() },
                QueueEvent::RequestQueued { request_id: request_id.clone(), destination: destination.clone(), position },
                QueueEvent::QueuePositionChanged {
                    request_id,
                    destination,
                    old_position: None,
                    new_position: Some(position),
                },
            ],
        }
    }

    pub fn cancel(&mut self, selector: CancelSelector, now: Timestamp) -> Result<CommandOutcome, QueueError> {
        let request_id = match selector {
            CancelSelector::RequestId(id) => id,
            CancelSelector::PlayerDestination { player, destination } => self.requests.values()
                .filter(|record| {
                    record.state == LifecycleState::Queued
                        && record.request.player == player
                        && record.request.destination == destination
                })
                .min_by_key(|record| (record.sequence, record.request.request_id.clone()))
                .map(|record| record.request.request_id.clone())
                .ok_or_else(|| QueueError::RequestNotFound(format!("{player}@{destination}")))?,
        };
        let record = self.requests.get(&request_id)
            .ok_or_else(|| QueueError::RequestNotFound(request_id.clone()))?;
        if record.state != LifecycleState::Queued { return Err(QueueError::RequestNotQueued(request_id)); }
        let destination = record.request.destination.clone();
        let before = self.positions_for_destination(&destination);
        self.remove_from_queue(&destination, &request_id);
        self.transition(&request_id, LifecycleState::Cancelled, now, TransitionCause::Cancelled);
        let after = self.positions_for_destination(&destination);
        let mut events = vec![QueueEvent::RequestCancelled { request_id: request_id.clone() }];
        events.extend(self.position_change_events(&destination, before, after));
        Ok(CommandOutcome { affected_request_id: Some(request_id), events })
    }

    pub fn activate_next(&mut self, resource: &ResourceKey, now: Timestamp) -> Result<CommandOutcome, QueueError> {
        if self.active_by_resource.contains_key(resource) { return Err(QueueError::ResourceBusy(resource.clone())); }
        let request_id = self.select_next_request_id(resource)
            .ok_or_else(|| QueueError::NoEligibleRequest(resource.clone()))?;
        let destination = self.requests[&request_id].request.destination.clone();
        let before = self.positions_for_destination(&destination);
        self.remove_from_queue(&destination, &request_id);
        let attempt = {
            let record = self.requests.get_mut(&request_id).expect("selected request exists");
            record.attempts = record.attempts.saturating_add(1);
            record.attempts
        };
        let job = ActiveJob {
            job_id: format!("job:{request_id}:{attempt}"),
            request_id: request_id.clone(),
            destination: destination.clone(),
            resource: resource.clone(),
            attempt,
            activated_at: now,
        };
        self.transition(
            &request_id,
            LifecycleState::Active,
            now,
            TransitionCause::Activated { job_id: job.job_id.clone(), resource: resource.clone() },
        );
        self.active_by_resource.insert(resource.clone(), job.clone());
        let after = self.positions_for_destination(&destination);
        let mut events = vec![QueueEvent::JobActivated { job }];
        events.extend(self.position_change_events(&destination, before, after));
        Ok(CommandOutcome { affected_request_id: Some(request_id), events })
    }

    pub fn complete(&mut self, active_job_id: &str, now: Timestamp) -> Result<CommandOutcome, QueueError> {
        let (_resource, job) = self.take_active_job(active_job_id)?;
        self.transition(
            &job.request_id,
            LifecycleState::Completed,
            now,
            TransitionCause::Completed { job_id: job.job_id.clone() },
        );
        Ok(CommandOutcome {
            affected_request_id: Some(job.request_id.clone()),
            events: vec![QueueEvent::JobCompleted { job_id: job.job_id, request_id: job.request_id }],
        })
    }

    pub fn fail(
        &mut self,
        active_job_id: &str,
        disposition: FailureDisposition,
        now: Timestamp,
    ) -> Result<CommandOutcome, QueueError> {
        let (_resource, job) = self.take_active_job(active_job_id)?;
        let request_id = job.request_id.clone();
        let destination = job.destination.clone();
        let mut events = vec![QueueEvent::JobFailed {
            job_id: job.job_id.clone(),
            request_id: request_id.clone(),
            disposition,
        }];
        match disposition {
            FailureDisposition::RetryableSafe => {
                self.transition(
                    &request_id,
                    LifecycleState::Failed,
                    now,
                    TransitionCause::RetryableFailure { job_id: job.job_id.clone() },
                );
                let before = self.positions_for_destination(&destination);
                self.transition(
                    &request_id,
                    LifecycleState::Queued,
                    now,
                    TransitionCause::RetryQueued { job_id: job.job_id },
                );
                self.queues.entry(destination.clone()).or_default().push_front(request_id.clone());
                let position = self.position(&request_id).expect("retry was requeued");
                events.push(QueueEvent::RequestQueued {
                    request_id: request_id.clone(),
                    destination: destination.clone(),
                    position,
                });
                let after = self.positions_for_destination(&destination);
                events.extend(self.position_change_events(&destination, before, after));
            }
            FailureDisposition::Terminal => {
                self.transition(
                    &request_id,
                    LifecycleState::Failed,
                    now,
                    TransitionCause::TerminalFailure { job_id: job.job_id },
                );
            }
            FailureDisposition::UncertainDoNotReplay => {
                self.transition(
                    &request_id,
                    LifecycleState::BlockedReconciliation,
                    now,
                    TransitionCause::UncertainFailure { job_id: job.job_id.clone() },
                );
                events.push(QueueEvent::JobBlockedUncertain { job_id: job.job_id, request_id: request_id.clone() });
            }
        }
        Ok(CommandOutcome { affected_request_id: Some(request_id), events })
    }

    pub fn expire(&mut self, now: Timestamp) -> CommandOutcome {
        let mut expired: Vec<(String, String, u64)> = self.requests.values()
            .filter(|record| {
                record.state == LifecycleState::Queued
                    && now.saturating_sub(record.last_seen_at) >= self.config.expiry
            })
            .map(|record| (
                record.request.request_id.clone(),
                record.request.destination.clone(),
                record.sequence,
            ))
            .collect();
        expired.sort_by_key(|(id, destination, sequence)| (destination.clone(), *sequence, id.clone()));
        let touched: BTreeSet<String> = expired.iter().map(|(_, destination, _)| destination.clone()).collect();
        let before: BTreeMap<String, BTreeMap<String, usize>> = touched.iter()
            .map(|destination| (destination.clone(), self.positions_for_destination(destination)))
            .collect();
        let mut events = Vec::new();
        for (request_id, destination, _) in &expired {
            self.remove_from_queue(destination, request_id);
            self.transition(request_id, LifecycleState::Expired, now, TransitionCause::Expired);
            events.push(QueueEvent::RequestExpired { request_id: request_id.clone() });
        }
        for destination in touched {
            let after = self.positions_for_destination(&destination);
            let old = before.get(&destination).cloned().unwrap_or_default();
            events.extend(self.position_change_events(&destination, old, after));
        }
        CommandOutcome { affected_request_id: None, events }
    }

    pub fn position(&self, request_id: &str) -> Option<usize> {
        let record = self.requests.get(request_id)?;
        if record.state != LifecycleState::Queued { return None; }
        self.queues.get(&record.request.destination)?
            .iter().position(|id| id == request_id).map(|index| index + 1)
    }

    pub fn queued_count_by_destination(&self, destination: &str) -> usize {
        self.queues.get(destination).map(VecDeque::len).unwrap_or(0)
    }

    pub fn active_job_by_resource(&self, resource: &ResourceKey) -> Option<&ActiveJob> {
        self.active_by_resource.get(resource)
    }

    pub fn next_eligible_request(&self, resource: &ResourceKey) -> Option<RequestRecord> {
        self.select_next_request_id(resource).and_then(|id| self.requests.get(&id).cloned())
    }

    pub fn snapshot(&self) -> QueueSnapshot {
        QueueSnapshot {
            version: 1,
            config: self.config.clone(),
            requests: self.requests.clone(),
            queues: self.queues.clone(),
            active_by_resource: self.active_by_resource.clone(),
            audit: self.audit.clone(),
            next_sequence: self.next_sequence,
        }
    }

    pub fn restore(snapshot: QueueSnapshot, now: Timestamp) -> Result<(Self, Vec<QueueEvent>), RestoreError> {
        if snapshot.version != 1 { return Err(RestoreError::UnsupportedVersion(snapshot.version)); }
        let mut engine = Self {
            config: snapshot.config,
            requests: snapshot.requests,
            queues: snapshot.queues,
            active_by_resource: snapshot.active_by_resource,
            audit: snapshot.audit,
            next_sequence: snapshot.next_sequence,
        };
        engine.validate_invariants().map_err(RestoreError::InvalidSnapshot)?;
        if let Some(max_sequence) = engine.requests.values().map(|r| r.sequence).max() {
            engine.next_sequence = engine.next_sequence.max(max_sequence.saturating_add(1));
        }
        let active_jobs: Vec<ActiveJob> = engine.active_by_resource.values().cloned().collect();
        engine.active_by_resource.clear();
        let mut events = Vec::new();
        for job in active_jobs {
            engine.transition(
                &job.request_id,
                LifecycleState::BlockedReconciliation,
                now,
                TransitionCause::RestoredActiveBlocked { job_id: job.job_id.clone() },
            );
            events.push(QueueEvent::JobBlockedUncertain { job_id: job.job_id, request_id: job.request_id });
        }
        engine.validate_invariants().map_err(RestoreError::InvalidSnapshot)?;
        Ok((engine, events))
    }

    pub fn validate_invariants(&self) -> Result<(), InvariantViolation> {
        let mut queued_ids = BTreeSet::new();
        for (destination, queue) in &self.queues {
            for request_id in queue {
                if !queued_ids.insert(request_id.clone()) {
                    return Err(InvariantViolation::DuplicateQueueEntry(request_id.clone()));
                }
                let record = self.requests.get(request_id)
                    .ok_or_else(|| InvariantViolation::QueueRecordMissing(request_id.clone()))?;
                if record.state != LifecycleState::Queued {
                    return Err(InvariantViolation::QueueStateMismatch(request_id.clone()));
                }
                if record.request.destination != *destination {
                    return Err(InvariantViolation::QueueDestinationMismatch(request_id.clone()));
                }
            }
        }

        let mut active_counts: BTreeMap<String, usize> = BTreeMap::new();
        for (resource, job) in &self.active_by_resource {
            if &job.resource != resource {
                return Err(InvariantViolation::ActiveResourceMismatch(job.request_id.clone()));
            }
            let record = self.requests.get(&job.request_id)
                .ok_or_else(|| InvariantViolation::ActiveRecordMissing(job.request_id.clone()))?;
            if record.state != LifecycleState::Active {
                return Err(InvariantViolation::ActiveStateMismatch(job.request_id.clone()));
            }
            if record.request.destination != job.destination {
                return Err(InvariantViolation::ActiveDestinationMismatch(job.request_id.clone()));
            }
            if !self.config.resource_allows_destination(resource, &job.destination) {
                return Err(InvariantViolation::ActiveOnUnconfiguredResource(job.request_id.clone()));
            }
            *active_counts.entry(job.request_id.clone()).or_default() += 1;
        }

        for (request_id, record) in &self.requests {
            if record.request.request_id != *request_id {
                return Err(InvariantViolation::RequestMapKeyMismatch(request_id.clone()));
            }
            match record.state {
                LifecycleState::Queued => {
                    if !queued_ids.contains(request_id) {
                        return Err(InvariantViolation::QueuedRecordMissingFromQueue(request_id.clone()));
                    }
                    if active_counts.contains_key(request_id) {
                        return Err(InvariantViolation::TerminalRecordInLiveStructure(request_id.clone()));
                    }
                }
                LifecycleState::Active => {
                    if active_counts.get(request_id).copied().unwrap_or(0) != 1 {
                        return Err(InvariantViolation::ActiveRecordCount(request_id.clone()));
                    }
                    if queued_ids.contains(request_id) {
                        return Err(InvariantViolation::TerminalRecordInLiveStructure(request_id.clone()));
                    }
                }
                LifecycleState::Completed
                | LifecycleState::Cancelled
                | LifecycleState::Expired
                | LifecycleState::BlockedReconciliation
                | LifecycleState::Failed
                | LifecycleState::Received => {
                    if queued_ids.contains(request_id) || active_counts.contains_key(request_id) {
                        return Err(InvariantViolation::TerminalRecordInLiveStructure(request_id.clone()));
                    }
                }
            }
        }
        Ok(())
    }

    fn find_duplicate(&self, request: &SummonRequest) -> Option<String> {
        self.requests.values()
            .filter(|record| {
                record.request.player == request.player
                    && record.request.destination == request.destination
                    && request.received_at.saturating_sub(record.last_seen_at) <= self.config.dedup_window
            })
            .max_by_key(|record| (record.last_seen_at, record.sequence, record.request.request_id.clone()))
            .map(|record| record.request.request_id.clone())
    }

    fn select_next_request_id(&self, resource: &ResourceKey) -> Option<String> {
        self.queues.iter()
            .filter(|(destination, queue)| !queue.is_empty() && self.config.resource_allows_destination(resource, destination))
            .filter_map(|(_, queue)| queue.front())
            .filter_map(|request_id| self.requests.get(request_id))
            .min_by_key(|record| (record.request.received_at, record.sequence, record.request.request_id.clone()))
            .map(|record| record.request.request_id.clone())
    }

    fn transition(&mut self, request_id: &str, to: LifecycleState, at: Timestamp, cause: TransitionCause) {
        let from = {
            let record = self.requests.get_mut(request_id).expect("transition request must exist");
            let from = record.state;
            record.state = to;
            from
        };
        self.audit.push(AuditEntry {
            at,
            request_id: request_id.to_owned(),
            from: Some(from),
            to,
            cause,
        });
    }

    fn take_active_job(&mut self, active_job_id: &str) -> Result<(ResourceKey, ActiveJob), QueueError> {
        let resource = self.active_by_resource.iter()
            .find(|(_, job)| job.job_id == active_job_id)
            .map(|(resource, _)| resource.clone())
            .ok_or_else(|| QueueError::ActiveJobNotFound(active_job_id.to_owned()))?;
        let job = self.active_by_resource.remove(&resource).expect("located active job exists");
        Ok((resource, job))
    }

    fn remove_from_queue(&mut self, destination: &str, request_id: &str) {
        let remove_destination = if let Some(queue) = self.queues.get_mut(destination) {
            if let Some(index) = queue.iter().position(|id| id == request_id) { queue.remove(index); }
            queue.is_empty()
        } else { false };
        if remove_destination { self.queues.remove(destination); }
    }

    fn positions_for_destination(&self, destination: &str) -> BTreeMap<String, usize> {
        self.queues.get(destination)
            .map(|queue| queue.iter().enumerate().map(|(index, id)| (id.clone(), index + 1)).collect())
            .unwrap_or_default()
    }

    fn position_change_events(
        &self,
        destination: &str,
        before: BTreeMap<String, usize>,
        after: BTreeMap<String, usize>,
    ) -> Vec<QueueEvent> {
        let ids: BTreeSet<String> = before.keys().chain(after.keys()).cloned().collect();
        ids.into_iter().filter_map(|request_id| {
            let old_position = before.get(&request_id).copied();
            let new_position = after.get(&request_id).copied();
            (old_position != new_position).then(|| QueueEvent::QueuePositionChanged {
                request_id,
                destination: destination.to_owned(),
                old_position,
                new_position,
            })
        }).collect()
    }
}
