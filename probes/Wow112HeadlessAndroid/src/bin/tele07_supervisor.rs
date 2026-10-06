use std::collections::HashMap;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const ACCEPTOR_EXE: &str = "tele06a_acceptor_runtime.exe";
const SUMMONER_EXE: &str = "tele06a_ritual_runtime.exe";
const POLL_MS: u64 = 250;
const READY_STABLE_MS: u64 = 2_000;
const DEFAULT_READY_TIMEOUT_SECS: u64 = 180;
const DEFAULT_CYCLE_TIMEOUT_SECS: u64 = 90;
const DEFAULT_STALE_SECS: u64 = 75;
const DEFAULT_RESTART_BUDGET: u32 = 5;
const PORTAL_TIMEOUT_SECS: u64 = 45;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

#[cfg(windows)]
#[link(name = "Kernel32")]
extern "system" {
    fn SetConsoleCtrlHandler(handler: Option<extern "system" fn(u32) -> i32>, add: i32) -> i32;
}

#[cfg(windows)]
extern "system" fn console_ctrl_handler(_ctrl_type: u32) -> i32 {
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
    1
}

#[cfg(windows)]
fn install_shutdown_handler() {
    unsafe {
        let _ = SetConsoleCtrlHandler(Some(console_ctrl_handler), 1);
    }
}

#[cfg(not(windows))]
fn install_shutdown_handler() {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RoleKind {
    Acceptor,
    Summoner,
}

#[derive(Clone, Copy, Debug)]
struct RoleSpec {
    label: &'static str,
    account: &'static str,
    character: &'static str,
    kind: RoleKind,
    acceptor_role: &'static str,
    settle_ms: Option<u64>,
}

const CUSTOMER: RoleSpec = RoleSpec {
    label: "CUSTOMER",
    account: "octowar1",
    character: "Smokinpole",
    kind: RoleKind::Acceptor,
    acceptor_role: "customer",
    settle_ms: None,
};
const SLAVE1: RoleSpec = RoleSpec {
    label: "SLAVE1",
    account: "octowinter1",
    character: "Winterone",
    kind: RoleKind::Acceptor,
    acceptor_role: "clicker",
    settle_ms: Some(150),
};
const SLAVE2: RoleSpec = RoleSpec {
    label: "SLAVE2",
    account: "octowinter2",
    character: "Wintertwoo",
    kind: RoleKind::Acceptor,
    acceptor_role: "clicker",
    settle_ms: Some(300),
};
const SUMMONER: RoleSpec = RoleSpec {
    label: "SUMMONER",
    account: "taxi3",
    character: "Teletanaris",
    kind: RoleKind::Summoner,
    acceptor_role: "",
    settle_ms: None,
};

fn acceptor_specs() -> [RoleSpec; 3] {
    [CUSTOMER, SLAVE1, SLAVE2]
}

fn role_spec(label: &str) -> Option<RoleSpec> {
    [CUSTOMER, SLAVE1, SLAVE2, SUMMONER]
        .iter()
        .copied()
        .find(|spec| spec.label.eq_ignore_ascii_case(label))
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RuntimeState {
    state: String,
    session: u32,
    detail: String,
}

impl RuntimeState {
    fn connecting(detail: &str) -> Self {
        Self {
            state: "CONNECTING".to_string(),
            session: 0,
            detail: detail.to_string(),
        }
    }
}

fn parse_runtime_state(text: &str) -> RuntimeState {
    let mut state = "CONNECTING".to_string();
    let mut session = 0u32;
    let mut detail = "waiting for runtime state file".to_string();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else { continue };
        match key.trim() {
            "state" => state = value.trim().to_string(),
            "session" => session = value.trim().parse::<u32>().unwrap_or(0),
            "detail" => detail = value.trim().to_string(),
            _ => {}
        }
    }
    RuntimeState { state, session, detail }
}

fn read_runtime_state(path: &Path) -> RuntimeState {
    match fs::read_to_string(path) {
        Ok(text) => parse_runtime_state(&text),
        Err(_) => RuntimeState::connecting("waiting for runtime state file"),
    }
}

fn is_ready_state(state: &RuntimeState) -> bool {
    state.state == "READY"
}

fn is_acceptor_uncertain_state(state: &str) -> bool {
    matches!(
        state,
        "FAIL_PORTAL_MUTATION_UNCERTAIN"
            | "FAIL_AUTO_POSITION_UNCERTAIN"
            | "FAIL_AUTO_POSITION_ALREADY_ATTEMPTED"
    )
}

fn is_acceptor_terminal_failure(state: &str) -> bool {
    matches!(
        state,
        "FAIL_PORTAL_MUTATION_UNCERTAIN"
            | "FAIL_PORTAL_OUT_OF_RANGE"
            | "FAIL_PORTAL_RANGE_UNKNOWN"
            | "FAIL_AUTO_POSITION_LIMIT"
            | "FAIL_AUTO_POSITION_UNCERTAIN"
            | "FAIL_AUTO_POSITION_ALREADY_ATTEMPTED"
    )
}

fn is_uncertain_code(code: &str) -> bool {
    code.contains("UNCERTAIN") || code == "FAIL_ACTIVE_ROLE_EXITED" || code == "FAIL_ACTIVE_STALE"
}

#[derive(Debug)]
struct ManagedRole {
    spec: RoleSpec,
    child: Child,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
    state_path: PathBuf,
    last_observed: Option<RuntimeState>,
    last_progress: Instant,
}

struct SupervisorLog {
    file: File,
}

impl SupervisorLog {
    fn new(path: &Path) -> io::Result<Self> {
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self { file })
    }

    fn log(&mut self, message: &str) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let line = format!("[{}.{:03}] {}", now.as_secs(), now.subsec_millis(), message);
        println!("{line}");
        let _ = writeln!(self.file, "{line}");
        let _ = self.file.flush();
    }
}

