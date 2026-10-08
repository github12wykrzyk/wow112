//! One process/session lease and durable no-retry barrier for every economic mutation.
use std::{cell::RefCell, fs::{self, File, OpenOptions}, io::Write, path::{Path, PathBuf}};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind { Buy, Mail, Cancel, Post, Split }
impl Kind {
    fn permits(self, op: u32) -> bool {
        matches!((self, op), (Self::Buy, 0x25a) | (Self::Mail, 0x245 | 0x246) | (Self::Cancel, 0x257) | (Self::Post, 0x256) | (Self::Split, 0x10e))
    }
}
pub struct Coordinator {
    lock: PathBuf, pending: PathBuf, journal: File,
    active: Option<Kind>, sent: bool, stopped: bool,
}
fn fail(e: impl std::fmt::Display) -> String { format!("AH_MUTATION_COORDINATOR_HARD_STOP: {e}") }
impl Coordinator {
    pub fn open(root: &Path, key: &str) -> Result<Self, String> {
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(fail("invalid character scope"));
        }
        fs::create_dir_all(root).map_err(fail)?;
        let lock = root.join(format!("{key}.lock"));
        let mut file = OpenOptions::new().write(true).create_new(true).open(&lock).map_err(fail)?;
        // Never auto-expire a lock: a crashed process is a reconciliation task, not a lease timeout.
        writeln!(file, "pid={} scope={key}", std::process::id()).and_then(|_| file.sync_all()).map_err(fail)?;
        let pending = root.join(format!("{key}.pending"));
        if pending.exists() { let _ = fs::remove_file(&lock); return Err(fail("unresolved send from earlier process")); }
        let journal = match OpenOptions::new().append(true).create(true).open(root.join(format!("{key}.journal"))) {
            Ok(f) => f, Err(e) => { let _=fs::remove_file(&lock); return Err(fail(e)); }
        };
        Ok(Self { lock, pending, journal, active: None, sent: false, stopped: false })
    }
    pub fn begin(&mut self, kind: Kind) -> Result<(), String> {
        if self.stopped || self.active.is_some() || self.pending.exists() { return Err(fail("busy or unresolved operation")); }
        self.active=Some(kind); self.sent=false; Ok(())
    }
    pub fn before_send(&mut self, opcode: u32, payload: &[u8]) -> Result<(), String> {
        if self.stopped || self.sent || !self.active.is_some_and(|k| k.permits(opcode)) {
            return Err(fail("send has no matching exclusive mutation permit"));
        }
        // Barrier precedes the first byte, including a partial header write.
        self.sent=true;
        let result=(|| -> std::io::Result<()> {
            let mut p=OpenOptions::new().write(true).create_new(true).open(&self.pending)?;
            writeln!(p, "kind={:?} opcode={opcode:04x} payload={payload:02x?}", self.active)?;
            p.sync_all()?;
            writeln!(self.journal, "SEND_INTENT {:?} opcode={opcode:04x}",self.active)?;
            self.journal.sync_all()
        })();
        if let Err(e)=result { self.stopped=true; return Err(fail(e)); }
        Ok(())
    }
    pub fn finish(&mut self, result: Result<(),String>) -> Result<(),String> {
        if self.stopped { return Err(fail("coordinator already stopped")); }
        if self.sent {
            if let Err(e)=result { self.stopped=true; return Err(fail(e)); }
            let done=(|| -> std::io::Result<()> {
                writeln!(self.journal,"CONFIRMED_RECONCILED {:?}",self.active)?;
                self.journal.sync_all()?;
                fs::remove_file(&self.pending)
            })();
            if let Err(e)=done { self.stopped=true; return Err(fail(e)); }
        } else if let Err(e)=result { self.active=None; return Err(e); }
        self.active=None; self.sent=false; Ok(())
    }
    pub fn has_pending_send(&self) -> bool { self.pending.exists() }
}
impl Drop for Coordinator {
    fn drop(&mut self) { let _=fs::remove_file(&self.lock); }
}
thread_local! { static CURRENT: RefCell<Option<Coordinator>> = const { RefCell::new(None) }; }
pub struct Session;
impl Drop for Session { fn drop(&mut self) { CURRENT.with(|c| { c.borrow_mut().take(); }); } }
pub fn bind(server: &str, realm: u32, guid: u64) -> Result<Session,String> {
    let root = if cfg!(windows) {
        PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(||fail("LOCALAPPDATA unavailable"))?)
    } else {
        PathBuf::from(std::env::var_os("HOME").ok_or_else(||fail("HOME unavailable"))?).join(".local/share")
    }.join("WoW112/MutationCoordinatorV1");
    // An explicit stable server identity avoids world-address aliases splitting the lock.
    let server=server.to_ascii_lowercase();
    let encoded=server.bytes().map(|b|format!("{b:02x}")).collect::<String>();
    if encoded.is_empty() || encoded.len()>160 || guid==0 { return Err(fail("invalid server/character identity")); }
    CURRENT.with(|c| {
        let mut c=c.borrow_mut();
        if c.is_some() { return Err(fail("session already bound")); }
        *c=Some(Coordinator::open(&root,&format!("{encoded}-{realm}-{guid:016x}"))?); Ok(Session)
    })
}
pub fn before_send(opcode:u32,payload:&[u8])->Result<(),String> {
    if !matches!(opcode,0x10e|0x245|0x246|0x256|0x257|0x25a) { return Ok(()); }
    CURRENT.with(|c| c.borrow_mut().as_mut().ok_or_else(||fail("no character session"))?.before_send(opcode,payload))
}
pub fn pending_send_exists() -> bool {
    CURRENT.with(|c| c.borrow().as_ref().is_some_and(|x| x.has_pending_send()))
}
pub fn transaction(kind:Kind, action:impl FnOnce()->Result<(),String>)->Result<(),String> {
    CURRENT.with(|c| c.borrow_mut().as_mut().ok_or_else(||fail("no session"))?.begin(kind))?;
    let result=action();
    CURRENT.with(|c| c.borrow_mut().as_mut().ok_or_else(||fail("lost session"))?.finish(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root()->PathBuf { static N:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0); std::env::temp_dir().join(format!("life-test-{}-{}",std::process::id(),N.fetch_add(1,std::sync::atomic::Ordering::Relaxed))) }
    #[test] fn exclusive_and_independent_characters() { let r=root(); let c=Coordinator::open(&r,"a").unwrap(); assert!(Coordinator::open(&r,"a").is_err()); assert!(Coordinator::open(&r,"b").is_ok()); drop(c); assert!(Coordinator::open(&r,"a").is_ok()); fs::remove_dir_all(r).unwrap(); }
    #[test] fn all_mutations_freeze_on_uncertain_send_and_restart() { for (kind,op) in [(Kind::Buy,0x25a),(Kind::Mail,0x245),(Kind::Mail,0x246),(Kind::Cancel,0x257),(Kind::Post,0x256),(Kind::Split,0x10e)] {let r=root(); let mut c=Coordinator::open(&r,"a").unwrap();c.begin(kind).unwrap();c.before_send(op,&[1]).unwrap();assert!(c.has_pending_send());assert!(c.finish(Err("partial write / timeout".into())).is_err());for k in [Kind::Buy,Kind::Mail,Kind::Cancel,Kind::Post,Kind::Split] {assert!(c.begin(k).is_err());}drop(c);assert!(Coordinator::open(&r,"a").is_err());fs::remove_dir_all(r).unwrap();} }
    #[test] fn crash_after_intent_survives_without_finish() {let r=root();let mut c=Coordinator::open(&r,"a").unwrap();c.begin(Kind::Post).unwrap();c.before_send(0x256,&[]).unwrap();assert!(c.has_pending_send());drop(c);assert!(Coordinator::open(&r,"a").is_err());fs::remove_dir_all(r).unwrap();}
    #[test] fn ack_and_reconcile_allow_next_operation() {let r=root();let mut c=Coordinator::open(&r,"a").unwrap();for k in [Kind::Mail,Kind::Mail] {c.begin(k).unwrap();c.before_send(0x246,&[]).unwrap();c.finish(Ok(())).unwrap();assert!(!c.has_pending_send());}drop(c);assert!(Coordinator::open(&r,"a").is_ok());fs::remove_dir_all(r).unwrap();}
    #[test] fn split_reconcile_allows_post() {let r=root();let mut c=Coordinator::open(&r,"a").unwrap();c.begin(Kind::Split).unwrap();c.before_send(0x10e,&[]).unwrap();c.finish(Ok(())).unwrap();c.begin(Kind::Post).unwrap();c.before_send(0x256,&[]).unwrap();c.finish(Ok(())).unwrap();drop(c);assert!(Coordinator::open(&r,"a").is_ok());fs::remove_dir_all(r).unwrap();}
    #[test] fn no_send_failure_is_not_uncertain() {let r=root();let mut c=Coordinator::open(&r,"a").unwrap();c.begin(Kind::Buy).unwrap();assert!(c.finish(Err("stale target".into())).is_err());assert!(!c.has_pending_send());c.begin(Kind::Mail).unwrap();assert!(c.before_send(0x257,&[]).is_err());c.finish(Err("wrong op".into())).unwrap_err();drop(c);fs::remove_dir_all(r).unwrap();}
    #[test] fn nested_and_duplicate_sends_blocked() {let r=root();let mut c=Coordinator::open(&r,"a").unwrap();c.begin(Kind::Cancel).unwrap();assert!(c.begin(Kind::Buy).is_err());c.before_send(0x257,&[]).unwrap();assert!(c.before_send(0x257,&[]).is_err());drop(c);fs::remove_dir_all(r).unwrap();}
}
