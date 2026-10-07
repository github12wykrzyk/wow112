use crate::tele11_executor_contract::{
    classify_external_executor, logs_have_uncertain_marker, ExecutorRuntimeState,
    ExecutorVerdict, ExecutorVerdictClass,
};
use crate::tele11_executor_process::{
    read_role_state, spawn_clicker, spawn_summoner, stop_role, ExternalExecutorConfig,
    ManagedRole, ACCEPTOR_EXE, SUMMONER_EXE,
};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const POLL_MS: u64 = 250;
const READY_STABLE_MS: u64 = 2_000;

struct RuntimeLog {
    file: std::fs::File,
}

impl RuntimeLog {
    fn open(path: &Path) -> Result<Self, String> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|error| format!("open TELE11 executor log {} failed: {error}", path.display()))?;
        Ok(Self { file })
    }

    fn line(&mut self, message: &str) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let line = format!("[{}.{:03}] {message}", now.as_secs(), now.subsec_millis());
        println!("{line}");
        let _ = writeln!(self.file, "{line}");
        let _ = self.file.flush();
    }
}

fn observe(role: &mut ManagedRole, log: &mut RuntimeLog) -> ExecutorRuntimeState {
    let state = read_role_state(role);
    if role.last_state.as_ref() != Some(&state) {
        role.last_state = Some(state.clone());
        role.last_progress = Instant::now();
        log.line(&format!(
            "STATE role={} state={} session={} detail={}",
            role.label, state.state, state.session, state.detail
        ));
    }
    state
}

fn stop_all(roles: &mut BTreeMap<&'static str, ManagedRole>, log: &mut RuntimeLog) {
    for role in roles.values_mut() {
        let pid = role.child.id();
        stop_role(role);
        log.line(&format!("STOP role={} pid={pid}", role.label));
    }
}

fn wait_clickers_ready(
    roles: &mut BTreeMap<&'static str, ManagedRole>,
    config: &ExternalExecutorConfig,
    log: &mut RuntimeLog,
) -> Result<(), String> {
    let deadline = Instant::now() + config.ready_timeout;
    let mut stable_since: Option<Instant> = None;
    loop {
        if Instant::now() >= deadline {
            return Err("clicker READY timeout before summoner activation".to_string());
        }
        let mut ready = true;
        for label in ["CLICKER1", "CLICKER2"] {
            let role = roles
                .get_mut(label)
                .ok_or_else(|| format!("missing controlled role {label}"))?;
            match role.child.try_wait() {
                Ok(Some(status)) => {
                    return Err(format!("{label} exited before active phase status={status}"));
                }
                Err(error) => {
                    return Err(format!("{label} status failed before active phase: {error}"));
                }
                Ok(None) => {}
            }
            if observe(role, log).state != "READY" {
                ready = false;
            }
        }
        if ready {
            if let Some(since) = stable_since {
                if since.elapsed() >= Duration::from_millis(READY_STABLE_MS) {
                    log.line("READY_GATE PASS clickers=2/2 stable=2s");
                    return Ok(());
                }
            } else {
                stable_since = Some(Instant::now());
                log.line("READY_GATE clickers=2/2 observed; stability timer started");
            }
        } else {
            stable_since = None;
        }
        thread::sleep(Duration::from_millis(POLL_MS));
    }
}

fn active_snapshot(
    roles: &mut BTreeMap<&'static str, ManagedRole>,
    log: &mut RuntimeLog,
) -> Result<(ExecutorRuntimeState, ExecutorRuntimeState, ExecutorRuntimeState, bool, bool), String> {
    let mut states = BTreeMap::<&'static str, ExecutorRuntimeState>::new();
    let mut child_exited = false;
    let mut uncertain_marker = false;
    for label in ["CLICKER1", "CLICKER2", "SUMMONER"] {
        let role = roles
            .get_mut(label)
            .ok_or_else(|| format!("missing active role {label}"))?;
        match role.child.try_wait() {
            Ok(Some(status)) => {
                child_exited = true;
                log.line(&format!("ACTIVE_EXIT role={label} status={status}"));
            }
            Err(error) => {
                child_exited = true;
                log.line(&format!("ACTIVE_STATUS_ERROR role={label} error={error}"));
            }
            Ok(None) => {}
        }
        let state = observe(role, log);
        let stdout = fs::read_to_string(&role.stdout_path).unwrap_or_default();
        let stderr = fs::read_to_string(&role.stderr_path).unwrap_or_default();
        if logs_have_uncertain_marker(&stdout, &stderr) {
            uncertain_marker = true;
        }
        states.insert(label, state);
    }
    Ok((
        states.remove("SUMMONER").unwrap(),
        states.remove("CLICKER1").unwrap(),
        states.remove("CLICKER2").unwrap(),
        child_exited,
        uncertain_marker,
    ))
}

