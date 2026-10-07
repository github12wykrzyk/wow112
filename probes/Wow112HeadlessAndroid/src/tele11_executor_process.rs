use crate::tele11_executor_contract::{parse_executor_runtime_state, ExecutorRuntimeState};
use std::env;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

pub const ACCEPTOR_EXE: &str = "tele06a_acceptor_runtime.exe";
pub const SUMMONER_EXE: &str = "tele06a_ritual_runtime.exe";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub account: String,
    pub character: String,
}

#[derive(Clone, Debug)]
pub struct ExternalExecutorConfig {
    pub customer: String,
    pub destination: String,
    pub resource: String,
    pub summoner: Identity,
    pub clicker1: Identity,
    pub clicker2: Identity,
    pub password: String,
    pub realm_index: usize,
    pub run_dir: PathBuf,
    pub ready_timeout: Duration,
    pub active_timeout: Duration,
    pub offer_settle: Duration,
}

impl ExternalExecutorConfig {
    pub fn from_env() -> Result<Self, String> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let run_dir = env::var("WOW112_TELE11_RUN_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("tele11_runs").join(format!("executor_{now}")));
        Ok(Self {
            customer: required("WOW112_TELE11_CUSTOMER_CHARACTER")?,
            destination: required("WOW112_TELE11_DESTINATION")?,
            resource: required("WOW112_TELE11_RESOURCE")?,
            summoner: identity("SUMMONER")?,
            clicker1: identity("CLICKER1")?,
            clicker2: identity("CLICKER2")?,
            password: required("WOW112_PASSWORD")?,
            realm_index: env::var("WOW112_REALM_INDEX")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(1),
            run_dir,
            ready_timeout: Duration::from_secs(env_u64(
                "WOW112_TELE11_READY_TIMEOUT_SECS",
                180,
            )?),
            active_timeout: Duration::from_secs(env_u64(
                "WOW112_TELE11_ACTIVE_TIMEOUT_SECS",
                360,
            )?),
            offer_settle: Duration::from_millis(env_u64(
                "WOW112_TELE11_OFFER_SETTLE_MS",
                3_000,
            )?),
        })
    }

    pub fn self_test() -> Self {
        Self {
            customer: "Customer".into(),
            destination: "winterspring".into(),
            resource: "summon/winterspring".into(),
            summoner: Identity {
                account: "sum-account".into(),
                character: "Summoner".into(),
            },
            clicker1: Identity {
                account: "click1-account".into(),
                character: "Clickone".into(),
            },
            clicker2: Identity {
                account: "click2-account".into(),
                character: "Clicktwo".into(),
            },
            password: "self-test".into(),
            realm_index: 1,
            run_dir: PathBuf::from("tele11-self-test"),
            ready_timeout: Duration::from_secs(180),
            active_timeout: Duration::from_secs(360),
            offer_settle: Duration::from_secs(3),
        }
    }
}

fn required(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing or empty {name}"))
}

fn env_u64(name: &str, default_value: u64) -> Result<u64, String> {
    match env::var(name) {
        Ok(value) => value
            .trim()
            .parse::<u64>()
            .map_err(|error| format!("invalid {name}={value:?}: {error}")),
        Err(_) => Ok(default_value),
    }
}

fn identity(prefix: &str) -> Result<Identity, String> {
    Ok(Identity {
        account: required(&format!("WOW112_TELE11_{prefix}_ACCOUNT"))?,
        character: required(&format!("WOW112_TELE11_{prefix}_CHARACTER"))?,
    })
}

#[derive(Debug)]
pub struct ManagedRole {
    pub label: &'static str,
    pub child: Child,
    pub state_path: PathBuf,
    pub stdout_path: PathBuf,
    pub stderr_path: PathBuf,
    pub last_state: Option<ExecutorRuntimeState>,
    pub last_progress: Instant,
}