#[derive(Debug)]
struct Config {
    cycles: u32,
    ready_timeout: Duration,
    cycle_timeout: Duration,
    stale_timeout: Duration,
    restart_budget: u32,
    fault_role: Option<String>,
    fault_cycle: Option<u32>,
    self_test: bool,
}

fn parse_u32_arg(args: &[String], name: &str) -> Option<u32> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .and_then(|pair| pair[1].parse::<u32>().ok())
}

fn parse_u64_arg(args: &[String], name: &str) -> Option<u64> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .and_then(|pair| pair[1].parse::<u64>().ok())
}

fn parse_string_arg(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
}

fn env_u32(name: &str, default_value: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(default_value)
}

fn env_u64(name: &str, default_value: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default_value)
}

fn config_from_args() -> Result<Config, String> {
    let args: Vec<String> = env::args().collect();
    let self_test = args.iter().any(|arg| arg == "--self-test");
    let cycles = parse_u32_arg(&args, "--cycles")
        .unwrap_or_else(|| env_u32("WOW112_TELE07_CYCLES", 10))
        .max(1);
    let ready_timeout_secs = parse_u64_arg(&args, "--ready-timeout-secs")
        .unwrap_or_else(|| env_u64("WOW112_TELE07_READY_TIMEOUT_SECS", DEFAULT_READY_TIMEOUT_SECS));
    let cycle_timeout_secs = parse_u64_arg(&args, "--cycle-timeout-secs")
        .unwrap_or_else(|| env_u64("WOW112_TELE07_CYCLE_TIMEOUT_SECS", DEFAULT_CYCLE_TIMEOUT_SECS));
    let stale_secs = parse_u64_arg(&args, "--stale-secs")
        .unwrap_or_else(|| env_u64("WOW112_TELE07_STALE_SECS", DEFAULT_STALE_SECS));
    let restart_budget = parse_u32_arg(&args, "--restart-budget")
        .unwrap_or_else(|| env_u32("WOW112_TELE07_RESTART_BUDGET", DEFAULT_RESTART_BUDGET));
    let fault_role = parse_string_arg(&args, "--fault-role")
        .or_else(|| env::var("WOW112_TELE07_FAULT_ROLE").ok())
        .filter(|value| !value.trim().is_empty());
    let fault_cycle = parse_u32_arg(&args, "--fault-cycle")
        .or_else(|| env::var("WOW112_TELE07_FAULT_CYCLE").ok().and_then(|v| v.parse::<u32>().ok()));

    if let Some(role) = fault_role.as_deref() {
        let Some(spec) = role_spec(role) else {
            return Err(format!("invalid --fault-role={role:?}"));
        };
        if spec.kind != RoleKind::Acceptor {
            return Err("fault injection is restricted to CUSTOMER/SLAVE1/SLAVE2 before active mutation".to_string());
        }
    }

    Ok(Config {
        cycles,
        ready_timeout: Duration::from_secs(ready_timeout_secs.max(5)),
        cycle_timeout: Duration::from_secs(cycle_timeout_secs.max(15)),
        stale_timeout: Duration::from_secs(stale_secs.max(15)),
        restart_budget,
        fault_role,
        fault_cycle,
        self_test,
    })
}

