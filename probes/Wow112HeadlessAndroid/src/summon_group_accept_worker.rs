use crate::summon_mutation_coordinator::{MutationCoordinator, MutationKind};
use crate::summon_service_core::{RequestPhase, ServiceSnapshot};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GroupAcceptClaim {
    pub request_id: String,
    pub operation_id: String,
    pub inviter: String,
}

#[derive(Clone, Debug)]
pub struct GroupAcceptWorker {
    root: PathBuf,
}

impl GroupAcceptWorker {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root)
            .map_err(|e| format!("create group accept worker root {} failed: {e}", root.display()))?;
        Ok(Self { root })
    }

    fn active_inviting_request(&self) -> Result<Option<String>, String> {
        let path = self.root.join("summon_service_state.json");
        if !path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(&path)
            .map_err(|e| format!("read summon state {} failed: {e}", path.display()))?;
        let snapshot: ServiceSnapshot = serde_json::from_str(&raw)
            .map_err(|e| format!("parse summon state {} failed: {e}", path.display()))?;
        let mut active = snapshot
            .requests
            .iter()
            .filter(|r| r.phase == RequestPhase::Inviting)
            .map(|r| r.request_id.clone())
            .collect::<Vec<_>>();
        active.sort();
        match active.len() {
            0 => Ok(None),
            1 => Ok(active.pop()),
            count => Err(format!(
                "group accept worker found {count} inviting requests; refusing ambiguous mutation"
            )),
        }
    }

    pub fn execute_accept_once<F>(
        &self,
        inviter: &str,
        now_ms: u64,
        send_once: F,
    ) -> Result<Option<GroupAcceptClaim>, String>
    where
        F: FnOnce() -> Result<(), String>,
    {
        let inviter = inviter.trim();
        if inviter.is_empty() {
            return Err("group accept inviter must be non-empty".to_string());
        }
        let Some(request_id) = self.active_inviting_request()? else {
            return Ok(None);
        };
        let mut mutations = MutationCoordinator::open(self.root.join("summon_mutations.json"))?;
        if let Some(reason) = mutations.hard_block_reason() {
            return Err(format!("group accept blocked by unresolved mutation: {reason}"));
        }
        let inviter_key = inviter.to_ascii_lowercase();
        let operation_id = format!("{request_id}:group-accept:{inviter_key}");
        mutations.commit_before_send(
            &request_id,
            MutationKind::Invite,
            &operation_id,
            false,
            now_ms,
            format!("direction=accept inviter={inviter_key}"),
        )?;
        let claim = GroupAcceptClaim {
            request_id,
            operation_id,
            inviter: inviter.to_string(),
        };
        match send_once() {
            Ok(()) => {
                mutations.mark_send_ok(&claim.operation_id, now_ms.saturating_add(1))?;
                Ok(Some(claim))
            }
            Err(error) => {
                let reason = format!(
                    "group_accept_socket_uncertain request={} inviter={} cause={error}",
                    claim.request_id, inviter_key
                );
                mutations.mark_uncertain(&claim.operation_id, now_ms.saturating_add(1), &reason)?;
                Err(format!("{reason} retry_allowed=false"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summon_service_runtime::{ServiceRuntimeConfig, SummonServiceRuntime};
    use std::cell::Cell;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn root(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wow112_group_accept_{}_{}_{}",
            std::process::id(), stamp, tag
        ))
    }

    fn queue_two(root: &Path) -> (SummonServiceRuntime, String, String) {
        let config = ServiceRuntimeConfig::new(root, "group-accept-test");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let a = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("test"), 10)
            .unwrap()
            .unwrap();
        let b = runtime
            .on_whisper("Clientb", "hyjal pls", None, Some("test"), 11)
            .unwrap()
            .unwrap();
        (runtime, a, b)
    }

    #[test]
    fn accept_transport_is_once_per_request() {
        let root = root("once");
        let (mut runtime, a, _b) = queue_two(&root);
        runtime.start_next(20).unwrap();
        let worker = GroupAcceptWorker::open(&root).unwrap();
        let sends = Cell::new(0u32);
        let claim = worker
            .execute_accept_once("Summoner", 21, || {
                sends.set(sends.get() + 1);
                Ok(())
            })
            .unwrap()
            .unwrap();
        assert_eq!(claim.request_id, a);
        assert_eq!(sends.get(), 1);
        let replay = worker.execute_accept_once("Summoner", 22, || {
            panic!("duplicate accept transport must not execute")
        });
        assert!(replay.is_err());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn uncertain_accept_is_durable_and_never_replayed() {
        let root = root("uncertain");
        let (mut runtime, _a, _b) = queue_two(&root);
        runtime.start_next(20).unwrap();
        let worker = GroupAcceptWorker::open(&root).unwrap();
        let error = worker
            .execute_accept_once("Summoner", 21, || Err("ambiguous".to_string()))
            .unwrap_err();
        assert!(error.contains("retry_allowed=false"));
        drop(worker);
        let restored = GroupAcceptWorker::open(&root).unwrap();
        let replay = restored.execute_accept_once("Summoner", 22, || {
            panic!("uncertain accept must never replay")
        });
        assert!(replay.unwrap_err().contains("blocked by unresolved mutation"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn second_request_gets_fresh_accept_claim_without_process_restart() {
        let root = root("sequential");
        let (mut runtime, a, b) = queue_two(&root);
        let worker = GroupAcceptWorker::open(&root).unwrap();
        runtime.start_next(20).unwrap();
        let first = worker
            .execute_accept_once("Summoner", 21, || Ok(()))
            .unwrap()
            .unwrap();
        assert_eq!(first.request_id, a);
        runtime.mark_terminal_failure(&a, "test advance", 22).unwrap();
        runtime.start_next(30).unwrap();
        let second = worker
            .execute_accept_once("Summoner", 31, || Ok(()))
            .unwrap()
            .unwrap();
        assert_eq!(second.request_id, b);
        assert_ne!(first.operation_id, second.operation_id);
        let _ = fs::remove_dir_all(root);
    }
}
