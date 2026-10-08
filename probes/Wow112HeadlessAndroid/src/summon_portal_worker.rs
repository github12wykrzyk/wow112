use crate::summon_mutation_coordinator::{MutationCoordinator, MutationKind};
use crate::summon_service_control::{ControlInbox, ServiceControlCommand};
use crate::summon_service_core::{RequestPhase, ServiceSnapshot};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortalClaim {
    pub request_id: String,
    pub operation_id: String,
    pub portal_guid: u64,
}

#[derive(Clone, Debug)]
pub struct PortalWorker {
    root: PathBuf,
}

impl PortalWorker {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root)
            .map_err(|e| format!("create portal worker root {} failed: {e}", root.display()))?;
        Ok(Self { root })
    }

    pub fn active_ritual_request(&self) -> Result<Option<String>, String> {
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
            .filter(|r| r.phase == RequestPhase::RitualCommitted)
            .map(|r| r.request_id.clone())
            .collect::<Vec<_>>();
        active.sort();
        match active.len() {
            0 => Ok(None),
            1 => Ok(active.pop()),
            count => Err(format!(
                "portal worker found {count} ritual-committed requests; refusing ambiguous portal mutation"
            )),
        }
    }

    pub fn claim_portal_use(&self, portal_guid: u64, now_ms: u64) -> Result<Option<PortalClaim>, String> {
        let Some(request_id) = self.active_ritual_request()? else {
            return Ok(None);
        };
        let mut mutations = MutationCoordinator::open(self.root.join("summon_mutations.json"))?;
        if let Some(reason) = mutations.hard_block_reason() {
            return Err(format!("portal worker blocked by unresolved mutation: {reason}"));
        }
        let operation_id = format!("{request_id}:portal-use:{portal_guid:016X}");
        mutations.commit_before_send(
            &request_id,
            MutationKind::PortalUse,
            &operation_id,
            false,
            now_ms,
            format!("portal_guid=0x{portal_guid:016X}"),
        )?;
        Ok(Some(PortalClaim {
            request_id,
            operation_id,
            portal_guid,
        }))
    }

    pub fn mark_send_ok(&self, claim: &PortalClaim, now_ms: u64) -> Result<(), String> {
        let mut mutations = MutationCoordinator::open(self.root.join("summon_mutations.json"))?;
        mutations.mark_send_ok(&claim.operation_id, now_ms)?;
        ControlInbox::submit(
            &self.root,
            &ServiceControlCommand::PortalCommitted {
                request_id: claim.request_id.clone(),
            },
        )?;
        Ok(())
    }

    pub fn mark_send_uncertain(
        &self,
        claim: &PortalClaim,
        now_ms: u64,
        reason: impl Into<String>,
    ) -> Result<(), String> {
        let mut mutations = MutationCoordinator::open(self.root.join("summon_mutations.json"))?;
        mutations.mark_uncertain(&claim.operation_id, now_ms, reason.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summon_mutation_coordinator::{MutationState, MutationKind};
    use crate::summon_service_runtime::{ServiceRuntimeConfig, SummonServiceRuntime};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn root(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wow112_portal_worker_{}_{}_{}",
            std::process::id(), stamp, tag
        ))
    }

    fn ritual_ready(root: &Path) -> (SummonServiceRuntime, String) {
        let config = ServiceRuntimeConfig::new(root, "portal-worker-test");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("test"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        (runtime, id)
    }

    #[test]
    fn portal_use_is_scoped_to_active_request_and_publishes_evidence() {
        let root = root("claim");
        let (_runtime, id) = ritual_ready(&root);
        let worker = PortalWorker::open(&root).unwrap();
        let claim = worker.claim_portal_use(0xAABBCCDD, 30).unwrap().unwrap();
        assert_eq!(claim.request_id, id);
        worker.mark_send_ok(&claim, 31).unwrap();

        let journal = MutationCoordinator::open(root.join("summon_mutations.json")).unwrap();
        let record = journal.records().last().unwrap();
        assert_eq!(record.kind, MutationKind::PortalUse);
        assert_eq!(record.state, MutationState::Confirmed);

        let inbox = ControlInbox::open(&root).unwrap();
        let pending = inbox.next().unwrap().unwrap();
        assert_eq!(
            pending.command,
            ServiceControlCommand::PortalCommitted { request_id: id }
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn uncertain_portal_send_survives_restart_and_forbids_replay() {
        let root = root("uncertain");
        let (_runtime, _id) = ritual_ready(&root);
        let worker = PortalWorker::open(&root).unwrap();
        let claim = worker.claim_portal_use(0x1234, 30).unwrap().unwrap();
        worker
            .mark_send_uncertain(&claim, 31, "socket ambiguous")
            .unwrap();
        drop(worker);

        let restored = PortalWorker::open(&root).unwrap();
        let error = restored.claim_portal_use(0x1234, 40).unwrap_err();
        assert!(error.contains("blocked by unresolved mutation"));
        let inbox = ControlInbox::open(&root).unwrap();
        assert!(inbox.next().unwrap().is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn next_request_can_claim_new_portal_without_process_restart() {
        let root = root("sequential");
        let config = ServiceRuntimeConfig::new(&root, "portal-worker-test");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let a = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("test"), 10)
            .unwrap()
            .unwrap();
        let b = runtime
            .on_whisper("Clientb", "hyjal pls", None, Some("test"), 11)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&a, "ritual-a").unwrap();

        let worker = PortalWorker::open(&root).unwrap();
        let claim_a = worker.claim_portal_use(0xAAA, 30).unwrap().unwrap();
        worker.mark_send_ok(&claim_a, 31).unwrap();
        runtime.mark_portal_committed(&a).unwrap();
        runtime.mark_summon_completed(&a, 32).unwrap();
        runtime.mark_payment_received(&a, 40_000, "trade-a", 33).unwrap();

        runtime.start_next(40).unwrap();
        runtime.mark_ritual_committed(&b, "ritual-b").unwrap();
        let claim_b = worker.claim_portal_use(0xBBB, 50).unwrap().unwrap();
        assert_eq!(claim_b.request_id, b);
        assert_ne!(claim_a.operation_id, claim_b.operation_id);
        let _ = fs::remove_dir_all(root);
    }
}
