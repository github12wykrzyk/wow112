use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use tele08_request_queue::ResourceKey;
use wow112_headless_android_probe::tele11_service_core::{
    ExecutorOutcome, JournalEvent, RouteConfig, ServiceCore, ServiceCoreConfig,
};

const INGRESS_EXE: &str = "tele11_ingress_once.exe";
const WORKER_EXE: &str = "tele11_external_worker.exe";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const DEFAULT_DEDUP_MS: u64 = 30_000;
const DEFAULT_EXPIRY_MS: u64 = 180_000;

#[derive(Clone, Debug)]
struct Config {
    destination: String,
    service_dir: PathBuf,
    journal_path: PathBuf,
    payment_ledger_path: PathBuf,
    once: bool,
    self_test: bool,
}

#[derive(Clone, Debug)]
struct WorkerVerdict {
    code: String,
    detail: String,
    replay_allowed: bool,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn env_u64(name: &str, default_value: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(default_value)
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].trim().to_string())
        .filter(|value| !value.is_empty())
}

fn config_from_args() -> Result<Config, String> {
    let args: Vec<String> = env::args().collect();
    let self_test = args.iter().any(|arg| arg == "--self-test");
    let once = args.iter().any(|arg| arg == "--once");
    let destination = arg_value(&args, "--destination")
        .or_else(|| env::var("WOW112_TELE11_DESTINATION").ok())
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| if self_test { "winterspring".into() } else { String::new() });
    if destination.is_empty() {
        return Err("missing --destination or WOW112_TELE11_DESTINATION".into());
    }
    let service_dir = env::var("WOW112_TELE11_SERVICE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele11_state").join(&destination));
    let journal_path = env::var("WOW112_TELE11_JOURNAL_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| service_dir.join("service_journal.jsonl"));
    let payment_ledger_path = env::var("WOW112_TELE10_LEDGER_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| service_dir.join("payment_ledger.json"));
    Ok(Config {
        destination,
        service_dir,
        journal_path,
        payment_ledger_path,
        once,
        self_test,
    })
}

fn service_core_config(destination: &str) -> ServiceCoreConfig {
    ServiceCoreConfig {
        schema_version: 1,
        dedup_window_ms: env_u64("WOW112_TELE11_DEDUP_MS", DEFAULT_DEDUP_MS),
        expiry_ms: env_u64("WOW112_TELE11_EXPIRY_MS", DEFAULT_EXPIRY_MS),
        routes: vec![RouteConfig {
            destination: destination.to_string(),
            resource: format!("summon/{destination}"),
        }],
    }
}

fn resource(config: &Config) -> ResourceKey {
    ResourceKey(format!("summon/{}", config.destination))
}

fn write_service_state(config: &Config, state: &str, detail: &str) {
    let safe = detail.replace(['\r', '\n'], " ");
    let temp = config.service_dir.join("SERVICE_STATE.tmp");
    let final_path = config.service_dir.join("SERVICE_STATE.txt");
    let body = format!(
        "state={state}\ndestination={}\ndetail={safe}\ntimestamp_ms={}\n",
        config.destination,
        now_ms()
    );
    if fs::write(&temp, body).is_ok() {
        let _ = fs::rename(temp, final_path);
    }
}

fn sanitize(value: &str) -> String {
    value
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') { ch } else { '_' })
        .collect()
}

fn raw_text_for_request(core: &ServiceCore, request_id: &str) -> String {
    core.journal_entries()
        .iter()
        .rev()
        .find_map(|entry| match &entry.event {
            JournalEvent::RequestAccepted {
                request_id: id,
                raw_text,
                ..
            } if id == request_id => Some(raw_text.clone()),
            _ => None,
        })
        .unwrap_or_else(|| "unknown".into())
}

fn parse_worker_verdict(path: &Path) -> Result<WorkerVerdict, String> {
    let text = fs::read_to_string(path)
        .map_err(|e| format!("read worker verdict {} failed: {e}", path.display()))?;
    let mut code = None;
    let mut detail = String::new();
    let mut replay_allowed = None;
    for line in text.lines() {
        if let Some((key, value)) = line.split_once('=') {
            match key.trim() {
                "result" => code = Some(value.trim().to_string()),
                "detail" => detail = value.trim().to_string(),
                "replay_allowed" => {
                    replay_allowed = Some(value.trim().eq_ignore_ascii_case("true"))
                }
                _ => {}
            }
        }
    }
    Ok(WorkerVerdict {
        code: code.ok_or_else(|| "worker verdict missing result".to_string())?,
        detail,
        replay_allowed: replay_allowed.unwrap_or(false),
    })
}

fn map_worker_outcome(verdict: &WorkerVerdict) -> ExecutorOutcome {
    if verdict.code == "PASS_EXTERNAL_SUMMON_PAYMENT_COMPLETE"
        || verdict.code == "COMPLETE_EXTERNAL_UNPAID_NO_REPLAY"
    {
        return ExecutorOutcome::Pass;
    }
    if verdict.replay_allowed {
        return ExecutorOutcome::SafePreActiveFailure;
    }
    if verdict.code.contains("UNCERTAIN")
        || verdict.code.contains("ACTIVE")
        || verdict.code.contains("STALE")
        || verdict.code.contains("PORTAL_TIMEOUT")
        || verdict.code.contains("PAYMENT_WITHOUT_PORTAL")
    {
        return ExecutorOutcome::Uncertain;
    }
    ExecutorOutcome::TerminalFailure
}

fn run_self_test(config: &Config) -> Result<(), String> {
    service_core_config(&config.destination).validate()?;
    let pass = WorkerVerdict {
        code: "PASS_EXTERNAL_SUMMON_PAYMENT_COMPLETE".into(),
        detail: "paid".into(),
        replay_allowed: false,
    };
    if map_worker_outcome(&pass) != ExecutorOutcome::Pass {
        return Err("paid pass mapping failed".into());
    }
    let unpaid = WorkerVerdict {
        code: "COMPLETE_EXTERNAL_UNPAID_NO_REPLAY".into(),
        detail: "unpaid".into(),
        replay_allowed: false,
    };
    if map_worker_outcome(&unpaid) != ExecutorOutcome::Pass {
        return Err("unpaid completed summon mapping failed".into());
    }
    let safe = WorkerVerdict {
        code: "FAIL_SAFE_PRE_MUTATION_READY".into(),
        detail: "ready".into(),
        replay_allowed: true,
    };
    if map_worker_outcome(&safe) != ExecutorOutcome::SafePreActiveFailure {
        return Err("safe retry mapping failed".into());
    }
    let uncertain = WorkerVerdict {
        code: "FAIL_MUTATION_UNCERTAIN".into(),
        detail: "write".into(),
        replay_allowed: false,
    };
    if map_worker_outcome(&uncertain) != ExecutorOutcome::Uncertain {
        return Err("uncertain mapping failed".into());
    }
    println!("TELE11 SERVICE SELFTEST PASS destination={}", config.destination);
    Ok(())
}

fn spawn_ingress(root: &Path, config: &Config) -> Result<i32, String> {
    let exe = root.join(INGRESS_EXE);
    if !exe.exists() {
        return Err(format!("missing ingress binary: {}", exe.display()));
    }
    let ingress_status = config.service_dir.join("INGRESS_STATE.txt");
    let stdout = fs::File::create(config.service_dir.join("INGRESS.stdout.log"))
        .map_err(|e| e.to_string())?;
    let stderr = fs::File::create(config.service_dir.join("INGRESS.stderr.log"))
        .map_err(|e| e.to_string())?;
    let mut command = Command::new(exe);
    command
        .arg("--destination")
        .arg(&config.destination)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_TELE11_DESTINATION", &config.destination)
        .env("WOW112_TELE11_JOURNAL_PATH", &config.journal_path)
        .env("WOW112_TELE11_INGRESS_STATUS", ingress_status);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let status = command
        .status()
        .map_err(|e| format!("spawn/wait ingress failed: {e}"))?;
    Ok(status.code().unwrap_or(2))
}

fn spawn_worker(
    root: &Path,
    config: &Config,
    customer: &str,
    raw_text: &str,
    job_id: &str,
) -> Result<(i32, PathBuf), String> {
    let exe = root.join(WORKER_EXE);
    if !exe.exists() {
        return Err(format!("missing worker binary: {}", exe.display()));
    }
    let job_dir = config
        .service_dir
        .join("jobs")
        .join(sanitize(job_id));
    fs::create_dir_all(&job_dir).map_err(|e| format!("create job dir failed: {e}"))?;
    let stdout = fs::File::create(job_dir.join("SERVICE_WORKER.stdout.log"))
        .map_err(|e| e.to_string())?;
    let stderr = fs::File::create(job_dir.join("SERVICE_WORKER.stderr.log"))
        .map_err(|e| e.to_string())?;
    let mut command = Command::new(exe);
    command
        .arg("--customer")
        .arg(customer)
        .arg("--destination")
        .arg(&config.destination)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_TELE11_DESTINATION", &config.destination)
        .env("WOW112_TELE11_TRIGGER_MESSAGE", raw_text)
        .env("WOW112_TELE11_RUN_DIR", &job_dir)
        .env("WOW112_TELE10_LEDGER_PATH", &config.payment_ledger_path);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let status = command
        .status()
        .map_err(|e| format!("spawn/wait worker failed: {e}"))?;
    Ok((status.code().unwrap_or(3), job_dir.join("WORKER_VERDICT.txt")))
}

fn open_core(config: &Config) -> Result<ServiceCore, String> {
    let (core, recovered) = ServiceCore::create_or_open(
        &config.journal_path,
        service_core_config(&config.destination),
        now_ms(),
    )?;
    if !recovered.is_empty() {
        return Err(format!(
            "BLOCKED_RECONCILIATION recovered_jobs={} first={:?}",
            recovered.len(),
            recovered.first()
        ));
    }
    Ok(core)
}

fn run_service(config: &Config) -> Result<i32, String> {
    fs::create_dir_all(config.service_dir.join("jobs"))
        .map_err(|e| format!("create service dir failed: {e}"))?;
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    let root = exe
        .parent()
        .ok_or_else(|| "service executable has no parent".to_string())?
        .to_path_buf();
    for file in [INGRESS_EXE, WORKER_EXE] {
        if !root.join(file).exists() {
            return Err(format!("missing required sibling binary: {file}"));
        }
    }
    write_service_state(config, "BOOTING", "opening durable service core");

    loop {
        let mut core = match open_core(config) {
            Ok(value) => value,
            Err(error) => {
                write_service_state(config, "BLOCKED_RECONCILIATION", &error);
                return Ok(3);
            }
        };
        let resource = resource(config);
        if core.queue().next_eligible_request(&resource).is_none() {
            write_service_state(config, "LISTENING", "starting one-shot ingress owner session");
            let ingress_rc = spawn_ingress(&root, config)?;
            thread::sleep(Duration::from_millis(500));
            core = match open_core(config) {
                Ok(value) => value,
                Err(error) => {
                    write_service_state(config, "BLOCKED_RECONCILIATION", &error);
                    return Ok(3);
                }
            };
            if core.queue().next_eligible_request(&resource).is_none() {
                if config.once {
                    write_service_state(
                        config,
                        "NO_JOB",
                        &format!("ingress exited rc={ingress_rc} without durable queued request"),
                    );
                    return Ok(if ingress_rc == 0 { 0 } else { 2 });
                }
                write_service_state(
                    config,
                    "RECONNECTING",
                    &format!("ingress exited rc={ingress_rc} without job; retrying"),
                );
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        }

        let activation = core.activate_next(&resource, now_ms())?;
        let job = activation.job;
        let request = core
            .queue()
            .request(&job.request_id)
            .ok_or_else(|| format!("activated request missing: {}", job.request_id))?
            .request
            .clone();
        let raw_text = raw_text_for_request(&core, &job.request_id);
        write_service_state(
            config,
            "EXECUTING",
            &format!(
                "job={} request={} player={} destination={}",
                job.job_id, job.request_id, request.player, request.destination
            ),
        );

        let worker_result = spawn_worker(
            &root,
            config,
            &request.player,
            &raw_text,
            &job.job_id,
        );
        let verdict = match worker_result {
            Ok((rc, verdict_path)) => match parse_worker_verdict(&verdict_path) {
                Ok(value) => value,
                Err(error) => WorkerVerdict {
                    code: "FAIL_ACTIVE_WORKER_VERDICT_MISSING".into(),
                    detail: format!("worker_rc={rc}; {error}"),
                    replay_allowed: false,
                },
            },
            Err(error) => WorkerVerdict {
                code: "FAIL_ACTIVE_WORKER_SPAWN_UNCERTAIN".into(),
                detail: error,
                replay_allowed: false,
            },
        };
        let outcome = map_worker_outcome(&verdict);
        core.settle_job(
            &job.job_id,
            outcome,
            now_ms(),
            format!("{}: {}", verdict.code, verdict.detail),
        )?;
        write_service_state(
            config,
            if outcome == ExecutorOutcome::Pass {
                "SETTLED"
            } else if outcome == ExecutorOutcome::SafePreActiveFailure {
                "REQUEUED_SAFE"
            } else if outcome == ExecutorOutcome::Uncertain {
                "BLOCKED_RECONCILIATION"
            } else {
                "FAILED_TERMINAL"
            },
            &format!("job={} verdict={} detail={}", job.job_id, verdict.code, verdict.detail),
        );

        if outcome == ExecutorOutcome::Uncertain {
            return Ok(3);
        }
        if config.once {
            return Ok(0);
        }
        thread::sleep(Duration::from_millis(500));
    }
}

fn main() {
    let config = match config_from_args() {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[TELE11-SERVICE] CONFIG ERROR: {error}");
            std::process::exit(2);
        }
    };
    if config.self_test {
        if let Err(error) = run_self_test(&config) {
            eprintln!("[TELE11-SERVICE] SELFTEST ERROR: {error}");
            std::process::exit(2);
        }
        return;
    }
    match run_service(&config) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            write_service_state(&config, "ERROR", &error);
            eprintln!("[TELE11-SERVICE] ERROR: {error}");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdict_mapping_is_fail_closed() {
        assert_eq!(
            map_worker_outcome(&WorkerVerdict {
                code: "FAIL_ACTIVE_ROLE_EXITED".into(),
                detail: String::new(),
                replay_allowed: false,
            }),
            ExecutorOutcome::Uncertain
        );
        assert_eq!(
            map_worker_outcome(&WorkerVerdict {
                code: "FAIL_SAFE_PRE_MUTATION_TIMEOUT".into(),
                detail: String::new(),
                replay_allowed: true,
            }),
            ExecutorOutcome::SafePreActiveFailure
        );
    }
}
