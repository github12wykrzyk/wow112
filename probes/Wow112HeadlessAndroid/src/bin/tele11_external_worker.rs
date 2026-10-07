use std::collections::HashMap;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const ACCEPTOR_EXE: &str = "tele06a_acceptor_runtime.exe";
const SUMMONER_EXE: &str = "tele06a_ritual_runtime.exe";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const POLL_MS: u64 = 250;
const READY_STABLE_MS: u64 = 2_000;
const DEFAULT_READY_TIMEOUT_SECS: u64 = 180;
const DEFAULT_JOB_TIMEOUT_SECS: u64 = 600;
const DEFAULT_STALE_SECS: u64 = 90;
const PORTAL_TIMEOUT_SECS: u64 = 45;

#[derive(Clone, Debug)]
struct Endpoint {
    label: &'static str,
    account: String,
    character: String,
    settle_ms: Option<u64>,
}

#[derive(Clone, Debug)]
struct Config {
    customer: String,
    destination: String,
    trigger_message: String,
    summoner: Endpoint,
    clicker1: Endpoint,
    clicker2: Endpoint,
    ready_timeout: Duration,
    job_timeout: Duration,
    stale_timeout: Duration,
    self_test: bool,
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
            state: "CONNECTING".into(),
            session: 0,
            detail: detail.into(),
        }
    }
}

#[derive(Debug)]
struct ManagedRole {
    endpoint: Endpoint,
    child: Child,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
    state_path: PathBuf,
    last_observed: Option<RuntimeState>,
    last_progress: Instant,
}

struct WorkerLog {
    file: File,
}

impl WorkerLog {
    fn new(path: &Path) -> Result<Self, String> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| format!("open worker log failed: {e}"))?;
        Ok(Self { file })
    }

    fn log(&mut self, message: &str) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let line = format!("[{}.{:03}] {message}", now.as_secs(), now.subsec_millis());
        println!("{line}");
        let _ = writeln!(self.file, "{line}");
        let _ = self.file.flush();
    }
}

#[derive(Clone, Debug)]
struct Verdict {
    code: String,
    detail: String,
    replay_allowed: bool,
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].trim().to_string())
        .filter(|value| !value.is_empty())
}

fn env_or(name: &str, default_value: &str) -> String {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default_value.to_string())
}

fn env_u64(name: &str, default_value: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(default_value)
}