fn run_self_test() -> Result<(), String> {
    let parsed = parse_runtime_state("state=READY\nsession=4\ndetail=fresh pong sequence=8\n");
    if parsed.state != "READY" || parsed.session != 4 || parsed.detail != "fresh pong sequence=8" {
        return Err("state parser contract failed".to_string());
    }
    if !is_ready_state(&parsed) {
        return Err("ready classifier failed".to_string());
    }
    if !is_acceptor_terminal_failure("FAIL_PORTAL_OUT_OF_RANGE") {
        return Err("terminal failure classifier failed".to_string());
    }
    if !is_acceptor_uncertain_state("FAIL_PORTAL_MUTATION_UNCERTAIN") {
        return Err("uncertain acceptor classifier failed".to_string());
    }
    if !is_uncertain_code("FAIL_ACTIVE_ROLE_EXITED") {
        return Err("active exit must be fail-closed".to_string());
    }
    if role_spec("slave1").map(|r| r.character) != Some("Winterone") {
        return Err("role table contract failed".to_string());
    }
    println!("TELE07 SUPERVISOR SELFTEST PASS");
    Ok(())
}

fn write_supervisor_state(run_dir: &Path, state: &str, detail: &str) {
    let safe_detail = detail.replace('\r', " ").replace('\n', " ");
    let body = format!("state={state}\ndetail={safe_detail}\n");
    let _ = fs::write(run_dir.join("SUPERVISOR_STATE.txt"), body);
}

fn read_text(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

fn role_has_uncertain_marker(role: &ManagedRole) -> bool {
    let text = format!("{}\n{}", read_text(&role.stdout_path), read_text(&role.stderr_path));
    [
        "TELE06A_CAST_MUTATION_UNCERTAIN",
        "TELE06A_SELECTION_MUTATION_UNCERTAIN",
        "TELE06A_ACCEPT_MUTATION_UNCERTAIN",
        "TELE06B_PORTAL_MUTATION_UNCERTAIN",
        "TELE06C_MOVE_MUTATION_UNCERTAIN",
    ]
    .iter()
    .any(|needle| text.contains(needle))
}

fn spawn_role(
    root: &Path,
    run_dir: &Path,
    password: &str,
    cycle: u32,
    spec: RoleSpec,
    restart_index: u32,
    log: &mut SupervisorLog,
) -> Result<ManagedRole, String> {
    let exe = match spec.kind {
        RoleKind::Acceptor => root.join(ACCEPTOR_EXE),
        RoleKind::Summoner => root.join(SUMMONER_EXE),
    };
    if !exe.exists() {
        return Err(format!("missing runtime binary: {}", exe.display()));
    }

    let stem = format!("CYCLE_{cycle:03}_{}_R{restart_index:02}", spec.label);
    let stdout_path = run_dir.join(format!("{stem}.stdout.log"));
    let stderr_path = run_dir.join(format!("{stem}.stderr.log"));
    let state_path = run_dir.join(format!("STATE_{}_C{cycle:03}_R{restart_index:02}.txt", spec.label));
    let stdout = File::create(&stdout_path).map_err(|e| format!("create stdout log failed: {e}"))?;
    let stderr = File::create(&stderr_path).map_err(|e| format!("create stderr log failed: {e}"))?;

    let mut command = Command::new(&exe);
    command
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_ACCOUNT", spec.account)
        .env("WOW112_CHARACTER", spec.character)
        .env("WOW112_REALM_INDEX", "1")
        .env("WOW112_RECONNECT_LIMIT", "60")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path);

    match spec.kind {
        RoleKind::Acceptor => {
            command
                .env("WOW112_TELE_AUTO_ACCEPT_FROM", SUMMONER.character)
                .env("WOW112_TELE06B_ROLE", spec.acceptor_role);
            if spec.acceptor_role == "clicker" {
                command.env("WOW112_TELE06B_MAX_RANGE", "5.8");
                if let Some(settle_ms) = spec.settle_ms {
                    command.env("WOW112_TELE06B_CLICK_SETTLE_MS", settle_ms.to_string());
                }
            }
        }
        RoleKind::Summoner => {
            command
                .env("WOW112_TELE_RESET_GROUP", "1")
                .env("WOW112_TELE_INVITE_LIST", "Smokinpole,Winterone,Wintertwoo")
                .env("WOW112_RITUAL_TARGET_NAME", "Smokinpole");
        }
    }

    #[cfg(windows)]
    {
        command.creation_flags(CREATE_NO_WINDOW);
    }

    let child = command
        .spawn()
        .map_err(|e| format!("spawn {} failed: {e}", spec.label))?;
    log.log(&format!(
        "START role={} pid={} account={} character={} cycle={} restart={}",
        spec.label,
        child.id(),
        spec.account,
        spec.character,
        cycle,
        restart_index
    ));
    Ok(ManagedRole {
        spec,
        child,
        stdout_path,
        stderr_path,
        state_path,
        last_observed: None,
        last_progress: Instant::now(),
    })
}

