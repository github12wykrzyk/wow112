use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::{env, fs::{self, File, OpenOptions}, io::{BufWriter, Write}, path::PathBuf, time::{Instant, SystemTime, UNIX_EPOCH}};

pub struct Capture {
    writer: BufWriter<File>, partial: PathBuf, final_path: PathBuf,
    pub scan_id: String, market: String, producer: String, source: String, scope: String,
    key: Vec<u8>, seq: u64, pages: u32, started: Instant, finished: bool,
}

pub fn validate_config() -> Result<(), String> {
    for name in ["WOW112_MARKET_ID", "WOW112_PRODUCER_ID", "WOW112_OWNER_HMAC_KEY"] {
        let s = env::var(name).map_err(|_| format!("missing {name}"))?;
        if s.trim().is_empty() { return Err(format!("empty {name}")); }
        if name == "WOW112_OWNER_HMAC_KEY" && s.len() < 32 { return Err("owner HMAC key must contain at least 32 bytes".into()); }
    }
    Ok(())
}

pub fn now_ms() -> u128 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() }

impl Capture {
    pub fn new(dir: &str, source: &str, scope: &str) -> Result<Self, String> {
        validate_config()?;
        let market = env::var("WOW112_MARKET_ID").unwrap();
        if (source == "fixture") != market.starts_with("fixture:") {
            return Err("fixture and live market namespaces must remain separate".into());
        }
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let ns = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
        let scan_id = format!("{ns}-{}", std::process::id());
        let partial = PathBuf::from(dir).join(format!("{scan_id}.ndjson.partial"));
        let final_path = PathBuf::from(dir).join(format!("{scan_id}.ndjson"));
        let file = OpenOptions::new().write(true).create_new(true).open(&partial).map_err(|e| e.to_string())?;
        let mut c = Self { writer: BufWriter::new(file), partial, final_path, scan_id,
            market: env::var("WOW112_MARKET_ID").unwrap(), producer: env::var("WOW112_PRODUCER_ID").unwrap(),
            key: env::var("WOW112_OWNER_HMAC_KEY").unwrap().into_bytes(), source: source.into(), scope: scope.into(),
            seq: 0, pages: 0, started: Instant::now(), finished: false };
        c.emit(json!({"event_type":"ScanStarted", "max_page_size":50}))?;
        Ok(c)
    }
    fn emit(&mut self, mut v: Value) -> Result<(), String> {
        self.seq += 1;
        let o = v.as_object_mut().ok_or("invalid event")?;
        o.insert("schema_version".into(), json!(1));
        o.insert("event_id".into(), json!(format!("{}:{}", self.scan_id, self.seq)));
        o.insert("scan_id".into(), json!(self.scan_id));
        o.insert("producer_seq".into(), json!(self.seq));
        o.insert("market_id".into(), json!(self.market));
        o.insert("producer_id".into(), json!(self.producer));
        o.insert("source".into(), json!(self.source));
        o.insert("scope".into(), json!(self.scope));
        o.insert("observed_at_utc_ms".into(), json!(now_ms() as u64));
        o.insert("received_monotonic_ms".into(), json!(self.started.elapsed().as_millis() as u64));
        o.insert("source_build_sha".into(), json!("f78d4305a4c12fde33767cad85d94f755c1e120a"));
        o.insert("parser_version".into(), json!("vanilla64-history-v1"));
        serde_json::to_writer(&mut self.writer, &v).map_err(|e| e.to_string())?;
        self.writer.write_all(b"\n").map_err(|e| e.to_string())?;
        self.writer.flush().map_err(|e| e.to_string())
    }
    pub fn owner_token(&self, owner: u64) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.key).unwrap();
        mac.update(self.market.as_bytes()); mac.update(&[0]); mac.update(&owner.to_le_bytes());
        mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect()
    }
    pub fn page(&mut self, page: u32, total: u32, payload: &[u8], records: Vec<Value>) -> Result<(), String> {
        use sha2::Digest;
        self.pages += 1;
        let hash: String = Sha256::digest(payload).iter().map(|b| format!("{b:02x}")).collect();
        self.emit(json!({"event_type":"PageObserved", "page":page, "listfrom":page*50,
            "total":total, "record_count":records.len(), "payload_sha256":hash, "records":records}))
    }
    pub fn finish(&mut self, status: &str, reason: &str) -> Result<(), String> {
        self.emit(json!({"event_type":"ScanFinished", "status":status, "reason":reason, "pages":self.pages}))?;
        self.writer.flush().map_err(|e| e.to_string())?;
        self.writer.get_ref().sync_all().map_err(|e| e.to_string())?;
        fs::rename(&self.partial, &self.final_path).map_err(|e| e.to_string())?;
        self.finished = true;
        println!("[AH-HISTORY] CAPTURE {status} pages={} file={}", self.pages, self.final_path.display());
        Ok(())
    }
}

impl Drop for Capture {
    fn drop(&mut self) { if !self.finished { let _ = self.finish("aborted", "run_failed_or_interrupted"); } }
}