fn config_from_args() -> Result<Config, String> {
    let args: Vec<String> = env::args().collect();
    let self_test = args.iter().any(|arg| arg == "--self-test");
    let customer = arg_value(&args, "--customer")
        .or_else(|| env::var("WOW112_TELE11_CUSTOMER").ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| if self_test { "Externalcustomer".into() } else { String::new() });
    let destination = arg_value(&args, "--destination")
        .or_else(|| env::var("WOW112_TELE11_DESTINATION").ok())
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| if self_test { "hyjal".into() } else { String::new() });
    if customer.is_empty() {
        return Err("missing --customer or WOW112_TELE11_CUSTOMER".into());
    }
    if destination.is_empty() {
        return Err("missing --destination or WOW112_TELE11_DESTINATION".into());
    }
    if customer.contains(',') || customer.as_bytes().contains(&0) {
        return Err("customer name contains an unsafe delimiter".into());
    }

    let trigger_message = env::var("WOW112_TELE11_TRIGGER_MESSAGE")
        .unwrap_or_else(|_| "external-worker".into());
    let summoner = Endpoint {
        label: "SUMMONER",
        account: env_or("WOW112_TELE11_SUMMONER_ACCOUNT", "taxi3"),
        character: env_or("WOW112_TELE11_SUMMONER_CHARACTER", "Teletanaris"),
        settle_ms: None,
    };
    let clicker1 = Endpoint {
        label: "SLAVE1",
        account: env_or("WOW112_TELE11_CLICKER1_ACCOUNT", "octowinter1"),
        character: env_or("WOW112_TELE11_CLICKER1_CHARACTER", "Winterone"),
        settle_ms: Some(env_u64("WOW112_TELE11_CLICKER1_SETTLE_MS", 150)),
    };
    let clicker2 = Endpoint {
        label: "SLAVE2",
        account: env_or("WOW112_TELE11_CLICKER2_ACCOUNT", "octowinter2"),
        character: env_or("WOW112_TELE11_CLICKER2_CHARACTER", "Wintertwoo"),
        settle_ms: Some(env_u64("WOW112_TELE11_CLICKER2_SETTLE_MS", 300)),
    };
    if [summoner.character.as_str(), clicker1.character.as_str(), clicker2.character.as_str()]
        .iter()
        .any(|name| name.eq_ignore_ascii_case(&customer))
    {
        return Err("external customer must not be one of the controlled service characters".into());
    }

    Ok(Config {
        customer,
        destination,
        trigger_message,
        summoner,
        clicker1,
        clicker2,
        ready_timeout: Duration::from_secs(env_u64(
            "WOW112_TELE11_READY_TIMEOUT_SECS",
            DEFAULT_READY_TIMEOUT_SECS,
        )),
        job_timeout: Duration::from_secs(env_u64(
            "WOW112_TELE11_JOB_TIMEOUT_SECS",
            DEFAULT_JOB_TIMEOUT_SECS,
        )),
        stale_timeout: Duration::from_secs(env_u64(
            "WOW112_TELE11_STALE_SECS",
            DEFAULT_STALE_SECS,
        )),
        self_test,
    })
}

fn parse_runtime_state(text: &str) -> RuntimeState {
    let mut state = "CONNECTING".to_string();
    let mut session = 0u32;
    let mut detail = "waiting for runtime state file".to_string();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
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
    fs::read_to_string(path)
        .map(|text| parse_runtime_state(&text))
        .unwrap_or_else(|_| RuntimeState::connecting("waiting for runtime state file"))
}

fn write_worker_state(run_dir: &Path, state: &str, detail: &str) {
    let safe = detail.replace(['\r', '\n'], " ");
    let _ = fs::write(
        run_dir.join("WORKER_STATE.txt"),
        format!("state={state}\ndetail={safe}\n"),
    );
}

fn write_verdict(run_dir: &Path, config: &Config, verdict: &Verdict) {
    let detail = verdict.detail.replace(['\r', '\n'], " ");
    let body = format!(
        "result={}\ndetail={}\ncustomer={}\ndestination={}\nreplay_allowed={}\n",
        verdict.code, detail, config.customer, config.destination, verdict.replay_allowed
    );
    let _ = fs::write(run_dir.join("WORKER_VERDICT.txt"), body);
}

fn role_has_uncertain_marker(role: &ManagedRole) -> bool {
    let stdout = fs::read_to_string(&role.stdout_path).unwrap_or_default();
    let stderr = fs::read_to_string(&role.stderr_path).unwrap_or_default();
    let text = format!("{stdout}\n{stderr}");
    [
        "TELE06A_INVITE_MUTATION_UNCERTAIN",
        "TELE06A_CAST_MUTATION_UNCERTAIN",
        "TELE06A_SELECTION_MUTATION_UNCERTAIN",
        "TELE06B_PORTAL_MUTATION_UNCERTAIN",
        "TELE06C_MOVE_MUTATION_UNCERTAIN",
        "TELE10_TRADE_BEGIN_MUTATION_UNCERTAIN",
        "TELE10_TRADE_ACCEPT_MUTATION_UNCERTAIN",
    ]
    .iter()
    .any(|needle| text.contains(needle))
}

fn state_is_uncertain(state: &str) -> bool {
    state.contains("UNCERTAIN") || state == "FAIL_ACTIVE_STALE"
}

fn state_is_terminal_failure(state: &str) -> bool {
    state.starts_with("FAIL_") && !state_is_uncertain(state)
}