fn stop_role(mut role: ManagedRole, log: &mut SupervisorLog) {
    match role.child.try_wait() {
        Ok(Some(status)) => {
            log.log(&format!("STOP role={} already_exited status={status}", role.spec.label));
        }
        _ => {
            let pid = role.child.id();
            let _ = role.child.kill();
            let _ = role.child.wait();
            log.log(&format!("STOP role={} pid={pid}", role.spec.label));
        }
    }
}

fn stop_all(managed: &mut HashMap<String, ManagedRole>, log: &mut SupervisorLog) {
    let labels: Vec<String> = managed.keys().cloned().collect();
    for label in labels {
        if let Some(role) = managed.remove(&label) {
            stop_role(role, log);
        }
    }
}

fn observe_role(role: &mut ManagedRole, log: &mut SupervisorLog) -> RuntimeState {
    let state = read_runtime_state(&role.state_path);
    if role.last_observed.as_ref() != Some(&state) {
        log.log(&format!(
            "ROLE_STATE role={} state={} session={} detail={}",
            role.spec.label, state.state, state.session, state.detail
        ));
        role.last_progress = Instant::now();
        role.last_observed = Some(state.clone());
    }
    state
}

fn restart_role_pre_active(
    label: &str,
    root: &Path,
    run_dir: &Path,
    password: &str,
    cycle: u32,
    managed: &mut HashMap<String, ManagedRole>,
    restart_counts: &mut HashMap<String, u32>,
    config: &Config,
    log: &mut SupervisorLog,
    reason: &str,
) -> Result<(), String> {
    let spec = role_spec(label).ok_or_else(|| format!("unknown role {label}"))?;
    if spec.kind != RoleKind::Acceptor {
        return Err(format!("unsafe pre-active restart requested for non-acceptor {label}"));
    }
    let count = restart_counts.entry(spec.label.to_string()).or_insert(0);
    if *count >= config.restart_budget {
        return Err(format!("restart budget exhausted role={} count={} reason={reason}", spec.label, count));
    }
    *count += 1;
    write_supervisor_state(run_dir, "RECOVERING", &format!("role={} reason={reason}", spec.label));
    log.log(&format!("RECOVER role={} action=restart_only_this_role reason={reason} restart={}", spec.label, *count));
    if let Some(old) = managed.remove(spec.label) {
        stop_role(old, log);
    }
    let new_role = spawn_role(root, run_dir, password, cycle, spec, *count, log)?;
    managed.insert(spec.label.to_string(), new_role);
    Ok(())
}

