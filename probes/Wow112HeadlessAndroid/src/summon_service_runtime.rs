use crate::summon_service_core::{
    CoreError, DurableRequest, OperatorCommand, RequestPhase, SummonServiceCore,
};
use crate::tele08_whisper_parser::ParserConfig;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use tele08_request_queue::{QueueConfig, ResourceKey};

#[derive(Clone, Debug)]
pub struct ServiceRuntimeConfig {
    pub state_path: PathBuf,
    pub events_path: PathBuf,
    pub session_id: String,
    pub resource: ResourceKey,
    pub destinations: Vec<String>,
    pub dedup_window_ms: u64,
    pub request_expiry_ms: u64,
}

impl ServiceRuntimeConfig {
    pub fn new(root: impl AsRef<Path>, session_id: impl Into<String>) -> Self {
        let root = root.as_ref();
        Self {
            state_path: root.join("summon_service_state.json"),
            events_path: root.join("summon_service_events.jsonl"),
            session_id: session_id.into(),
            resource: ResourceKey("summoner:default".to_string()),
            destinations: vec![
                "hyjal".to_string(),
                "azshara".to_string(),
                "winterspring".to_string(),
                "hydraxian".to_string(),
            ],
            dedup_window_ms: 10_000,
            request_expiry_ms: 120_000,
        }
    }

    pub fn parser(&self) -> ParserConfig {
        let mut parser = ParserConfig::default();
        if self
            .destinations
            .iter()
            .any(|value| value.eq_ignore_ascii_case("hydraxian"))
        {
            parser = parser
                .with_destination_alias("hydraxian", "hydraxian")
                .with_destination_alias("hydraxian waterlords", "hydraxian")
                .with_destination_alias("hydrax", "hydraxian");
        }
        parser
    }

    pub fn queue_config(&self) -> QueueConfig {
        let mut queue = QueueConfig::new(self.dedup_window_ms, self.request_expiry_ms);
        for destination in &self.destinations {
            queue.map_destination_resource(destination.clone(), self.resource.clone());
        }
        queue
    }
}

pub struct SummonServiceRuntime {
    config: ServiceRuntimeConfig,
    core: SummonServiceCore,
}

impl SummonServiceRuntime {
    pub fn open(config: ServiceRuntimeConfig, now_ms: u64) -> Result<Self, String> {
        ensure_parent(&config.state_path)?;
        ensure_parent(&config.events_path)?;
        let parser = config.parser();
        let queue_config = config.queue_config();
        let core = if config.state_path.exists() {
            let text = fs::read_to_string(&config.state_path).map_err(|error| {
                format!(
                    "read summon service state {} failed: {error}",
                    config.state_path.display()
                )
            })?;
            SummonServiceCore::restore_json(
                &text,
                parser,
                queue_config,
                config.resource.clone(),
                now_ms,
            )
            .map_err(core_error)?
        } else {
            SummonServiceCore::new(
                config.session_id.clone(),
                parser,
                queue_config,
                config.resource.clone(),
            )
        };
        let mut runtime = Self { config, core };
        runtime.persist()?;
        Ok(runtime)
    }

    pub fn core(&self) -> &SummonServiceCore {
        &self.core
    }

    pub fn active_request_id(&self) -> Option<&str> {
        self.core.active_request_id()
    }

    pub fn active_request(&self) -> Option<&DurableRequest> {
        let id = self.core.active_request_id()?;
        self.core.request(id)
    }

    pub fn request(&self, request_id: &str) -> Option<&DurableRequest> {
        self.core.request(request_id)
    }

    pub fn on_whisper(
        &mut self,
        customer: &str,
        text: &str,
        destination_context: Option<&str>,
        source_role: Option<&str>,
        now_ms: u64,
    ) -> Result<Option<String>, String> {
        let result = self
            .core
            .on_whisper(customer, text, destination_context, source_role, now_ms)
            .map_err(core_error)?;
        self.persist()?;
        Ok(result)
    }

    pub fn start_next(&mut self, now_ms: u64) -> Result<Option<String>, String> {
        let result = self.core.start_next(now_ms).map_err(core_error)?;
        self.persist()?;
        Ok(result)
    }

