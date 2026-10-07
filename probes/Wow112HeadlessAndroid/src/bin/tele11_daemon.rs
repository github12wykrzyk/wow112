use std::env;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tele08_request_queue::{QueueEvent, ResourceKey};
use wow112_headless_android_probe::tele11_executor_launch::{
    run_contained_executor, ContainedExecutorResult,
};
use wow112_headless_android_probe::tele11_ingress::{
    archive_spool_event, list_spool_events, read_spool_event,
};
use wow112_headless_android_probe::tele11_process_containment::KillOnCloseJob;
use wow112_headless_android_probe::tele11_service_config::{ListenerConfig, ServiceFileConfig};
use wow112_headless_android_probe::tele11_service_core::{ExecutorOutcome, ServiceCore};

const POLL_MS: u64 = 250;
const LISTENER_RESTART_BACKOFF_MS: u64 = 2_000;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE11-DAEMON] FATAL: {error}");
        std::process::exit(2);
    }
}

fn config_path(args: &[String]) -> Result<PathBuf, String> {
    if let Some(index) = args.iter().position(|arg| arg == "--config") {
        return args
            .get(index + 1)
            .map(PathBuf::from)
            .ok_or_else(|| "--config requires a path".to_string());
    }
    env::var("WOW112_TELE11_CONFIG")
        .map(PathBuf::from)
        .map_err(|_| "missing --config or WOW112_TELE11_CONFIG".to_string())
}

struct ManagedListener {
    child: Child,
    _containment: KillOnCloseJob,
    started_at: Instant,
}

fn spawn_listener(
    config_path: &Path,
    listener: &ListenerConfig,
    password: &str,
) -> Result<ManagedListener, String> {
    let current = env::current_exe().map_err(|error| format!("current_exe failed: {error}"))?;
    let listener_exe = current
        .parent()
        .ok_or_else(|| "daemon executable has no parent directory".to_string())?
        .join("tele11_listener.exe");
    if !listener_exe.exists() {
        return Err(format!("listener binary missing: {}", listener_exe.display()));
    }
    let containment = KillOnCloseJob::new()?;
    let mut command = Command::new(&listener_exe);
    command
        .arg("--config")
        .arg(config_path)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .env("WOW112_PASSWORD", password);
    let mut child = command
        .spawn()
        .map_err(|error| format!("spawn TELE11 listener failed: {error}"))?;
    if let Err(error) = containment.assign_child(&child) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("contain listener pid failed: {error}"));
    }
    println!(
        "[TELE11-DAEMON] LISTENER START pid={} character={} inbox={} contained=true",
        child.id(), listener.character, listener.inbox_dir
    );
    Ok(ManagedListener {
        child,
        _containment: containment,
        started_at: Instant::now(),
    })
}

fn ensure_listener(
    slot: &mut Option<ManagedListener>,
    config_path: &Path,
    listener: &ListenerConfig,
    password: &str,
    last_restart: &mut Option<Instant>,
) -> Result<(), String> {
    let exited = match slot.as_mut() {
        Some(managed) => match managed.child.try_wait() {
            Ok(Some(status)) => {
                eprintln!(
                    "[TELE11-DAEMON] LISTENER EXIT status={status} uptime_ms={}",
                    managed.started_at.elapsed().as_millis()
                );
                true
            }
            Ok(None) => false,
            Err(error) => {
                eprintln!("[TELE11-DAEMON] LISTENER status error={error}");
                true
            }
        },
        None => true,
    };
    if !exited {
        return Ok(());
    }
    *slot = None;
    if last_restart
        .map(|instant| instant.elapsed() < Duration::from_millis(LISTENER_RESTART_BACKOFF_MS))
        .unwrap_or(false)
    {
        return Ok(());
    }
    let managed = spawn_listener(config_path, listener, password)?;
    *last_restart = Some(Instant::now());
    *slot = Some(managed);
    Ok(())
}

fn import_inbox(core: &mut ServiceCore, listener: &ListenerConfig) -> Result<usize, String> {
    let inbox = Path::new(&listener.inbox_dir);
    let archive_root = inbox
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("ingress_archive");
    let mut imported = 0usize;
    for path in list_spool_events(inbox)? {
        let event = match read_spool_event(&path) {
            Ok(event) => event,
            Err(error) => {
                eprintln!(
                    "[TELE11-DAEMON] INGRESS DEADLETTER path={} error={error}",
                    path.display()
                );
                archive_spool_event(&path, &archive_root, "deadletter")?;
                continue;
            }
        };
        let events = core.enqueue_request(
            event.request_id.clone(),
            event.sender.clone(),
            event.destination.clone(),
            event.raw_text.clone(),
            event.at_ms,
        )?;
        let rejected = events
            .iter()
            .any(|queue_event| matches!(queue_event, QueueEvent::RequestRejected { .. }));
        let duplicate = events
            .iter()
            .any(|queue_event| matches!(queue_event, QueueEvent::DuplicateSuppressed { .. }));
        let bucket = if rejected { "rejected" } else { "processed" };
        archive_spool_event(&path, &archive_root, bucket)?;
        println!(
            "[TELE11-DAEMON] INGRESS IMPORT request_id={} sender={} destination={} rejected={} duplicate={} events={:?}",
            event.request_id,
            event.sender,
            event.destination,
            rejected,
            duplicate,
            events
        );
        imported += 1;
    }
    Ok(imported)
}