fn wait_for_acceptors_ready(
    root: &Path,
    run_dir: &Path,
    password: &str,
    cycle: u32,
    managed: &mut HashMap<String, ManagedRole>,
    restart_counts: &mut HashMap<String, u32>,
    config: &Config,
    log: &mut SupervisorLog,
) -> Result<(), String> {
    let deadline = Instant::now() + config.ready_timeout;
    let mut stable_since: Option<Instant> = None;
    loop {
        if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
            return Err("shutdown requested".to_string());
        }
        if Instant::now() >= deadline {
            return Err("READY timeout: did not obtain stable 3/3 acceptors".to_string());
        }

        let mut all_ready = true;
        let mut restart_request: Option<(String, String)> = None;
        for spec in acceptor_specs() {
            let role = managed
                .get_mut(spec.label)
                .ok_or_else(|| format!("managed role missing: {}", spec.label))?;
            match role.child.try_wait() {
                Ok(Some(status)) => {
                    all_ready = false;
                    restart_request = Some((spec.label.to_string(), format!("process exited status={status}")));
                    break;
                }
                Err(error) => {
                    all_ready = false;
                    restart_request = Some((spec.label.to_string(), format!("process status error={error}")));
                    break;
                }
                Ok(None) => {}
            }
            let state = observe_role(role, log);
            if !is_ready_state(&state) {
                all_ready = false;
            }
            if role.last_progress.elapsed() >= config.stale_timeout {
                all_ready = false;
                restart_request = Some((
                    spec.label.to_string(),
                    format!("stale control-plane state={} for {:?}", state.state, role.last_progress.elapsed()),
                ));
                break;
            }
        }

        if let Some((label, reason)) = restart_request {
            stable_since = None;
            restart_role_pre_active(
                &label,
                root,
                run_dir,
                password,
                cycle,
                managed,
                restart_counts,
                config,
                log,
                &reason,
            )?;
            thread::sleep(Duration::from_millis(POLL_MS));
            continue;
        }

        if all_ready {
            if let Some(since) = stable_since {
                if since.elapsed() >= Duration::from_millis(READY_STABLE_MS) {
                    write_supervisor_state(run_dir, "HEALTHY", "3/3 acceptors READY stable for 2s");
                    log.log("READY_GATE PASS 3/3 stable=2s");
                    return Ok(());
                }
            } else {
                stable_since = Some(Instant::now());
                log.log("READY_GATE 3/3 observed; stability timer started");
            }
        } else {
            stable_since = None;
        }
        thread::sleep(Duration::from_millis(POLL_MS));
    }
}

#[derive(Debug)]
struct CycleVerdict {
    code: String,
    detail: String,
}