fn role_paths(run_dir: &Path, label: &'static str) -> (PathBuf, PathBuf, PathBuf) {
    (
        run_dir.join(format!("STATE_{label}.txt")),
        run_dir.join(format!("{label}.stdout.log")),
        run_dir.join(format!("{label}.stderr.log")),
    )
}

pub fn read_role_state(role: &ManagedRole) -> ExecutorRuntimeState {
    fs::read_to_string(&role.state_path)
        .map(|text| parse_executor_runtime_state(&text))
        .unwrap_or_else(|_| ExecutorRuntimeState::connecting())
}

pub fn spawn_clicker(
    root: &Path,
    config: &ExternalExecutorConfig,
    label: &'static str,
    identity: &Identity,
    settle_ms: u64,
) -> Result<ManagedRole, String> {
    let exe = root.join(ACCEPTOR_EXE);
    if !exe.exists() {
        return Err(format!("missing clicker runtime {}", exe.display()));
    }
    let (state_path, stdout_path, stderr_path) = role_paths(&config.run_dir, label);
    let stdout = File::create(&stdout_path)
        .map_err(|error| format!("create {} failed: {error}", stdout_path.display()))?;
    let stderr = File::create(&stderr_path)
        .map_err(|error| format!("create {} failed: {error}", stderr_path.display()))?;
    let mut command = Command::new(exe);
    command
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", &config.password)
        .env("WOW112_ACCOUNT", &identity.account)
        .env("WOW112_CHARACTER", &identity.character)
        .env("WOW112_REALM_INDEX", config.realm_index.to_string())
        .env("WOW112_RECONNECT_LIMIT", "60")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path)
        .env("WOW112_TELE_AUTO_ACCEPT_FROM", &config.summoner.character)
        .env("WOW112_TELE06B_ROLE", "clicker")
        .env("WOW112_TELE06B_MAX_RANGE", "5.8")
        .env("WOW112_TELE06B_CLICK_SETTLE_MS", settle_ms.to_string());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let child = command
        .spawn()
        .map_err(|error| format!("spawn {label} failed: {error}"))?;
    Ok(ManagedRole {
        label,
        child,
        state_path,
        stdout_path,
        stderr_path,
        last_state: None,
        last_progress: Instant::now(),
    })
}

pub fn spawn_summoner(
    root: &Path,
    config: &ExternalExecutorConfig,
) -> Result<ManagedRole, String> {
    let exe = root.join(SUMMONER_EXE);
    if !exe.exists() {
        return Err(format!("missing summoner runtime {}", exe.display()));
    }
    let (state_path, stdout_path, stderr_path) = role_paths(&config.run_dir, "SUMMONER");
    let stdout = File::create(&stdout_path)
        .map_err(|error| format!("create {} failed: {error}", stdout_path.display()))?;
    let stderr = File::create(&stderr_path)
        .map_err(|error| format!("create {} failed: {error}", stderr_path.display()))?;
    let invite_list = format!(
        "{},{},{}",
        config.clicker1.character, config.clicker2.character, config.customer
    );
    let mut command = Command::new(exe);
    command
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", &config.password)
        .env("WOW112_ACCOUNT", &config.summoner.account)
        .env("WOW112_CHARACTER", &config.summoner.character)
        .env("WOW112_REALM_INDEX", config.realm_index.to_string())
        .env("WOW112_RECONNECT_LIMIT", "60")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path)
        .env("WOW112_TELE_RESET_GROUP", "1")
        .env("WOW112_TELE_INVITE_LIST", invite_list)
        .env("WOW112_RITUAL_TARGET_NAME", &config.customer);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let child = command
        .spawn()
        .map_err(|error| format!("spawn SUMMONER failed: {error}"))?;
    Ok(ManagedRole {
        label: "SUMMONER",
        child,
        state_path,
        stdout_path,
        stderr_path,
        last_state: None,
        last_progress: Instant::now(),
    })
}

pub fn stop_role(role: &mut ManagedRole) {
    if role.child.try_wait().ok().flatten().is_none() {
        let _ = role.child.kill();
        let _ = role.child.wait();
    }
}