fn observe(role: &mut ManagedRole, log: &mut WorkerLog) -> RuntimeState {
    let state = read_runtime_state(&role.state_path);
    if role.last_observed.as_ref() != Some(&state) {
        log.log(&format!(
            "ROLE_STATE role={} state={} session={} detail={}",
            role.endpoint.label, state.state, state.session, state.detail
        ));
        role.last_progress = Instant::now();
        role.last_observed = Some(state.clone());
    }
    state
}

fn spawn_clicker(
    root: &Path,
    run_dir: &Path,
    password: &str,
    endpoint: &Endpoint,
    summoner_character: &str,
) -> Result<ManagedRole, String> {
    let exe = root.join(ACCEPTOR_EXE);
    if !exe.exists() {
        return Err(format!("missing runtime binary: {}", exe.display()));
    }
    let stdout_path = run_dir.join(format!("{}.stdout.log", endpoint.label));
    let stderr_path = run_dir.join(format!("{}.stderr.log", endpoint.label));
    let state_path = run_dir.join(format!("STATE_{}.txt", endpoint.label));
    let stdout = File::create(&stdout_path).map_err(|e| e.to_string())?;
    let stderr = File::create(&stderr_path).map_err(|e| e.to_string())?;
    let mut command = Command::new(exe);
    command
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_ACCOUNT", &endpoint.account)
        .env("WOW112_CHARACTER", &endpoint.character)
        .env("WOW112_REALM_INDEX", "1")
        .env("WOW112_RECONNECT_LIMIT", "60")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path)
        .env("WOW112_TELE_AUTO_ACCEPT_FROM", summoner_character)
        .env("WOW112_TELE06B_ROLE", "clicker")
        .env("WOW112_TELE06B_MAX_RANGE", "5.8");
    if let Some(settle_ms) = endpoint.settle_ms {
        command.env("WOW112_TELE06B_CLICK_SETTLE_MS", settle_ms.to_string());
    }
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let child = command.spawn().map_err(|e| format!("spawn {} failed: {e}", endpoint.label))?;
    Ok(ManagedRole {
        endpoint: endpoint.clone(),
        child,
        stdout_path,
        stderr_path,
        state_path,
        last_observed: None,
        last_progress: Instant::now(),
    })
}

fn spawn_summoner(
    root: &Path,
    run_dir: &Path,
    password: &str,
    config: &Config,
) -> Result<ManagedRole, String> {
    let exe = root.join(SUMMONER_EXE);
    if !exe.exists() {
        return Err(format!("missing runtime binary: {}", exe.display()));
    }
    let endpoint = &config.summoner;
    let stdout_path = run_dir.join("SUMMONER.stdout.log");
    let stderr_path = run_dir.join("SUMMONER.stderr.log");
    let state_path = run_dir.join("STATE_SUMMONER.txt");
    let stdout = File::create(&stdout_path).map_err(|e| e.to_string())?;
    let stderr = File::create(&stderr_path).map_err(|e| e.to_string())?;
    let invite_list = format!(
        "{},{},{}",
        config.customer, config.clicker1.character, config.clicker2.character
    );
    let mut command = Command::new(exe);
    command
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_ACCOUNT", &endpoint.account)
        .env("WOW112_CHARACTER", &endpoint.character)
        .env("WOW112_REALM_INDEX", "1")
        .env("WOW112_RECONNECT_LIMIT", "60")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path)
        .env("WOW112_TELE_RESET_GROUP", "1")
        .env("WOW112_TELE_INVITE_LIST", invite_list)
        .env("WOW112_RITUAL_TARGET_NAME", &config.customer)
        .env("WOW112_TELE_DESTINATION", &config.destination)
        .env("WOW112_TELE_TRIGGER_MESSAGE", &config.trigger_message);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let child = command.spawn().map_err(|e| format!("spawn SUMMONER failed: {e}"))?;
    Ok(ManagedRole {
        endpoint: endpoint.clone(),
        child,
        stdout_path,
        stderr_path,
        state_path,
        last_observed: None,
        last_progress: Instant::now(),
    })
}