fn monitor_active_cycle(
    run_dir: &Path,
    managed: &mut HashMap<String, ManagedRole>,
    config: &Config,
    log: &mut SupervisorLog,
) -> CycleVerdict {
    let deadline = Instant::now() + config.cycle_timeout;
    let mut ritual_started_at: Option<Instant> = None;

    loop {
        if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
            return CycleVerdict { code: "SHUTDOWN".to_string(), detail: "shutdown requested during active cycle".to_string() };
        }
        if Instant::now() >= deadline {
            return CycleVerdict { code: "FAIL_CYCLE_TIMEOUT".to_string(), detail: "active cycle deadline exceeded".to_string() };
        }

        for label in ["CUSTOMER", "SLAVE1", "SLAVE2", "SUMMONER"] {
            let Some(role) = managed.get_mut(label) else {
                return CycleVerdict { code: "FAIL_ACTIVE_ROLE_MISSING".to_string(), detail: format!("role missing: {label}") };
            };
            match role.child.try_wait() {
                Ok(Some(status)) => {
                    return CycleVerdict { code: "FAIL_ACTIVE_ROLE_EXITED".to_string(), detail: format!("role={label} exited status={status}; active phase never auto-restarts") };
                }
                Err(error) => {
                    return CycleVerdict { code: "FAIL_ACTIVE_ROLE_EXITED".to_string(), detail: format!("role={label} status error={error}; active phase never auto-restarts") };
                }
                Ok(None) => {}
            }
            let state = observe_role(role, log);
            if role_has_uncertain_marker(role) || is_acceptor_uncertain_state(&state.state) {
                return CycleVerdict { code: "FAIL_MUTATION_UNCERTAIN".to_string(), detail: format!("role={label} state={} detail={}", state.state, state.detail) };
            }
            if role.last_progress.elapsed() >= config.stale_timeout {
                return CycleVerdict { code: "FAIL_ACTIVE_STALE".to_string(), detail: format!("role={label} state={} stale={:?}; active phase never auto-restarts", state.state, role.last_progress.elapsed()) };
            }
        }

        let summoner_state = managed.get("SUMMONER").map(|r| read_runtime_state(&r.state_path)).unwrap_or_else(|| RuntimeState::connecting("missing summoner"));
        if summoner_state.state == "FAIL_SERVER_REJECT" {
            return CycleVerdict { code: "FAIL_SERVER_REJECT".to_string(), detail: summoner_state.detail };
        }
        if summoner_state.state == "PASS_RITUAL_STARTED" && ritual_started_at.is_none() {
            ritual_started_at = Some(Instant::now());
            write_supervisor_state(run_dir, "HEALTHY", "Ritual 698 started; waiting for portal completion");
            log.log(&format!("CHECKPOINT PASS_RITUAL_STARTED detail={}", summoner_state.detail));
        }

        let customer = managed.get("CUSTOMER").map(|r| read_runtime_state(&r.state_path)).unwrap_or_else(|| RuntimeState::connecting("missing customer"));
        let slave1 = managed.get("SLAVE1").map(|r| read_runtime_state(&r.state_path)).unwrap_or_else(|| RuntimeState::connecting("missing slave1"));
        let slave2 = managed.get("SLAVE2").map(|r| read_runtime_state(&r.state_path)).unwrap_or_else(|| RuntimeState::connecting("missing slave2"));

        for (label, state) in [("SLAVE1", &slave1), ("SLAVE2", &slave2)] {
            if is_acceptor_terminal_failure(&state.state) {
                return CycleVerdict { code: state.state.clone(), detail: format!("{label}: {}", state.detail) };
            }
        }

        if customer.state == "PASS_RITUAL_COMPLETE"
            && slave1.state == "PORTAL_USE_SENT"
            && slave2.state == "PORTAL_USE_SENT"
        {
            return CycleVerdict {
                code: "PASS_RITUAL_COMPLETE".to_string(),
                detail: format!("server 0x02AB confirmed; {}", customer.detail),
            };
        }

        if let Some(started) = ritual_started_at {
            if started.elapsed() >= Duration::from_secs(PORTAL_TIMEOUT_SECS) {
                let (code, detail) = if slave1.state != "PORTAL_USE_SENT" || slave2.state != "PORTAL_USE_SENT" {
                    ("FAIL_PORTAL_TIMEOUT", format!("45s after ritual start SLAVE1={} SLAVE2={}", slave1.state, slave2.state))
                } else {
                    ("FAIL_COMPLETION_TIMEOUT", format!("portal uses sent but CUSTOMER={} without 0x02AB", customer.state))
                };
                return CycleVerdict { code: code.to_string(), detail };
            }
        }
        thread::sleep(Duration::from_millis(POLL_MS));
    }
}

fn append_cycle_result(run_dir: &Path, cycle: u32, verdict: &CycleVerdict) {
    let path = run_dir.join("CYCLE_RESULTS.txt");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "cycle={cycle} result={} detail={}", verdict.code, verdict.detail.replace('\n', " "));
    }
}