    pub fn mark_ritual_committed(
        &mut self,
        request_id: &str,
        correlation_id: &str,
    ) -> Result<(), String> {
        self.core
            .mark_ritual_committed(request_id, correlation_id)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn mark_portal_committed(&mut self, request_id: &str) -> Result<(), String> {
        self.core
            .mark_portal_committed(request_id)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn mark_summon_completed(
        &mut self,
        request_id: &str,
        now_ms: u64,
    ) -> Result<(), String> {
        let phase = self
            .request(request_id)
            .ok_or_else(|| format!("summon completion request not found: {request_id}"))?
            .phase;
        if phase != RequestPhase::PortalCommitted {
            return Err(format!(
                "summon completion requires portal proof request_id={request_id} phase={phase:?}"
            ));
        }
        self.core
            .mark_summon_completed(request_id, now_ms)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn mark_payment_received(
        &mut self,
        request_id: &str,
        amount_copper: u64,
        correlation_id: &str,
        now_ms: u64,
    ) -> Result<(), String> {
        self.core
            .mark_payment_received(request_id, amount_copper, correlation_id, now_ms)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn mark_payment_missing(
        &mut self,
        request_id: &str,
        reason: &str,
        now_ms: u64,
    ) -> Result<(), String> {
        self.core
            .mark_payment_missing(request_id, reason, now_ms)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn mark_terminal_failure(
        &mut self,
        request_id: &str,
        reason: &str,
        now_ms: u64,
    ) -> Result<(), String> {
        self.core
            .mark_terminal_failure(request_id, reason, now_ms)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn mark_uncertain(
        &mut self,
        request_id: &str,
        reason: &str,
        now_ms: u64,
    ) -> Result<(), String> {
        self.core
            .mark_uncertain(request_id, reason, now_ms)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn on_reconnect(&mut self, reason: &str, now_ms: u64) -> Result<(), String> {
        self.core
            .on_reconnect(reason, now_ms)
            .map_err(core_error)?;
        self.persist()
    }

    pub fn operator(&mut self, command: OperatorCommand) -> Result<(), String> {
        self.core.handle_operator(command).map_err(core_error)?;
        self.persist()
    }

    pub fn persist(&mut self) -> Result<(), String> {
        self.flush_events()?;
        let body = self.core.snapshot_json().map_err(core_error)?;
        atomic_write(&self.config.state_path, body.as_bytes())
    }

    fn flush_events(&mut self) -> Result<(), String> {
        let events = self.core.drain_events();
        if events.is_empty() {
            return Ok(());
        }
        ensure_parent(&self.config.events_path)?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.config.events_path)
            .map_err(|error| {
                format!(
                    "open summon event log {} failed: {error}",
                    self.config.events_path.display()
                )
            })?;
        for event in events {
            let line = serde_json::to_string(&event)
                .map_err(|error| format!("serialize summon event failed: {error}"))?;
            file.write_all(line.as_bytes())
                .and_then(|_| file.write_all(b"\n"))
                .map_err(|error| format!("append summon event failed: {error}"))?;
        }
        file.sync_all()
            .map_err(|error| format!("sync summon event log failed: {error}"))
    }
}

fn core_error(error: CoreError) -> String {
    format!("summon_service_core:{error:?}")
}

fn ensure_parent(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent().filter(|value| !value.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .map_err(|error| format!("create {} failed: {error}", parent.display()))?;
    }
    Ok(())
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}.{}", path.display(), suffix))
}

fn atomic_write(path: &Path, body: &[u8]) -> Result<(), String> {
    ensure_parent(path)?;
    let next = sidecar(path, "next");
    let bak = sidecar(path, "bak");
    {
        let mut file = File::create(&next)
            .map_err(|error| format!("create {} failed: {error}", next.display()))?;
        file.write_all(body)
            .map_err(|error| format!("write {} failed: {error}", next.display()))?;
        file.sync_all()
            .map_err(|error| format!("sync {} failed: {error}", next.display()))?;
    }
    if path.exists() {
        let _ = fs::copy(path, &bak);
        fs::remove_file(path)
            .map_err(|error| format!("remove old {} failed: {error}", path.display()))?;
    }
    fs::rename(&next, path)
        .map_err(|error| format!("commit {} -> {} failed: {error}", next.display(), path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn root(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wow112_summon_service_runtime_{}_{}_{}",
            std::process::id(), stamp, tag
        ))
    }

    #[test]
    fn multi_customer_state_survives_restart() {
        let root = root("multi");
        let config = ServiceRuntimeConfig::new(&root, "session-a");
        let mut runtime = SummonServiceRuntime::open(config.clone(), 1).unwrap();
        let a = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("live"), 10)
            .unwrap()
            .unwrap();
        let b = runtime
            .on_whisper("Clientb", "azshara pls", None, Some("live"), 11)
            .unwrap()
            .unwrap();
        assert_ne!(a, b);
        runtime.start_next(20).unwrap();
        runtime.mark_terminal_failure(&a, "safe_test_failure", 21).unwrap();
        drop(runtime);

        let restored = SummonServiceRuntime::open(config, 30).unwrap();
        assert_eq!(restored.request(&a).unwrap().phase, RequestPhase::Failed);
        assert_eq!(restored.request(&b).unwrap().phase, RequestPhase::Queued);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn restart_after_summon_resumes_payment_only() {
        let root = root("payment_resume");
        let config = ServiceRuntimeConfig::new(&root, "session-b");
        let mut runtime = SummonServiceRuntime::open(config.clone(), 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "winterspring pls", None, Some("live"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        runtime.mark_portal_committed(&id).unwrap();
        runtime.mark_summon_completed(&id, 22).unwrap();
        drop(runtime);

        let restored = SummonServiceRuntime::open(config, 100).unwrap();
        assert_eq!(restored.active_request_id(), Some(id.as_str()));
        assert_eq!(
            restored.request(&id).unwrap().phase,
            RequestPhase::AwaitingPayment
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
fn restart_after_portal_commit_resumes_wait_without_replay() {
    let root = root("portal_resume");
    let config = ServiceRuntimeConfig::new(&root, "session-portal-resume");
    let mut runtime = SummonServiceRuntime::open(config.clone(), 1).unwrap();
    let id = runtime
        .on_whisper("Clienta", "hyjal pls", None, Some("live"), 10)
        .unwrap()
        .unwrap();
    runtime.start_next(20).unwrap();
    runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
    runtime.mark_portal_committed(&id).unwrap();
    drop(runtime);

    let restored = SummonServiceRuntime::open(config, 100).unwrap();
    assert_eq!(restored.active_request_id(), Some(id.as_str()));
    assert_eq!(restored.request(&id).unwrap().phase, RequestPhase::PortalCommitted);
    assert_ne!(restored.core().state(), crate::summon_service_core::ServiceState::BlockedUncertain);
    let _ = fs::remove_dir_all(root);
}

    #[test]
    fn summon_completion_without_portal_proof_is_rejected() {
        let root = root("portal_gate");
        let config = ServiceRuntimeConfig::new(&root, "session-portal-gate");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("live"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        let error = runtime.mark_summon_completed(&id, 22).unwrap_err();
        assert!(error.contains("requires portal proof"));
        assert_eq!(
            runtime.request(&id).unwrap().phase,
            RequestPhase::RitualCommitted
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn restart_mid_mutation_is_hard_blocked() {
        let root = root("blocked");
        let config = ServiceRuntimeConfig::new(&root, "session-c");
        let mut runtime = SummonServiceRuntime::open(config.clone(), 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("live"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        drop(runtime);

        let restored = SummonServiceRuntime::open(config, 100).unwrap();
        assert_eq!(
            restored.request(&id).unwrap().phase,
            RequestPhase::BlockedUncertain
        );
        assert!(restored.active_request_id().is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn events_are_append_only_jsonl() {
        let root = root("events");
        let config = ServiceRuntimeConfig::new(&root, "session-d");
        let mut runtime = SummonServiceRuntime::open(config.clone(), 1).unwrap();
        runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("live"), 10)
            .unwrap();
        runtime.persist().unwrap();
        let raw = fs::read_to_string(&config.events_path).unwrap();
        assert!(raw.lines().count() >= 4);
        for line in raw.lines() {
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            assert!(value.get("type").is_some());
            assert!(value.get("session_id").is_some());
        }
        let _ = fs::remove_dir_all(root);
    }
}
