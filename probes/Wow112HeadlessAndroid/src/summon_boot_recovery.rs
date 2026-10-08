use crate::summon_mutation_coordinator::{MutationCoordinator, MutationKind, MutationState};
use crate::summon_service_core::{RequestPhase, ServiceSnapshot};
use serde_json::Value;
use std::fs;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BootRecoveryResult {
    pub snapshot: ServiceSnapshot,
    pub promoted_request_id: Option<String>,
}

/// Promotes RitualCommitted -> PortalCommitted only when two independent durable
/// facts agree for the same request: a confirmed PortalUse mutation and a still-
/// pending PortalCommitted control message. Any ambiguity fails closed.
pub fn reconcile_boot_snapshot(
    root: impl AsRef<Path>,
    mut snapshot: ServiceSnapshot,
) -> Result<BootRecoveryResult, String> {
    let root = root.as_ref();
    let ritual_ids = snapshot
        .requests
        .iter()
        .filter(|record| record.phase == RequestPhase::RitualCommitted)
        .map(|record| record.request_id.clone())
        .collect::<Vec<_>>();

    if ritual_ids.is_empty() {
        return Ok(BootRecoveryResult {
            snapshot,
            promoted_request_id: None,
        });
    }
    if ritual_ids.len() != 1 {
        return Err(format!(
            "boot recovery refuses ambiguous ritual requests count={}",
            ritual_ids.len()
        ));
    }
    let request_id = &ritual_ids[0];

    let journal = MutationCoordinator::open(root.join("summon_mutations.json"))?;
    if journal.hard_block_reason().is_some() {
        return Ok(BootRecoveryResult {
            snapshot,
            promoted_request_id: None,
        });
    }
    let confirmed_portals = journal
        .records_for_request(request_id)
        .filter(|record| record.kind == MutationKind::PortalUse)
        .filter(|record| record.state == MutationState::Confirmed)
        .collect::<Vec<_>>();
    if confirmed_portals.is_empty() {
        return Ok(BootRecoveryResult {
            snapshot,
            promoted_request_id: None,
        });
    }
    if confirmed_portals.len() != 1 {
        return Err(format!(
            "boot recovery refuses multiple confirmed portal mutations request_id={} count={}",
            request_id,
            confirmed_portals.len()
        ));
    }

    let inbox = root.join("control_inbox");
    let mut matching_controls = 0usize;
    if inbox.exists() {
        let mut paths = fs::read_dir(&inbox)
            .map_err(|e| format!("read boot recovery inbox {} failed: {e}", inbox.display()))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|v| v.to_str()) == Some("json"))
            .collect::<Vec<_>>();
        paths.sort();
        for path in paths {
            let raw = fs::read_to_string(&path)
                .map_err(|e| format!("read boot recovery control {} failed: {e}", path.display()))?;
            let value: Value = serde_json::from_str(&raw)
                .map_err(|e| format!("parse boot recovery control {} failed: {e}", path.display()))?;
            let kind = value.get("type").and_then(Value::as_str);
            let control_request = value.get("request_id").and_then(Value::as_str);
            if kind == Some("portal_committed") && control_request == Some(request_id.as_str()) {
                matching_controls += 1;
            }
        }
    }

    if matching_controls == 0 {
        return Ok(BootRecoveryResult {
            snapshot,
            promoted_request_id: None,
        });
    }
    if matching_controls != 1 {
        return Err(format!(
            "boot recovery refuses duplicate portal controls request_id={} count={}",
            request_id, matching_controls
        ));
    }

    let record = snapshot
        .requests
        .iter_mut()
        .find(|record| record.request_id == *request_id)
        .ok_or_else(|| format!("boot recovery request disappeared: {request_id}"))?;
    record.phase = RequestPhase::PortalCommitted;
    record.mutation_committed = true;
    record.last_error = None;

    Ok(BootRecoveryResult {
        snapshot,
        promoted_request_id: Some(request_id.clone()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summon_mutation_coordinator::MutationCoordinator;
    use crate::summon_service_control::{ControlInbox, ServiceControlCommand};
    use crate::summon_service_runtime::{ServiceRuntimeConfig, SummonServiceRuntime};
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn root(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wow112_boot_recovery_{}_{}_{}",
            std::process::id(), stamp, tag
        ))
    }

    fn ritual_snapshot(root: &Path) -> (ServiceSnapshot, String) {
        let config = ServiceRuntimeConfig::new(root, "boot-recovery-test");
        let mut runtime = SummonServiceRuntime::open(config, 1).unwrap();
        let id = runtime
            .on_whisper("Clienta", "hyjal pls", None, Some("test"), 10)
            .unwrap()
            .unwrap();
        runtime.start_next(20).unwrap();
        runtime.mark_ritual_committed(&id, "ritual-1").unwrap();
        (runtime.core().snapshot(), id)
    }

    fn confirmed_portal(root: &Path, request_id: &str, operation_id: &str) {
        let mut journal = MutationCoordinator::open(root.join("summon_mutations.json")).unwrap();
        journal
            .commit_before_send(
                request_id,
                MutationKind::PortalUse,
                operation_id,
                false,
                30,
                "portal_guid=0x1",
            )
            .unwrap();
        journal.mark_send_ok(operation_id, 31).unwrap();
    }

    #[test]
    fn dual_durable_evidence_promotes_portal_wait() {
        let root = root("promote");
        let (snapshot, id) = ritual_snapshot(&root);
        confirmed_portal(&root, &id, "portal-1");
        ControlInbox::submit(
            &root,
            &ServiceControlCommand::PortalCommitted {
                request_id: id.clone(),
            },
        )
        .unwrap();
        let result = reconcile_boot_snapshot(&root, snapshot).unwrap();
        assert_eq!(result.promoted_request_id.as_deref(), Some(id.as_str()));
        assert_eq!(
            result
                .snapshot
                .requests
                .iter()
                .find(|record| record.request_id == id)
                .unwrap()
                .phase,
            RequestPhase::PortalCommitted
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn mutation_without_pending_control_does_not_promote() {
        let root = root("mutation_only");
        let (snapshot, id) = ritual_snapshot(&root);
        confirmed_portal(&root, &id, "portal-1");
        let result = reconcile_boot_snapshot(&root, snapshot).unwrap();
        assert!(result.promoted_request_id.is_none());
        assert_eq!(
            result.snapshot.requests.iter().find(|r| r.request_id == id).unwrap().phase,
            RequestPhase::RitualCommitted
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn control_without_confirmed_mutation_does_not_promote() {
        let root = root("control_only");
        let (snapshot, id) = ritual_snapshot(&root);
        ControlInbox::submit(
            &root,
            &ServiceControlCommand::PortalCommitted {
                request_id: id.clone(),
            },
        )
        .unwrap();
        let result = reconcile_boot_snapshot(&root, snapshot).unwrap();
        assert!(result.promoted_request_id.is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn uncertain_portal_mutation_never_promotes() {
        let root = root("uncertain");
        let (snapshot, id) = ritual_snapshot(&root);
        let mut journal = MutationCoordinator::open(root.join("summon_mutations.json")).unwrap();
        journal
            .commit_before_send(&id, MutationKind::PortalUse, "portal-1", false, 30, "")
            .unwrap();
        journal.mark_uncertain("portal-1", 31, "ambiguous transport").unwrap();
        ControlInbox::submit(
            &root,
            &ServiceControlCommand::PortalCommitted {
                request_id: id,
            },
        )
        .unwrap();
        let result = reconcile_boot_snapshot(&root, snapshot).unwrap();
        assert!(result.promoted_request_id.is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn duplicate_confirmed_portal_mutations_fail_closed() {
        let root = root("duplicate_mutation");
        let (snapshot, id) = ritual_snapshot(&root);
        confirmed_portal(&root, &id, "portal-1");
        confirmed_portal(&root, &id, "portal-2");
        ControlInbox::submit(
            &root,
            &ServiceControlCommand::PortalCommitted {
                request_id: id,
            },
        )
        .unwrap();
        let error = reconcile_boot_snapshot(&root, snapshot).unwrap_err();
        assert!(error.contains("multiple confirmed portal mutations"));
        let _ = fs::remove_dir_all(root);
    }
}