fn stop_role(mut role: ManagedRole, log: &mut WorkerLog) {
    let pid = role.child.id();
    match role.child.try_wait() {
        Ok(Some(status)) => log.log(&format!("STOP role={} already_exited status={status}", role.endpoint.label)),
        _ => {
            let _ = role.child.kill();
            let _ = role.child.wait();
            log.log(&format!("STOP role={} pid={pid}", role.endpoint.label));
        }
    }
}

fn stop_all(managed: &mut HashMap<String, ManagedRole>, log: &mut WorkerLog) {
    let keys: Vec<String> = managed.keys().cloned().collect();
    for key in keys {
        if let Some(role) = managed.remove(&key) {
            stop_role(role, log);
        }
    }
}

fn wait_clickers_ready(
    managed: &mut HashMap<String, ManagedRole>,
    config: &Config,
    log: &mut WorkerLog,
) -> Result<(), String> {
    let deadline = Instant::now() + config.ready_timeout;
    let mut stable_since: Option<Instant> = None;
    loop {
        if Instant::now() >= deadline {
            return Err("clicker READY timeout before active mutation".into());
        }
        let mut all_ready = true;
        for label in ["SLAVE1", "SLAVE2"] {
            let role = managed.get_mut(label).ok_or_else(|| format!("missing {label}"))?;
            if let Some(status) = role.child.try_wait().map_err(|e| e.to_string())? {
                return Err(format!("{label} exited before active mutation status={status}"));
            }
            let state = observe(role, log);
            if state.state != "READY" {
                all_ready = false;
            }
            if role.last_progress.elapsed() >= config.stale_timeout {
                return Err(format!("{label} stale before active mutation state={}", state.state));
            }
        }
        if all_ready {
            if let Some(since) = stable_since {
                if since.elapsed() >= Duration::from_millis(READY_STABLE_MS) {
                    log.log("READY_GATE PASS clickers=2/2 stable=2s");
                    return Ok(());
                }
            } else {
                stable_since = Some(Instant::now());
            }
        } else {
            stable_since = None;
        }
        thread::sleep(Duration::from_millis(POLL_MS));
    }
}