fn run_service(config: Config) -> Result<i32, String> {
    install_shutdown_handler();
    let exe_path = env::current_exe().map_err(|e| format!("current_exe failed: {e}"))?;
    let root = exe_path.parent().ok_or_else(|| "supervisor executable has no parent directory".to_string())?.to_path_buf();
    let password = env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    if password.is_empty() {
        return Err("WOW112_PASSWORD cannot be empty".to_string());
    }
    for file in [ACCEPTOR_EXE, SUMMONER_EXE] {
        if !root.join(file).exists() {
            return Err(format!("missing required child runtime: {file}"));
        }
    }

    let run_dir = env::var("WOW112_TELE07_RUN_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("results").join(format!("TELE07_{}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs())));
    fs::create_dir_all(&run_dir).map_err(|e| format!("create run directory failed: {e}"))?;
    let mut log = SupervisorLog::new(&run_dir.join("SUPERVISOR.log")).map_err(|e| format!("open supervisor log failed: {e}"))?;
    log.log(&format!("TELE07 START cycles={} ready_timeout={:?} cycle_timeout={:?} stale_timeout={:?} restart_budget={} fault_role={:?} fault_cycle={:?}",
        config.cycles, config.ready_timeout, config.cycle_timeout, config.stale_timeout, config.restart_budget, config.fault_role, config.fault_cycle));
    log.log("BASELINE TELE06C V1.6 immutable; child mutation guards are never reset in-process");
    write_supervisor_state(&run_dir, "BOOTING", "TELE07 supervisor starting");

    let mut managed: HashMap<String, ManagedRole> = HashMap::new();
    let mut total_pass = 0u32;
    let mut total_restarts = 0u32;

    for cycle in 1..=config.cycles {
        if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
            break;
        }
        write_supervisor_state(&run_dir, "BOOTING", &format!("cycle={cycle} arming fresh one-shot child guards"));
        log.log(&format!("CYCLE_START cycle={cycle}/{}", config.cycles));
        let mut restart_counts: HashMap<String, u32> = HashMap::new();

        for spec in acceptor_specs() {
            let role = spawn_role(&root, &run_dir, &password, cycle, spec, 0, &mut log)?;
            managed.insert(spec.label.to_string(), role);
            thread::sleep(Duration::from_millis(250));
        }

        if let Err(error) = wait_for_acceptors_ready(
            &root,
            &run_dir,
            &password,
            cycle,
            &mut managed,
            &mut restart_counts,
            &config,
            &mut log,
        ) {
            let verdict = CycleVerdict { code: "FAIL_READY_RECOVERY".to_string(), detail: error };
            append_cycle_result(&run_dir, cycle, &verdict);
            write_supervisor_state(&run_dir, "DEGRADED", &verdict.detail);
            log.log(&format!("CYCLE_FAIL cycle={cycle} code={} detail={}", verdict.code, verdict.detail));
            stop_all(&mut managed, &mut log);
            write_summary(&run_dir, &config, total_pass, total_restarts + restart_counts.values().sum::<u32>(), &verdict.code, &verdict.detail);
            return Ok(2);
        }

        if config.fault_cycle == Some(cycle) {
            if let Some(label) = config.fault_role.as_deref() {
                log.log(&format!("FAULT_INJECT cycle={cycle} role={label} action=kill_pre_active expected=recover_single_role"));
                if let Some(role) = managed.get_mut(label) {
                    let _ = role.child.kill();
                    let _ = role.child.wait();
                }
                restart_role_pre_active(
                    label,
                    &root,
                    &run_dir,
                    &password,
                    cycle,
                    &mut managed,
                    &mut restart_counts,
                    &config,
                    &mut log,
                    "intentional TELE07 pre-active fault injection",
                )?;
                wait_for_acceptors_ready(
                    &root,
                    &run_dir,
                    &password,
                    cycle,
                    &mut managed,
                    &mut restart_counts,
                    &config,
                    &mut log,
                )?;
                log.log(&format!("FAULT_RECOVERY PASS cycle={cycle} role={label}"));
            }
        }

        total_restarts += restart_counts.values().sum::<u32>();
        write_supervisor_state(&run_dir, "HEALTHY", &format!("cycle={cycle} starting summoner after stable 3/3 READY"));
        let summoner = spawn_role(&root, &run_dir, &password, cycle, SUMMONER, 0, &mut log)?;
        managed.insert(SUMMONER.label.to_string(), summoner);
        let verdict = monitor_active_cycle(&run_dir, &mut managed, &config, &mut log);
        append_cycle_result(&run_dir, cycle, &verdict);
        log.log(&format!("CYCLE_VERDICT cycle={cycle} code={} detail={}", verdict.code, verdict.detail));

        if verdict.code == "PASS_RITUAL_COMPLETE" {
            total_pass += 1;
            stop_all(&mut managed, &mut log);
            write_supervisor_state(&run_dir, "HEALTHY", &format!("cycle={cycle} PASS; recycling child processes for fresh one-shot guards"));
            thread::sleep(Duration::from_millis(750));
            continue;
        }

        let uncertain = is_uncertain_code(&verdict.code)
            || managed.values().any(role_has_uncertain_marker);
        stop_all(&mut managed, &mut log);
        let state = if uncertain { "BLOCKED" } else { "DEGRADED" };
        write_supervisor_state(&run_dir, state, &format!("cycle={cycle} {}: {}", verdict.code, verdict.detail));
        write_summary(&run_dir, &config, total_pass, total_restarts, &verdict.code, &verdict.detail);
        if uncertain {
            log.log("FAIL_CLOSED active/uncertain outcome: no automatic cycle replay");
            return Ok(3);
        }
        return Ok(2);
    }

    stop_all(&mut managed, &mut log);
    if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
        write_supervisor_state(&run_dir, "SHUTDOWN", "graceful shutdown requested");
        write_summary(&run_dir, &config, total_pass, total_restarts, "SHUTDOWN", "operator/console shutdown");
        log.log("TELE07 SHUTDOWN graceful child cleanup complete");
        return Ok(0);
    }

    let detail = format!("all {} requested cycles completed; pass={} restarts={}", config.cycles, total_pass, total_restarts);
    write_supervisor_state(&run_dir, "COMPLETE", &detail);
    write_summary(&run_dir, &config, total_pass, total_restarts, "PASS_TELE07", &detail);
    log.log(&format!("TELE07 COMPLETE {detail}"));
    Ok(0)
}

