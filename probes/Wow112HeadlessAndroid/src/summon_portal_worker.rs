use crate::summon_mutation_coordinator::{MutationCoordinator, MutationKind, MutationState};
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
    actor_key: String,
}

impl PortalWorker {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, String> {
    Self::open_for_actor(root, "default")
}

pub fn open_for_actor(
    root: impl AsRef<Path>,
    actor: impl AsRef<str>,
) -> Result<Self, String> {
    let root = root.as_ref().to_path_buf();
    fs::create_dir_all(&root)
        .map_err(|e| format!("create portal worker root {} failed: {e}", root.display()))?;
    let actor_key = actor.as_ref().trim().to_ascii_lowercase();
    if actor_key.is_empty()
        || actor_key.len() > 64
        || actor_key.bytes().any(|b| !(b.is_ascii_alphanumeric() || b == b'-' || b == b'_'))
    {
        return Err(format!("invalid portal worker actor={:?}", actor.as_ref()));
    }
    Ok(Self { root, actor_key })
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
            .filter(|r| matches!(r.phase, RequestPhase::RitualCommitted | RequestPhase::PortalCommitted))
            .map(|r| r.request_id.clone())
            .collect::<Vec<_>>();
        active.sort();
        match active.len() {
            0 => Ok(None),
            1 => Ok(active.pop()),
            count => Err(format!(
                "portal worker found {count} portal-wait requests; refusing ambiguous portal mutation"
            )),
        }
    }

    pub fn claim_portal_use(
        &self,
        portal_guid: u64,
        now_ms: u64,
    ) -> Result<Option<PortalClaim>, String> {
        let Some(request_id) = self.active_ritual_request()? else {
            return Ok(None);
        };
        let mut mutations = MutationCoordinator::open(self.root.join("summon_mutations.json"))?;
        if let Some(reason) = mutations.hard_block_reason() {
            return Err(format!("portal worker blocked by unresolved mutation: {reason}"));
        }
        let actor_prefix = format!("{request_id}:portal-use:{}:", self.actor_key);
    if mutations.records_for_request(&request_id).any(|record| {
        record.kind == MutationKind::PortalUse
            && record.state == MutationState::Confirmed
            && record.operation_id.starts_with(&actor_prefix)
    }) {
        return Ok(None);
    }
    let operation_id = format!(
        "{request_id}:portal-use:{}:{portal_guid:016X}",
        self.actor_key
    );
        mutations.commit_before_send(
            &request_id,
            MutationKind::PortalUse,
            &operation_id,
            false,
            now_ms,
            format!("helper_actor={} portal_guid=0x{portal_guid:016X}", self.actor_key),
        )?;
        Ok(Some(PortalClaim {
            request_id,
            operation_id,
            portal_guid,
        }))
    }

