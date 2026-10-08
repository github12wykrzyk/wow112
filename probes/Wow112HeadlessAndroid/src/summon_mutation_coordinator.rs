use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

pub const MUTATION_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MutationKind {
    GroupReset,
    Invite,
    GroupAccept,
    SetSelection,
    CastRitual,
    PortalUse,
    SummonResponse,
    TeleportAck,
    TradeBegin,
    TradeAccept,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MutationState {
    Committed,
    Sent,
    Confirmed,
    Uncertain,
    AbortedBeforeSend,
}

impl MutationState {
    pub fn blocks_replay(self) -> bool {
        matches!(self, Self::Committed | Self::Sent | Self::Uncertain)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MutationRecord {
    pub schema_version: u32,
    pub operation_id: String,
    pub request_id: String,
    pub kind: MutationKind,
    pub state: MutationState,
    pub requires_server_confirmation: bool,
    pub committed_at_ms: u64,
    pub sent_at_ms: Option<u64>,
    pub resolved_at_ms: Option<u64>,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct JournalState {
    schema_version: u32,
    records: Vec<MutationRecord>,
}

pub struct MutationCoordinator {
    path: PathBuf,
    state: JournalState,
}

impl MutationCoordinator {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, String> {
        let path = path.into();
        let state = if path.exists() {
            let raw = fs::read_to_string(&path)
                .map_err(|error| format!("read mutation journal {} failed: {error}", path.display()))?;
            let parsed: JournalState = serde_json::from_str(&raw)
                .map_err(|error| format!("parse mutation journal {} failed: {error}", path.display()))?;
            if parsed.schema_version != MUTATION_SCHEMA_VERSION {
                return Err(format!(
                    "unsupported mutation journal schema={} expected={}",
                    parsed.schema_version, MUTATION_SCHEMA_VERSION
                ));
            }
            parsed
        } else {
            JournalState {
                schema_version: MUTATION_SCHEMA_VERSION,
                records: Vec::new(),
            }
        };
        Ok(Self { path, state })
    }

    pub fn unresolved(&self) -> Option<&MutationRecord> {
        self.state
            .records
            .iter()
            .rev()
            .find(|record| record.state.blocks_replay())
    }

    pub fn hard_block_reason(&self) -> Option<String> {
        self.unresolved().map(|record| {
            format!(
                "mutation_unresolved operation={} request={} kind={:?} state={:?}",
                record.operation_id, record.request_id, record.kind, record.state
            )
        })
    }

    pub fn records(&self) -> &[MutationRecord] {
        &self.state.records
    }

    pub fn records_for_request<'a>(
        &'a self,
        request_id: &'a str,
    ) -> impl Iterator<Item = &'a MutationRecord> + 'a {
        self.state
            .records
            .iter()
            .filter(move |record| record.request_id == request_id)
    }

    pub fn commit_before_send(
        &mut self,
        request_id: &str,
        kind: MutationKind,
        operation_id: &str,
        requires_server_confirmation: bool,
        now_ms: u64,
        detail: impl Into<String>,
    ) -> Result<(), String> {
        if request_id.trim().is_empty() || operation_id.trim().is_empty() {
            return Err("mutation request_id and operation_id must be non-empty".to_string());
        }
        if let Some(record) = self.unresolved() {
            return Err(format!(
                "mutation coordinator busy operation={} request={} kind={:?} state={:?}",
                record.operation_id, record.request_id, record.kind, record.state
            ));
        }
        if self
            .state
            .records
            .iter()
            .any(|record| record.operation_id == operation_id)
        {
            return Err(format!("mutation operation_id already exists: {operation_id}"));
        }
        self.state.records.push(MutationRecord {
            schema_version: MUTATION_SCHEMA_VERSION,
            operation_id: operation_id.to_string(),
            request_id: request_id.to_string(),
            kind,
            state: MutationState::Committed,
            requires_server_confirmation,
            committed_at_ms: now_ms,
            sent_at_ms: None,
            resolved_at_ms: None,
            detail: detail.into(),
        });
        self.persist()
    }

    pub fn mark_send_ok(&mut self, operation_id: &str, now_ms: u64) -> Result<(), String> {
        let record = self.find_mut(operation_id)?;
        if record.state != MutationState::Committed {
            return Err(format!(
                "mark_send_ok invalid state operation={} state={:?}",
                operation_id, record.state
            ));
        }
        record.sent_at_ms = Some(now_ms);
        if record.requires_server_confirmation {
            record.state = MutationState::Sent;
        } else {
            record.state = MutationState::Confirmed;
            record.resolved_at_ms = Some(now_ms);
        }
        self.persist()
    }

    pub fn confirm_from_server(
        &mut self,
        operation_id: &str,
        now_ms: u64,
        detail: impl Into<String>,
    ) -> Result<(), String> {
        let detail = detail.into();
        let record = self.find_mut(operation_id)?;
        if !matches!(record.state, MutationState::Committed | MutationState::Sent) {
            return Err(format!(
                "confirm_from_server invalid state operation={} state={:?}",
                operation_id, record.state
            ));
        }
        record.state = MutationState::Confirmed;
        record.resolved_at_ms = Some(now_ms);
        if !detail.is_empty() {
            record.detail = detail;
        }
        self.persist()
    }

    pub fn mark_uncertain(
        &mut self,
        operation_id: &str,
        now_ms: u64,
        detail: impl Into<String>,
    ) -> Result<(), String> {
        let detail = detail.into();
        let record = self.find_mut(operation_id)?;
        if !matches!(record.state, MutationState::Committed | MutationState::Sent) {
            return Err(format!(
                "mark_uncertain invalid state operation={} state={:?}",
                operation_id, record.state
            ));
        }
        record.state = MutationState::Uncertain;
        record.resolved_at_ms = Some(now_ms);
        record.detail = detail;
        self.persist()
    }

    pub fn abort_before_transport(
        &mut self,
        operation_id: &str,
        now_ms: u64,
        detail: impl Into<String>,
    ) -> Result<(), String> {
        let detail = detail.into();
        let record = self.find_mut(operation_id)?;
        if record.state != MutationState::Committed || record.sent_at_ms.is_some() {
            return Err(format!(
                "abort_before_transport forbidden operation={} state={:?} sent_at={:?}",
                operation_id, record.state, record.sent_at_ms
            ));
        }
        record.state = MutationState::AbortedBeforeSend;
        record.resolved_at_ms = Some(now_ms);
        record.detail = detail;
        self.persist()
    }

    fn find_mut(&mut self, operation_id: &str) -> Result<&mut MutationRecord, String> {
        self.state
            .records
            .iter_mut()
            .find(|record| record.operation_id == operation_id)
            .ok_or_else(|| format!("mutation operation not found: {operation_id}"))
    }

    fn persist(&self) -> Result<(), String> {
        ensure_parent(&self.path)?;
        let body = serde_json::to_vec_pretty(&self.state)
            .map_err(|error| format!("serialize mutation journal failed: {error}"))?;
        atomic_write(&self.path, &body)
    }
}

fn ensure_parent(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent().filter(|value| !value.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .map_err(|error| format!("create mutation journal dir {} failed: {error}", parent.display()))?;
    }
    Ok(())
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}.{}", path.display(), suffix))
}

fn atomic_write(path: &Path, body: &[u8]) -> Result<(), String> {
    let next = sidecar(path, "next");
    let bak = sidecar(path, "bak");
    {
        let mut file = File::create(&next)
            .map_err(|error| format!("create mutation journal {} failed: {error}", next.display()))?;
        file.write_all(body)
            .map_err(|error| format!("write mutation journal {} failed: {error}", next.display()))?;
        file.sync_all()
            .map_err(|error| format!("sync mutation journal {} failed: {error}", next.display()))?;
    }
    if path.exists() {
        let _ = fs::copy(&self::PathBuf::from(path), &bak);
        fs::remove_file(path)
            .map_err(|error| format!("remove mutation journal {} failed: {error}", path.display()))?;
    }
    fs::rename(&next, path).map_err(|error| {
        format!(
            "commit mutation journal {} -> {} failed: {error}",
            next.display(),
            path.display()
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn path(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wow112_mutation_journal_{}_{}_{}.json",
            std::process::id(), stamp, tag
        ))
    }

    #[test]
    fn commit_is_durable_before_transport_and_blocks_restart_replay() {
        let path = path("commit_restart");
        {
            let mut journal = MutationCoordinator::open(&path).unwrap();
            journal
                .commit_before_send(
                    "request-a",
                    MutationKind::CastRitual,
                    "request-a:ritual:1",
                    true,
                    10,
                    "spell=698",
                )
                .unwrap();
        }
        let restored = MutationCoordinator::open(&path).unwrap();
        let unresolved = restored.unresolved().unwrap();
        assert_eq!(unresolved.operation_id, "request-a:ritual:1");
        assert_eq!(unresolved.state, MutationState::Committed);
        assert!(restored.hard_block_reason().is_some());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn uncertain_send_never_becomes_retryable() {
        let path = path("uncertain");
        let mut journal = MutationCoordinator::open(&path).unwrap();
        journal
            .commit_before_send(
                "request-a",
                MutationKind::Invite,
                "request-a:invite:client",
                true,
                10,
                "client=Clienta",
            )
            .unwrap();
        journal
            .mark_uncertain("request-a:invite:client", 11, "socket returned ambiguous error")
            .unwrap();
        drop(journal);

        let mut restored = MutationCoordinator::open(&path).unwrap();
        assert_eq!(restored.unresolved().unwrap().state, MutationState::Uncertain);
        assert!(restored
            .commit_before_send(
                "request-a",
                MutationKind::Invite,
                "request-a:invite:retry",
                true,
                12,
                "forbidden retry",
            )
            .is_err());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn confirmed_operation_releases_global_character_lock() {
        let path = path("sequence");
        let mut journal = MutationCoordinator::open(&path).unwrap();
        journal
            .commit_before_send(
                "request-a",
                MutationKind::Invite,
                "a:invite",
                true,
                10,
                "",
            )
            .unwrap();
        journal.mark_send_ok("a:invite", 11).unwrap();
        assert!(journal
            .commit_before_send(
                "request-b",
                MutationKind::Invite,
                "b:invite",
                true,
                12,
                "",
            )
            .is_err());
        journal
            .confirm_from_server("a:invite", 13, "party roster contains target")
            .unwrap();
        journal
            .commit_before_send(
                "request-b",
                MutationKind::Invite,
                "b:invite",
                true,
                14,
                "",
            )
            .unwrap();
        let _ = fs::remove_file(path);
    }

    #[test]
    fn no_ack_mutation_resolves_only_after_successful_write_result() {
        let path = path("no_ack");
        let mut journal = MutationCoordinator::open(&path).unwrap();
        journal
            .commit_before_send(
                "request-a",
                MutationKind::SetSelection,
                "a:selection",
                false,
                10,
                "guid=1",
            )
            .unwrap();
        journal.mark_send_ok("a:selection", 11).unwrap();
        assert!(journal.unresolved().is_none());
        let record = journal.records().last().unwrap();
        assert_eq!(record.state, MutationState::Confirmed);
        let _ = fs::remove_file(path);
    }
}
