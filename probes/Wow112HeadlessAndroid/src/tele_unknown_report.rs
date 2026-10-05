#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownWhisperRecord {
    pub timestamp_s: u64,
    pub character: String,
    pub sender: String,
    pub raw: String,
    pub normalized: String,
    pub conversation_state: String,
    pub classification: String,
    pub confidence: u8,
    pub reason: String,
    pub destination: Option<String>,
    pub action_taken: String,
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 8);
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04X}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

fn json_string(value: &str) -> String {
    format!("\"{}\"", json_escape(value))
}

impl UnknownWhisperRecord {
    /// Emits exactly one compact JSON object suitable for append-only JSONL.
    /// Runtime persistence is intentionally separate so classification stays pure/testable.
    pub fn to_json_line(&self) -> String {
        let destination = self
            .destination
            .as_deref()
            .map(json_string)
            .unwrap_or_else(|| "null".to_string());
        format!(
            "{{\"timestamp_s\":{},\"character\":{},\"sender\":{},\"raw\":{},\"normalized\":{},\"conversation_state\":{},\"classification\":{},\"confidence\":{},\"reason\":{},\"destination\":{},\"action_taken\":{}}}",
            self.timestamp_s,
            json_string(&self.character),
            json_string(&self.sender),
            json_string(&self.raw),
            json_string(&self.normalized),
            json_string(&self.conversation_state),
            json_string(&self.classification),
            self.confidence,
            json_string(&self.reason),
            destination,
            json_string(&self.action_taken),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonl_record_escapes_untrusted_whisper_text() {
        let record = UnknownWhisperRecord {
            timestamp_s: 123,
            character: "Feltaxi".to_string(),
            sender: "Somebody".to_string(),
            raw: "inv \"hyjal\"\npls".to_string(),
            normalized: "inv hyjal pls".to_string(),
            conversation_state: "New".to_string(),
            classification: "Unknown".to_string(),
            confidence: 20,
            reason: "no supported rule".to_string(),
            destination: None,
            action_taken: "LogUnknown".to_string(),
        };
        let line = record.to_json_line();
        assert!(!line.contains('\n'));
        assert!(line.contains("\\\"hyjal\\\"\\npls"));
        assert!(line.contains("\"destination\":null"));
    }

    #[test]
    fn jsonl_record_keeps_resolved_destination() {
        let record = UnknownWhisperRecord {
            timestamp_s: 456,
            character: "Feltaxi".to_string(),
            sender: "Somebody".to_string(),
            raw: "+ whatever".to_string(),
            normalized: "whatever".to_string(),
            conversation_state: "New".to_string(),
            classification: "Unknown".to_string(),
            confidence: 35,
            reason: "ambiguous ready token".to_string(),
            destination: Some("Hyjal".to_string()),
            action_taken: "LogUnknown".to_string(),
        };
        let line = record.to_json_line();
        assert!(line.contains("\"destination\":\"Hyjal\""));
    }
}