    pub fn execute_portal_use_once<F>(
        &self,
        portal_guid: u64,
        now_ms: u64,
        send_once: F,
    ) -> Result<Option<PortalClaim>, String>
    where
        F: FnOnce(u64) -> Result<(), String>,
    {
        let Some(claim) = self.claim_portal_use(portal_guid, now_ms)? else {
            return Ok(None);
        };
        match send_once(portal_guid) {
            Ok(()) => {
                self.mark_send_ok(&claim, now_ms.saturating_add(1))?;
                Ok(Some(claim))
            }
            Err(error) => {
                let reason = format!(
                    "portal_use_socket_uncertain request={} guid=0x{:016X} cause={error}",
                    claim.request_id, claim.portal_guid
                );
                self.mark_send_uncertain(&claim, now_ms.saturating_add(1), &reason)?;
                Err(format!("{reason} retry_allowed=false"))
            }
        }
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
    use crate::summon_mutation_coordinator::MutationKind;
    use crate::summon_service_control::apply_control;
    use crate::summon_service_runtime::{ServiceRuntimeConfig, SummonServiceRuntime};
    use std::cell::Cell;
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

    fn apply_next_control(root: &Path, runtime: &mut SummonServiceRuntime) {
        let inbox = ControlInbox::open(root).unwrap();
        let pending = inbox.next().unwrap().unwrap();
        apply_control(runtime, &pending.command).unwrap();
        inbox.ack(pending).unwrap();
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
    fn execute_once_calls_transport_exactly_once_and_publishes_portal_evidence() {
        let root = root("execute_once");
        let (_runtime, id) = ritual_ready(&root);
        let worker = PortalWorker::open(&root).unwrap();
        let sends = Cell::new(0u32);
        let claim = worker
            .execute_portal_use_once(0xDEAD, 30, |guid| {
                assert_eq!(guid, 0xDEAD);
                sends.set(sends.get() + 1);
                Ok(())
            })
            .unwrap()
            .unwrap();
        assert_eq!(claim.request_id, id);
        assert_eq!(sends.get(), 1);
        let inbox = ControlInbox::open(&root).unwrap();
        assert!(matches!(
            inbox.next().unwrap().unwrap().command,
            ServiceControlCommand::PortalCommitted { .. }
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn confirmed_click_is_idempotent_while_service_state_is_still_ritual_committed() {
        let root = root("idempotent_window");
        let (_runtime, _id) = ritual_ready(&root);
        let worker = PortalWorker::open(&root).unwrap();
        let sends = Cell::new(0u32);
        worker
            .execute_portal_use_once(0xD00D, 30, |_| {
                sends.set(sends.get() + 1);
                Ok(())
            })
            .unwrap()
            .unwrap();
        let second = worker
            .execute_portal_use_once(0xD00D, 31, |_| {
                panic!("confirmed portal operation must not replay before control inbox is consumed")
            })
            .unwrap();
        assert!(second.is_none());
        assert_eq!(sends.get(), 1);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
fn confirmed_portal_for_request_blocks_different_guid_before_control_consumption() {
    let root = root("different_guid_idempotent");
    let (_runtime, _id) = ritual_ready(&root);
    let worker = PortalWorker::open(&root).unwrap();
    worker
        .execute_portal_use_once(0xD00D, 30, |_| Ok(()))
        .unwrap()
        .unwrap();
    let second = worker
        .execute_portal_use_once(0xBEEF, 31, |_| {
            panic!("a request with confirmed portal use must never click a second portal guid")
        })
        .unwrap();
    assert!(second.is_none());
    let _ = fs::remove_dir_all(root);
}

    #[test]
fn two_distinct_helpers_can_each_click_once_for_same_request() {
    let root = root("two_helpers");
    let (mut runtime, id) = ritual_ready(&root);
    let a = PortalWorker::open_for_actor(&root, "Winterone").unwrap();
    let b = PortalWorker::open_for_actor(&root, "Wintertwoo").unwrap();
    let sends = Cell::new(0u32);
    a.execute_portal_use_once(0xD00D, 30, |_| {
        sends.set(sends.get() + 1);
        Ok(())
    })
    .unwrap()
    .unwrap();
    apply_next_control(&root, &mut runtime);
    assert_eq!(runtime.request(&id).unwrap().phase, RequestPhase::PortalCommitted);
    b.execute_portal_use_once(0xD00D, 32, |_| {
        sends.set(sends.get() + 1);
        Ok(())
    })
    .unwrap()
    .unwrap();
    assert_eq!(sends.get(), 2);
    let journal = MutationCoordinator::open(root.join("summon_mutations.json")).unwrap();
    let confirmed = journal
        .records_for_request(&id)
        .filter(|record| record.kind == MutationKind::PortalUse)
        .filter(|record| record.state == MutationState::Confirmed)
        .count();
    assert_eq!(confirmed, 2);
    let _ = fs::remove_dir_all(root);
}

    #[test]
    fn execute_once_transport_error_is_durable_uncertain_and_never_replayed() {
        let root = root("execute_error");
        let (_runtime, _id) = ritual_ready(&root);
        let worker = PortalWorker::open(&root).unwrap();
        let sends = Cell::new(0u32);
        let error = worker
            .execute_portal_use_once(0xBEEF, 30, |_| {
                sends.set(sends.get() + 1);
                Err("ambiguous socket result".to_string())
            })
            .unwrap_err();
        assert!(error.contains("retry_allowed=false"));
        assert_eq!(sends.get(), 1);

        let restored = PortalWorker::open(&root).unwrap();
        let second = restored.execute_portal_use_once(0xBEEF, 40, |_| {
            panic!("transport must not be called after unresolved uncertain mutation")
        });
        assert!(second.unwrap_err().contains("blocked by unresolved mutation"));
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

    #[test]
    fn full_portal_evidence_then_summon_then_payment_releases_queue() {
        let root = root("full_flow");
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
        let claim = worker.claim_portal_use(0xCAFE, 30).unwrap().unwrap();
        worker.mark_send_ok(&claim, 31).unwrap();
        apply_next_control(&root, &mut runtime);
        assert_eq!(runtime.request(&a).unwrap().phase, RequestPhase::PortalCommitted);

        ControlInbox::submit(
            &root,
            &ServiceControlCommand::SummonCompleted {
                request_id: a.clone(),
                now_ms: 32,
            },
        )
        .unwrap();
        apply_next_control(&root, &mut runtime);
        assert_eq!(runtime.request(&a).unwrap().phase, RequestPhase::AwaitingPayment);

        runtime
            .mark_payment_received(&a, 40_000, "trade-a", 33)
            .unwrap();
        assert_eq!(runtime.request(&a).unwrap().phase, RequestPhase::Completed);
        assert_eq!(runtime.start_next(40).unwrap(), Some(b));
        let _ = fs::remove_dir_all(root);
    }
}