fn monitor_active(
    managed: &mut HashMap<String, ManagedRole>,
    config: &Config,
    run_dir: &Path,
    log: &mut WorkerLog,
) -> Verdict {
    let deadline = Instant::now() + config.job_timeout;
    let mut ritual_started: Option<Instant> = None;
    let mut portal_complete_at: Option<Instant> = None;

    loop {
        for label in ["SLAVE1", "SLAVE2", "SUMMONER"] {
            let Some(role) = managed.get_mut(label) else {
                return Verdict { code: "FAIL_ACTIVE_ROLE_MISSING".into(), detail: label.into(), replay_allowed: false };
            };
            match role.child.try_wait() {
                Ok(Some(status)) => return Verdict {
                    code: "FAIL_ACTIVE_ROLE_EXITED".into(),
                    detail: format!("role={label} status={status}"),
                    replay_allowed: false,
                },
                Err(error) => return Verdict {
                    code: "FAIL_ACTIVE_ROLE_STATUS".into(),
                    detail: format!("role={label} error={error}"),
                    replay_allowed: false,
                },
                Ok(None) => {}
            }
            let state = observe(role, log);
            if role_has_uncertain_marker(role) || state_is_uncertain(&state.state) {
                return Verdict {
                    code: "FAIL_MUTATION_UNCERTAIN".into(),
                    detail: format!("role={label} state={} detail={}", state.state, state.detail),
                    replay_allowed: false,
                };
            }
            if state_is_terminal_failure(&state.state) {
                return Verdict {
                    code: state.state,
                    detail: format!("role={label} {}", state.detail),
                    replay_allowed: false,
                };
            }
            if role.last_progress.elapsed() >= config.stale_timeout {
                return Verdict {
                    code: "FAIL_ACTIVE_STALE".into(),
                    detail: format!("role={label} state={} stale={:?}", state.state, role.last_progress.elapsed()),
                    replay_allowed: false,
                };
            }
        }

        let summoner = managed.get("SUMMONER").map(|r| read_runtime_state(&r.state_path)).unwrap();
        let slave1 = managed.get("SLAVE1").map(|r| read_runtime_state(&r.state_path)).unwrap();
        let slave2 = managed.get("SLAVE2").map(|r| read_runtime_state(&r.state_path)).unwrap();

        if summoner.state == "PASS_RITUAL_STARTED" && ritual_started.is_none() {
            ritual_started = Some(Instant::now());
            write_worker_state(run_dir, "RITUAL_STARTED", &summoner.detail);
            log.log("CHECKPOINT ritual_started=true replay_allowed=false");
        }

        let portal_complete = slave1.state == "PORTAL_USE_SENT" && slave2.state == "PORTAL_USE_SENT";
        if portal_complete && portal_complete_at.is_none() {
            portal_complete_at = Some(Instant::now());
            write_worker_state(run_dir, "SUMMON_DISPATCHED", "both portal uses sent; external client outcome is not directly observable");
            log.log("CHECKPOINT summon_dispatched=true external_customer_ack_unobservable=true");
        }

        if summoner.state == "PASS_PAYMENT_COMPLETE" {
            if !portal_complete {
                return Verdict {
                    code: "FAIL_PAYMENT_WITHOUT_PORTAL_PROOF".into(),
                    detail: summoner.detail,
                    replay_allowed: false,
                };
            }
            return Verdict {
                code: "PASS_EXTERNAL_SUMMON_PAYMENT_COMPLETE".into(),
                detail: summoner.detail,
                replay_allowed: false,
            };
        }

        if let Some(started) = ritual_started {
            if portal_complete_at.is_none() && started.elapsed() >= Duration::from_secs(PORTAL_TIMEOUT_SECS) {
                return Verdict {
                    code: "FAIL_PORTAL_TIMEOUT".into(),
                    detail: format!("SLAVE1={} SLAVE2={}", slave1.state, slave2.state),
                    replay_allowed: false,
                };
            }
        }

        if Instant::now() >= deadline {
            if portal_complete_at.is_some() || ritual_started.is_some() {
                return Verdict {
                    code: "COMPLETE_EXTERNAL_UNPAID_NO_REPLAY".into(),
                    detail: "active summon mutation occurred; payment not settled before job deadline; external client accept/teleport cannot be safely inferred or replayed".into(),
                    replay_allowed: false,
                };
            }
            return Verdict {
                code: "FAIL_SAFE_PRE_MUTATION_TIMEOUT".into(),
                detail: "job deadline expired before ritual mutation".into(),
                replay_allowed: true,
            };
        }
        thread::sleep(Duration::from_millis(POLL_MS));
    }
}

