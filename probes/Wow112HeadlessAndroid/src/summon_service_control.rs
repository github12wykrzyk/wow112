use crate::summon_service_core::{OperatorCommand, RequestPhase, ServiceState};
use crate::summon_service_runtime::SummonServiceRuntime;
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServiceControlCommand {
    Pause,
    Resume,
    ManualWhisper {
        customer: String,
        text: String,
        destination_context: Option<String>,
        now_ms: u64,
    },
    GracefulShutdown {
        now_ms: u64,
    },
    PortalCommitted {
        request_id: String,
    },
    SummonCompleted {
        request_id: String,
        now_ms: u64,
    },
}

#[derive(Clone, Debug)]
pub struct PendingControl {
    pub path: PathBuf,
    pub command: ServiceControlCommand,
}

#[derive(Clone, Debug)]
pub struct ControlInbox {
    inbox: PathBuf,
    done: PathBuf,
}

impl ControlInbox {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref();
        let inbox = root.join("control_inbox");
        let done = root.join("control_done");
        fs::create_dir_all(&inbox)
            .map_err(|e| format!("create control inbox {} failed: {e}", inbox.display()))?;
        fs::create_dir_all(&done)
            .map_err(|e| format!("create control done {} failed: {e}", done.display()))?;
        Ok(Self { inbox, done })
    }

    pub fn next(&self) -> Result<Option<PendingControl>, String> {
        let mut entries = fs::read_dir(&self.inbox)
            .map_err(|e| format!("read control inbox {} failed: {e}", self.inbox.display()))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|v| v.to_str()) == Some("json"))
            .collect::<Vec<_>>();
        entries.sort();
        let Some(path) = entries.into_iter().next() else {
            return Ok(None);
        };
        let raw = fs::read_to_string(&path)
            .map_err(|e| format!("read control {} failed: {e}", path.display()))?;
        let command = serde_json::from_str::<ServiceControlCommand>(&raw)
            .map_err(|e| format!("parse control {} failed: {e}", path.display()))?;
        Ok(Some(PendingControl { path, command }))
    }

    pub fn ack(&self, pending: PendingControl) -> Result<(), String> {
        let file_name = pending
            .path
            .file_name()
            .ok_or_else(|| format!("control path has no filename: {}", pending.path.display()))?;
        let target = self.done.join(file_name);
        if target.exists() {
            fs::remove_file(&pending.path)
                .map_err(|e| format!("remove replayed control {} failed: {e}", pending.path.display()))?;
            return Ok(());
        }
        fs::rename(&pending.path, &target).map_err(|e| {
            format!(
                "ack control {} -> {} failed: {e}",
                pending.path.display(),
                target.display()
            )
        })
    }

    pub fn submit(root: impl AsRef<Path>, command: &ServiceControlCommand) -> Result<PathBuf, String> {
        let control = Self::open(root)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let file_name = format!(
            "{:020}_{:09}_{}_control.json",
            now.as_secs(),
            now.subsec_nanos(),
            std::process::id()
        );
        let target = control.inbox.join(file_name);
        let temp = PathBuf::from(format!("{}.next", target.display()));
        let body = serde_json::to_vec_pretty(command)
            .map_err(|e| format!("serialize control failed: {e}"))?;
        {
            let mut file = File::create(&temp)
                .map_err(|e| format!("create control temp {} failed: {e}", temp.display()))?;
            file.write_all(&body)
                .map_err(|e| format!("write control temp {} failed: {e}", temp.display()))?;
            file.sync_all()
                .map_err(|e| format!("sync control temp {} failed: {e}", temp.display()))?;
        }
        fs::rename(&temp, &target)
            .map_err(|e| format!("publish control {} failed: {e}", target.display()))?;
        Ok(target)
    }
}