fn dispatch_one(
    config: &ServiceFileConfig,
    core: &mut ServiceCore,
    password: &str,
) -> Result<bool, String> {
    let routes = core.config().routes.clone();
    for route in routes {
        let resource = ResourceKey(route.resource.clone());
        if core.queue().active_job_by_resource(&resource).is_some() {
            continue;
        }
        if core.queue().next_eligible_request(&resource).is_none() {
            continue;
        }
        let team = config
            .team_for_resource(&route.resource)
            .ok_or_else(|| format!("enabled resource has no team config: {}", route.resource))?;
        let activation = core.activate_next(&resource, now_ms())?;
        let record = core
            .queue()
            .request(&activation.job.request_id)
            .cloned()
            .ok_or_else(|| format!("activated request missing: {}", activation.job.request_id))?;
        let executor = config.executor_config(
            team,
            &record.request.player,
            password,
            &activation.job.job_id,
        );
        println!(
            "[TELE11-DAEMON] DISPATCH job_id={} request_id={} player={} destination={} resource={}",
            activation.job.job_id,
            activation.job.request_id,
            record.request.player,
            record.request.destination,
            activation.job.resource.0
        );

        let (outcome, detail) = match run_contained_executor(&executor) {
            ContainedExecutorResult::Exit(0) => (
                ExecutorOutcome::Pass,
                "PASS_SUMMON_OFFERED: ritual started and both controlled clicks sent".to_string(),
            ),
            ContainedExecutorResult::Exit(2) => (
                ExecutorOutcome::SafePreActiveFailure,
                "executor failed before active mutation; safe requeue".to_string(),
            ),
            ContainedExecutorResult::Exit(3) => (
                ExecutorOutcome::Uncertain,
                "executor active outcome uncertain; automatic replay forbidden".to_string(),
            ),
            ContainedExecutorResult::Exit(code) => (
                ExecutorOutcome::Uncertain,
                format!("unexpected executor exit={code}; conservative no-replay"),
            ),
            ContainedExecutorResult::SafePreActive(error) => {
                (ExecutorOutcome::SafePreActiveFailure, error)
            }
            ContainedExecutorResult::Uncertain(error) => (ExecutorOutcome::Uncertain, error),
        };
        let events = core.settle_job(
            &activation.job.job_id,
            outcome,
            now_ms(),
            detail.clone(),
        )?;
        println!(
            "[TELE11-DAEMON] SETTLE job_id={} outcome={:?} detail={} events={:?}",
            activation.job.job_id, outcome, detail, events
        );
        return Ok(true);
    }
    Ok(false)
}

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    if args.iter().any(|arg| arg == "--self-test") {
        println!("TELE11_DAEMON_SELFTEST_PASS");
        return Ok(());
    }
    let path = config_path(&args)?;
    let config = ServiceFileConfig::load(&path)?;
    let listener_config = config.listener()?.clone();
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let (mut core, recovery) =
        ServiceCore::create_or_open(config.journal_path(), config.core_config()?, now_ms())?;
    if !recovery.is_empty() {
        eprintln!(
            "[TELE11-DAEMON] RECOVERY BLOCK count={} jobs={:?}",
            recovery.len(), recovery
        );
    }

    println!(
        "[TELE11-DAEMON] START journal={} run_root={} listener={} destinations={} poll_ms={}",
        config.journal_path,
        config.run_root,
        listener_config.character,
        config.teams.iter().filter(|team| team.enabled).count(),
        POLL_MS
    );
    let mut listener: Option<ManagedListener> = None;
    let mut last_listener_restart: Option<Instant> = None;

    loop {
        ensure_listener(
            &mut listener,
            &path,
            &listener_config,
            &password,
            &mut last_listener_restart,
        )?;
        let imported = import_inbox(&mut core, &listener_config)?;
        let dispatched = dispatch_one(&config, &mut core, &password)?;
        if imported == 0 && !dispatched {
            thread::sleep(Duration::from_millis(POLL_MS));
        }
    }
}