fn monitor_active(
    roles: &mut BTreeMap<&'static str, ManagedRole>,
    config: &ExternalExecutorConfig,
    log: &mut RuntimeLog,
) -> Result<ExecutorVerdict, String> {
    let deadline = Instant::now() + config.active_timeout;
    let mut offer_since: Option<Instant> = None;
    loop {
        let timed_out = Instant::now() >= deadline;
        let (summoner, clicker1, clicker2, child_exited, uncertain_marker) =
            active_snapshot(roles, log)?;

        let offered_now = summoner.state == "PASS_RITUAL_STARTED"
            && clicker1.state == "PORTAL_USE_SENT"
            && clicker2.state == "PORTAL_USE_SENT";
        if offered_now {
            if offer_since.is_none() {
                offer_since = Some(Instant::now());
                log.line(&format!(
                    "OFFER_GATE observed; settle_ms={} before success",
                    config.offer_settle.as_millis()
                ));
            }
        } else {
            offer_since = None;
        }
        let offered_stable = offer_since
            .map(|since| since.elapsed() >= config.offer_settle)
            .unwrap_or(false);

        if let Some(verdict) = classify_external_executor(
            &summoner,
            &clicker1,
            &clicker2,
            true,
            offered_stable,
            uncertain_marker,
            child_exited,
            timed_out,
        ) {
            return Ok(verdict);
        }
        thread::sleep(Duration::from_millis(POLL_MS));
    }
}

fn write_verdict(config: &ExternalExecutorConfig, verdict: &ExecutorVerdict) -> Result<(), String> {
    let replay_safe = matches!(verdict.class, ExecutorVerdictClass::SafePreActive);
    let body = format!(
        "result={}\nclass={:?}\nreplay_safe={}\ncustomer={}\ndestination={}\nresource={}\ndetail={}\n",
        verdict.code,
        verdict.class,
        replay_safe,
        config.customer,
        config.destination,
        config.resource,
        verdict.detail.replace('\r', " ").replace('\n', " ")
    );
    fs::write(config.run_dir.join("EXECUTOR_VERDICT.txt"), body)
        .map_err(|error| format!("write TELE11 executor verdict failed: {error}"))
}

pub fn run_external_executor(config: ExternalExecutorConfig) -> Result<i32, String> {
    fs::create_dir_all(&config.run_dir)
        .map_err(|error| format!("create {} failed: {error}", config.run_dir.display()))?;
    let exe = std::env::current_exe().map_err(|error| format!("current_exe failed: {error}"))?;
    let root = exe
        .parent()
        .ok_or_else(|| "TELE11 executor has no executable parent".to_string())?
        .to_path_buf();
    for child in [ACCEPTOR_EXE, SUMMONER_EXE] {
        if !root.join(child).exists() {
            return Err(format!("required child runtime missing: {child}"));
        }
    }
    let mut log = RuntimeLog::open(&config.run_dir.join("EXECUTOR.log"))?;
    log.line(&format!(
        "START customer={} destination={} resource={} summoner={} clickers=[{},{}]",
        config.customer,
        config.destination,
        config.resource,
        config.summoner.character,
        config.clicker1.character,
        config.clicker2.character
    ));

    let mut roles = BTreeMap::new();
    roles.insert(
        "CLICKER1",
        spawn_clicker(&root, &config, "CLICKER1", &config.clicker1, 150)?,
    );
    thread::sleep(Duration::from_millis(250));
    roles.insert(
        "CLICKER2",
        spawn_clicker(&root, &config, "CLICKER2", &config.clicker2, 300)?,
    );

    if let Err(error) = wait_clickers_ready(&mut roles, &config, &mut log) {
        let verdict = ExecutorVerdict {
            class: ExecutorVerdictClass::SafePreActive,
            code: "FAIL_SAFE_PRE_ACTIVE".to_string(),
            detail: error,
        };
        stop_all(&mut roles, &mut log);
        write_verdict(&config, &verdict)?;
        return Ok(2);
    }

    roles.insert("SUMMONER", spawn_summoner(&root, &config)?);
    log.line("ACTIVE_PHASE summoner spawned; all subsequent ambiguous failures are no-replay");
    let verdict = monitor_active(&mut roles, &config, &mut log)?;
    stop_all(&mut roles, &mut log);
    write_verdict(&config, &verdict)?;
    log.line(&format!("VERDICT {} {:?}", verdict.code, verdict.class));
    Ok(match verdict.class {
        ExecutorVerdictClass::Pass => 0,
        ExecutorVerdictClass::SafePreActive => 2,
        ExecutorVerdictClass::UncertainDoNotReplay => 3,
    })
}