pub fn apply_control(
    runtime: &mut SummonServiceRuntime,
    command: &ServiceControlCommand,
) -> Result<(), String> {
    match command {
        ServiceControlCommand::Pause => match runtime.core().state() {
            ServiceState::Ready => runtime.operator(OperatorCommand::Pause),
            ServiceState::Paused => Ok(()),
            state => Err(format!("pause invalid in service state {state:?}")),
        },
        ServiceControlCommand::Resume => match runtime.core().state() {
            ServiceState::Paused => runtime.operator(OperatorCommand::Resume),
            ServiceState::Ready => Ok(()),
            state => Err(format!("resume invalid in service state {state:?}")),
        },
        ServiceControlCommand::ManualWhisper {
            customer,
            text,
            destination_context,
            now_ms,
        } => runtime.operator(OperatorCommand::ManualWhisper {
            customer: customer.clone(),
            text: text.clone(),
            destination_context: destination_context.clone(),
            now_ms: *now_ms,
        }),
        ServiceControlCommand::GracefulShutdown { now_ms } => match runtime.core().state() {
            ServiceState::Draining | ServiceState::Stopped => Ok(()),
            ServiceState::BlockedUncertain => Err(
                "graceful shutdown refused while blocked uncertain; reconciliation required"
                    .to_string(),
            ),
            _ => runtime.operator(OperatorCommand::GracefulShutdown { now_ms: *now_ms }),
        },
        ServiceControlCommand::PortalCommitted { request_id } => {
            let phase = runtime
                .request(request_id)
                .ok_or_else(|| format!("portal evidence request not found: {request_id}"))?
                .phase;
            match phase {
                RequestPhase::RitualCommitted => runtime.mark_portal_committed(request_id),
                RequestPhase::PortalCommitted
                | RequestPhase::AwaitingPayment
                | RequestPhase::Completed => Ok(()),
                other => Err(format!(
                    "portal evidence invalid request_id={request_id} phase={other:?}"
                )),
            }
        }
        ServiceControlCommand::SummonCompleted { request_id, now_ms } => {
            let phase = runtime
                .request(request_id)
                .ok_or_else(|| format!("summon completion request not found: {request_id}"))?
                .phase;
            match phase {
                RequestPhase::PortalCommitted => runtime.mark_summon_completed(request_id, *now_ms),
                RequestPhase::AwaitingPayment | RequestPhase::Completed => Ok(()),
                other => Err(format!(
                    "summon completion requires portal proof request_id={request_id} phase={other:?}"
                )),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summon_service_runtime::ServiceRuntimeConfig;

    fn root(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wow112_summon_control_{}_{}_{}",
            std::process::id(), stamp, tag
        ))
    }

    #[test]
    fn inbox_roundtrip_is_ordered_and_acknowledged() {
        let root = root("inbox");
        let inbox = ControlInbox::open(&root).unwrap();
        let path = ControlInbox::submit(&root, &ServiceControlCommand::Pause).unwrap();
        assert!(path.exists());
        let pending = inbox.next().unwrap().unwrap();
        assert_eq!(pending.command, ServiceControlCommand::Pause);
        inbox.ack(pending).unwrap();
        assert!(inbox.next().unwrap().is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn portal_then_summon_completion_is_idempotent() {
        let root = root("portal");
        let config = ServiceRuntimeConfig::new(&root, "control-test");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("test"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        let portal = ServiceControlCommand::PortalCommitted {
            request_id: id.clone(),
        };
        apply_control(&mut runtime, &portal).unwrap();
        apply_control(&mut runtime, &portal).unwrap();
        let complete = ServiceControlCommand::SummonCompleted {
            request_id: id.clone(),
            now_ms: 30,
        };
        apply_control(&mut runtime, &complete).unwrap();
        apply_control(&mut runtime, &complete).unwrap();
        assert_eq!(
            runtime.request(&id).unwrap().phase,
            RequestPhase::AwaitingPayment
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn summon_completion_without_portal_proof_is_blocked() {
        let root = root("gate");
        let config = ServiceRuntimeConfig::new(&root, "control-test");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("test"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        let result = apply_control(
            &mut runtime,
            &ServiceControlCommand::SummonCompleted {
                request_id: id,
                now_ms: 30,
            },
        );
        assert!(result.unwrap_err().contains("requires portal proof"));
        let _ = fs::remove_dir_all(root);
    }
}
