use crate::tele08_whisper_parser::{
    classify_whisper, request_fingerprint, ParserConfig, WhisperIntent, WhisperObservation,
};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const TELE11_INGRESS_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngressEvent {
    pub schema_version: u32,
    pub request_id: String,
    pub at_ms: u64,
    pub sender: String,
    pub raw_text: String,
    pub normalized_text: String,
    pub intent: String,
    pub destination: String,
    pub confidence: u8,
    pub reason: String,
    pub signals: Vec<String>,
}

pub fn classify_ingress(
    observation: &WhisperObservation,
    parser: &ParserConfig,
) -> Option<IngressEvent> {
    let classification = classify_whisper(observation, parser);
    let actionable = matches!(
        classification.intent,
        WhisperIntent::SummonRequest | WhisperIntent::InviteRequest | WhisperIntent::GenericPositive
    );
    if !actionable {
        return None;
    }
    let destination = classification.destination.as_ref()?.0.clone();
    let fingerprint = request_fingerprint(&classification);
    Some(IngressEvent {
        schema_version: TELE11_INGRESS_SCHEMA_VERSION,
        request_id: format!(
            "ingress:{}:{}",
            observation.timestamp_ms,
            fingerprint
        ),
        at_ms: observation.timestamp_ms,
        sender: classification.sender,
        raw_text: classification.raw_text,
        normalized_text: classification.normalized_text,
        intent: format!("{:?}", classification.intent),
        destination,
        confidence: classification.confidence,
        reason: classification.reason,
        signals: classification.signals,
    })
}

pub fn write_spool_event(inbox: &Path, event: &IngressEvent) -> Result<PathBuf, String> {
    if event.schema_version != TELE11_INGRESS_SCHEMA_VERSION {
        return Err(format!(
            "unsupported ingress schema_version={}",
            event.schema_version
        ));
    }
    fs::create_dir_all(inbox)
        .map_err(|error| format!("create ingress inbox {} failed: {error}", inbox.display()))?;
    let safe_id = event
        .request_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    let final_path = inbox.join(format!("{safe_id}.json"));
    if final_path.exists() {
        return Ok(final_path);
    }
    let temp_path = inbox.join(format!(".{safe_id}.{}.tmp", std::process::id()));
    let body = serde_json::to_vec(event)
        .map_err(|error| format!("serialize ingress event failed: {error}"))?;
    fs::write(&temp_path, body)
        .map_err(|error| format!("write ingress temp {} failed: {error}", temp_path.display()))?;
    fs::rename(&temp_path, &final_path).map_err(|error| {
        format!(
            "publish ingress event {} -> {} failed: {error}",
            temp_path.display(),
            final_path.display()
        )
    })?;
    Ok(final_path)
}

pub fn read_spool_event(path: &Path) -> Result<IngressEvent, String> {
    let text = fs::read_to_string(path)
        .map_err(|error| format!("read ingress event {} failed: {error}", path.display()))?;
    let event: IngressEvent = serde_json::from_str(&text)
        .map_err(|error| format!("parse ingress event {} failed: {error}", path.display()))?;
    if event.schema_version != TELE11_INGRESS_SCHEMA_VERSION {
        return Err(format!(
            "unsupported ingress schema_version={} path={}",
            event.schema_version,
            path.display()
        ));
    }
    Ok(event)
}

pub fn list_spool_events(inbox: &Path) -> Result<Vec<PathBuf>, String> {
    if !inbox.exists() {
        return Ok(Vec::new());
    }
    let mut paths = fs::read_dir(inbox)
        .map_err(|error| format!("read ingress inbox {} failed: {error}", inbox.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
        .collect::<Vec<_>>();
    paths.sort();
    Ok(paths)
}

pub fn archive_spool_event(
    source: &Path,
    archive_root: &Path,
    bucket: &str,
) -> Result<PathBuf, String> {
    let file_name = source
        .file_name()
        .ok_or_else(|| format!("ingress source has no filename: {}", source.display()))?;
    let target_dir = archive_root.join(bucket);
    fs::create_dir_all(&target_dir).map_err(|error| {
        format!(
            "create ingress archive {} failed: {error}",
            target_dir.display()
        )
    })?;
    let target = target_dir.join(file_name);
    if target.exists() {
        fs::remove_file(source).map_err(|error| {
            format!(
                "remove duplicate archived ingress {} failed: {error}",
                source.display()
            )
        })?;
        return Ok(target);
    }
    fs::rename(source, &target).map_err(|error| {
        format!(
            "archive ingress {} -> {} failed: {error}",
            source.display(),
            target.display()
        )
    })?;
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("tele11-ingress-{label}-{unique}"))
    }

    #[test]
    fn actionable_request_with_context_is_spooled_atomically() {
        let mut observation = WhisperObservation {
            sender: "Buyer".to_string(),
            text: "+".to_string(),
            timestamp_ms: 12345,
            source_role: Some("TELE11_LISTENER".to_string()),
            destination_context: Some("winterspring".to_string()),
        };
        let parser = ParserConfig::default();
        let event = classify_ingress(&observation, &parser).expect("actionable ingress");
        assert_eq!(event.destination, "winterspring");
        assert!(event.request_id.starts_with("ingress:12345:"));

        let root = temp_dir("atomic");
        let inbox = root.join("inbox");
        let path = write_spool_event(&inbox, &event).unwrap();
        assert!(path.exists());
        assert_eq!(list_spool_events(&inbox).unwrap(), vec![path.clone()]);
        assert_eq!(read_spool_event(&path).unwrap(), event);
        assert!(fs::read_dir(&inbox)
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| entry.path().extension().and_then(|v| v.to_str()) != Some("tmp")));

        observation.timestamp_ms += 1;
        let second = classify_ingress(&observation, &parser).unwrap();
        assert_ne!(event.request_id, second.request_id);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn unknown_and_presence_messages_are_not_admitted() {
        let parser = ParserConfig::default();
        for text in ["hello there", "here"] {
            let observation = WhisperObservation {
                sender: "Buyer".to_string(),
                text: text.to_string(),
                timestamp_ms: 1,
                source_role: None,
                destination_context: Some("hyjal".to_string()),
            };
            assert!(classify_ingress(&observation, &parser).is_none(), "text={text}");
        }
    }

    #[test]
    fn archive_is_idempotent_after_durable_import() {
        let root = temp_dir("archive");
        let inbox = root.join("inbox");
        let archive = root.join("archive");
        let event = IngressEvent {
            schema_version: 1,
            request_id: "ingress:1:abc".into(),
            at_ms: 1,
            sender: "Buyer".into(),
            raw_text: "+ hyjal".into(),
            normalized_text: "+ hyjal".into(),
            intent: "GenericPositive".into(),
            destination: "hyjal".into(),
            confidence: 98,
            reason: "leading_plus_request_signal".into(),
            signals: Vec::new(),
        };
        let source = write_spool_event(&inbox, &event).unwrap();
        let target = archive_spool_event(&source, &archive, "processed").unwrap();
        assert!(target.exists());
        assert!(!source.exists());
        let _ = fs::remove_dir_all(root);
    }
}