fn write_summary(run_dir: &Path, config: &Config, pass: u32, restarts: u32, result: &str, detail: &str) {
    let body = format!(
        "result={result}\ndetail={}\nrequested_cycles={}\npassed_cycles={}\nrole_restarts={}\ncore_baseline=TELE06C_V1_6\n",
        detail.replace('\r', " ").replace('\n', " "),
        config.cycles,
        pass,
        restarts
    );
    let _ = fs::write(run_dir.join("SUPERVISOR_VERDICT.txt"), body);
}

fn main() {
    let config = match config_from_args() {
        Ok(config) => config,
        Err(error) => {
            eprintln!("[TELE07] CONFIG ERROR: {error}");
            std::process::exit(2);
        }
    };
    if config.self_test {
        match run_self_test() {
            Ok(()) => return,
            Err(error) => {
                eprintln!("[TELE07] SELFTEST ERROR: {error}");
                std::process::exit(2);
            }
        }
    }
    match run_service(config) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("[TELE07] ERROR: {error}");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_control_plane_state() {
        let state = parse_runtime_state("state=AUTO_POSITION_SENT\nsession=8\ndetail=server acceptance unconfirmed\n");
        assert_eq!(state.state, "AUTO_POSITION_SENT");
        assert_eq!(state.session, 8);
    }

    #[test]
    fn active_exit_is_fail_closed() {
        assert!(is_uncertain_code("FAIL_ACTIVE_ROLE_EXITED"));
        assert!(is_uncertain_code("FAIL_ACTIVE_STALE"));
    }

    #[test]
    fn known_portal_range_failure_is_terminal_but_not_uncertain() {
        assert!(is_acceptor_terminal_failure("FAIL_PORTAL_OUT_OF_RANGE"));
        assert!(!is_acceptor_uncertain_state("FAIL_PORTAL_OUT_OF_RANGE"));
    }

    #[test]
    fn role_contract_is_frozen() {
        assert_eq!(CUSTOMER.account, "octowar1");
        assert_eq!(SLAVE1.character, "Winterone");
        assert_eq!(SLAVE2.character, "Wintertwoo");
        assert_eq!(SUMMONER.character, "Teletanaris");
        assert_eq!(SLAVE1.settle_ms, Some(150));
        assert_eq!(SLAVE2.settle_ms, Some(300));
    }
}