fn make_run_dir(root: &Path) -> Result<PathBuf, String> {
    if let Ok(path) = env::var("WOW112_TELE11_RUN_DIR") {
        let path = PathBuf::from(path);
        fs::create_dir_all(&path).map_err(|e| e.to_string())?;
        return Ok(path);
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let path = root.join("results").join(format!("TELE11_EXTERNAL_{now}"));
    fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    Ok(path)
}

fn run_self_test(config: &Config) -> Result<(), String> {
    let parsed = parse_runtime_state("state=PASS_PAYMENT_COMPLETE\nsession=3\ndetail=paid\n");
    if parsed.state != "PASS_PAYMENT_COMPLETE" || parsed.session != 3 {
        return Err("state parser contract failed".into());
    }
    if !state_is_uncertain("FAIL_TRADE_ACCEPT_UNCERTAIN") {
        return Err("trade uncertain classifier failed".into());
    }
    if state_is_terminal_failure("PASS_PAYMENT_COMPLETE") {
        return Err("PASS state classified as terminal failure".into());
    }
    if config.customer.eq_ignore_ascii_case(&config.summoner.character) {
        return Err("external customer isolation failed".into());
    }
    println!("TELE11 EXTERNAL WORKER SELFTEST PASS");
    Ok(())
}

fn run(config: Config) -> Result<i32, String> {
    if config.self_test {
        run_self_test(&config)?;
        return Ok(0);
    }
    let password = env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    if password.trim().is_empty() {
        return Err("WOW112_PASSWORD is empty".into());
    }
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    let root = exe.parent().ok_or_else(|| "worker executable has no parent".to_string())?.to_path_buf();
    for file in [ACCEPTOR_EXE, SUMMONER_EXE] {
        if !root.join(file).exists() {
            return Err(format!("missing required child runtime {file}"));
        }
    }
    let run_dir = make_run_dir(&root)?;
    let mut log = WorkerLog::new(&run_dir.join("WORKER.log"))?;
    log.log(&format!(
        "TELE11 START customer={} destination={} summoner={} clickers=[{},{}]",
        config.customer, config.destination, config.summoner.character, config.clicker1.character, config.clicker2.character
    ));
    write_worker_state(&run_dir, "BOOTING", "starting two controlled clickers");

    let mut managed = HashMap::new();
    let clicker1 = spawn_clicker(&root, &run_dir, &password, &config.clicker1, &config.summoner.character)?;
    managed.insert("SLAVE1".into(), clicker1);
    thread::sleep(Duration::from_millis(250));
    let clicker2 = spawn_clicker(&root, &run_dir, &password, &config.clicker2, &config.summoner.character)?;
    managed.insert("SLAVE2".into(), clicker2);

    if let Err(error) = wait_clickers_ready(&mut managed, &config, &mut log) {
        stop_all(&mut managed, &mut log);
        let verdict = Verdict {
            code: "FAIL_SAFE_PRE_MUTATION_READY".into(),
            detail: error,
            replay_allowed: true,
        };
        write_verdict(&run_dir, &config, &verdict);
        return Ok(2);
    }

    write_worker_state(&run_dir, "ACTIVE", "clickers ready; starting summoner for external customer");
    let summoner = spawn_summoner(&root, &run_dir, &password, &config)?;
    managed.insert("SUMMONER".into(), summoner);
    let verdict = monitor_active(&mut managed, &config, &run_dir, &mut log);
    write_verdict(&run_dir, &config, &verdict);
    log.log(&format!("VERDICT code={} replay_allowed={} detail={}", verdict.code, verdict.replay_allowed, verdict.detail));
    stop_all(&mut managed, &mut log);

    if verdict.code == "PASS_EXTERNAL_SUMMON_PAYMENT_COMPLETE" || verdict.code == "COMPLETE_EXTERNAL_UNPAID_NO_REPLAY" {
        Ok(0)
    } else if verdict.replay_allowed {
        Ok(2)
    } else {
        Ok(3)
    }
}

fn main() {
    let config = match config_from_args() {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[TELE11] CONFIG ERROR: {error}");
            std::process::exit(2);
        }
    };
    match run(config) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("[TELE11] ERROR: {error}");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_payment_state() {
        let state = parse_runtime_state("state=PASS_PAYMENT_COMPLETE\nsession=2\ndetail=ok\n");
        assert_eq!(state.state, "PASS_PAYMENT_COMPLETE");
        assert_eq!(state.session, 2);
    }

    #[test]
    fn uncertain_trade_is_no_replay() {
        assert!(state_is_uncertain("FAIL_TRADE_ACCEPT_UNCERTAIN"));
        assert!(state_is_uncertain("FAIL_PORTAL_MUTATION_UNCERTAIN"));
    }
}
