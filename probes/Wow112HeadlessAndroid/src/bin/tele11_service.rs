use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use tele08_request_queue::ResourceKey;
use wow112_headless_android_probe::tele11_executor_process::ExternalExecutorConfig;
use wow112_headless_android_probe::tele11_process_containment::KillOnCloseJob;
use wow112_headless_android_probe::tele11_service_config::ServiceFileConfig;
use wow112_headless_android_probe::tele11_service_core::{ExecutorOutcome, ServiceCore};

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE11-SERVICE] ERROR: {error}");
        std::process::exit(2);
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
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

fn arg_after(args: &[String], name: &str) -> Result<String, String> {
    let index = args
        .iter()
        .position(|arg| arg == name)
        .ok_or_else(|| format!("missing {name}"))?;
    args.get(index + 1)
        .cloned()
        .ok_or_else(|| format!("{name} requires a value"))
}

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    if args.iter().any(|arg| arg == "--self-test") {
        return self_test();
    }
    let command = args
        .get(1)
        .ok_or_else(|| usage().to_string())?
        .to_ascii_lowercase();
    if command == "help" || command == "--help" || command == "-h" {
        println!("{}", usage());
        return Ok(());
    }

    let config = ServiceFileConfig::load(&config_path(&args)?)?;
    let (mut core, recovery) =
        ServiceCore::create_or_open(config.journal_path(), config.core_config()?, now_ms())?;
    if !recovery.is_empty() {
        eprintln!(
            "[TELE11-SERVICE] RECOVERY_BLOCK count={} jobs={:?}",
            recovery.len(), recovery
        );
    }

    match command.as_str() {
        "status" => print_status(&core),
        "ledger" => print_ledger(&core),
        "enqueue" => {
            let player = arg_after(&args, "--player")?;
            let destination = arg_after(&args, "--destination")?.to_ascii_lowercase();
            let raw = args
                .iter()
                .position(|arg| arg == "--raw")
                .and_then(|index| args.get(index + 1))
                .cloned()
                .unwrap_or_else(|| destination.clone());
            let request_id = args
                .iter()
                .position(|arg| arg == "--request-id")
                .and_then(|index| args.get(index + 1))
                .cloned()
                .unwrap_or_else(|| format!("tele11:{}:{}", now_ms(), player.to_ascii_lowercase()));
            let events = core.enqueue_request(
                request_id.clone(),
                player.clone(),
                destination.clone(),
                raw,
                now_ms(),
            )?;
            println!(
                "ENQUEUE request_id={} player={} destination={} events={:?}",
                request_id, player, destination, events
            );
        }
        "run-once" => {
            let resource = arg_after(&args, "--resource")?;
            run_one(&config, &mut core, &resource)?;
        }
        "payment-observed" | "payment-settled" => {
            let request_id = arg_after(&args, "--request-id")?;
            let payer = arg_after(&args, "--payer")?;
            let amount = arg_after(&args, "--copper")?
                .parse::<u64>()
                .map_err(|error| format!("invalid --copper: {error}"))?;
            if command == "payment-observed" {
                core.record_payment_observed(&request_id, &payer, amount, now_ms())?;
            } else {
                core.record_payment_settled(&request_id, &payer, amount, now_ms())?;
            }
            println!(
                "PAYMENT event={} request_id={} payer={} copper={}",
                command, request_id, payer, amount
            );
        }
        _ => return Err(usage().to_string()),
    }
    Ok(())
}

#[derive(Debug)]
enum ChildRun {
    Exit(i32),
    SafePreActive(String),
    Uncertain(String),
}

fn run_executor_process(exec: &ExternalExecutorConfig) -> ChildRun {
    if let Err(error) = fs::create_dir_all(&exec.run_dir) {
        return ChildRun::SafePreActive(format!(
            "create executor run dir {} failed before spawn: {error}",
            exec.run_dir.display()
        ));
    }
    let gate = exec.run_dir.join("START.GATE");
    let _ = fs::remove_file(&gate);

    let current = match env::current_exe() {
        Ok(value) => value,
        Err(error) => {
            return ChildRun::SafePreActive(format!(
                "resolve service executable failed before spawn: {error}"
            ))
        }
    };
    let executor = match current.parent() {
        Some(parent) => parent.join("tele11_external_executor.exe"),
        None => {
            return ChildRun::SafePreActive(
                "service executable has no parent directory".to_string(),
            )
        }
    };
    if !executor.exists() {
        return ChildRun::SafePreActive(format!(
            "executor binary missing before spawn: {}",
            executor.display()
        ));
    }

    let containment = match KillOnCloseJob::new() {
        Ok(job) => job,
        Err(error) => {
            return ChildRun::SafePreActive(format!(
                "kill-on-close containment initialization failed before spawn: {error}"
            ))
        }
    };

    let mut command = Command::new(&executor);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .env("WOW112_PASSWORD", &exec.password)
        .env("WOW112_REALM_INDEX", exec.realm_index.to_string())
        .env("WOW112_TELE11_RUN_DIR", &exec.run_dir)
        .env("WOW112_TELE11_CUSTOMER_CHARACTER", &exec.customer)
        .env("WOW112_TELE11_DESTINATION", &exec.destination)
        .env("WOW112_TELE11_RESOURCE", &exec.resource)
        .env("WOW112_TELE11_SUMMONER_ACCOUNT", &exec.summoner.account)
        .env("WOW112_TELE11_SUMMONER_CHARACTER", &exec.summoner.character)
        .env("WOW112_TELE11_CLICKER1_ACCOUNT", &exec.clicker1.account)
        .env("WOW112_TELE11_CLICKER1_CHARACTER", &exec.clicker1.character)
        .env("WOW112_TELE11_CLICKER2_ACCOUNT", &exec.clicker2.account)
        .env("WOW112_TELE11_CLICKER2_CHARACTER", &exec.clicker2.character)
        .env(
            "WOW112_TELE11_READY_TIMEOUT_SECS",
            exec.ready_timeout.as_secs().to_string(),
        )
        .env(
            "WOW112_TELE11_ACTIVE_TIMEOUT_SECS",
            exec.active_timeout.as_secs().to_string(),
        )
        .env(
            "WOW112_TELE11_OFFER_SETTLE_MS",
            exec.offer_settle.as_millis().to_string(),
        )
        .env("WOW112_TELE11_START_GATE", &gate)
        .env("WOW112_TELE11_START_GATE_TIMEOUT_MS", "30000");

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return ChildRun::SafePreActive(format!(
                "executor spawn failed before start gate: {error}"
            ))
        }
    };
    if let Err(error) = containment.assign_child(&child) {
        let _ = child.kill();
        let _ = child.wait();
        return ChildRun::SafePreActive(format!(
            "executor containment assignment failed while start gate closed: {error}"
        ));
    }
    if let Err(error) = fs::write(&gate, b"contained\n") {
        let _ = child.kill();
        let _ = child.wait();
        return ChildRun::SafePreActive(format!(
            "publish executor start gate failed; roles never authorized: {error}"
        ));
    }
    println!(
        "CONTAINMENT PASS executor_pid={} gate={} kill_on_job_close=true",
        child.id(),
        gate.display()
    );

    let result = match child.wait() {
        Ok(status) => ChildRun::Exit(status.code().unwrap_or(3)),
        Err(error) => ChildRun::Uncertain(format!(
            "executor wait failed after start gate; containment will terminate tree: {error}"
        )),
    };
    let _ = fs::remove_file(&gate);
    drop(containment);
    result
}

fn run_one(
    config: &ServiceFileConfig,
    core: &mut ServiceCore,
    resource: &str,
) -> Result<(), String> {
    let team = config
        .team_for_resource(resource)
        .ok_or_else(|| format!("no enabled TELE11 team for resource {resource}"))?;
    let activation = core.activate_next(&ResourceKey(resource.to_string()), now_ms())?;
    let request = core
        .queue()
        .request(&activation.job.request_id)
        .cloned()
        .ok_or_else(|| format!("activated request missing: {}", activation.job.request_id))?;
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD for executor".to_string())?;
    let exec = config.executor_config(
        team,
        &request.request.player,
        &password,
        &activation.job.job_id,
    );

    println!(
        "ACTIVATE job_id={} request_id={} player={} destination={} resource={}",
        activation.job.job_id,
        activation.job.request_id,
        request.request.player,
        request.request.destination,
        activation.job.resource.0
    );

    let (outcome, detail) = match run_executor_process(&exec) {
        ChildRun::Exit(0) => (
            ExecutorOutcome::Pass,
            "contained executor PASS_SUMMON_OFFERED".to_string(),
        ),
        ChildRun::Exit(2) => (
            ExecutorOutcome::SafePreActiveFailure,
            "contained executor failed before summoner activation; safe requeue".to_string(),
        ),
        ChildRun::Exit(3) => (
            ExecutorOutcome::Uncertain,
            "contained executor active outcome uncertain; automatic replay forbidden".to_string(),
        ),
        ChildRun::Exit(code) => (
            ExecutorOutcome::Uncertain,
            format!("contained executor unexpected exit code={code}; conservative no-replay"),
        ),
        ChildRun::SafePreActive(error) => (ExecutorOutcome::SafePreActiveFailure, error),
        ChildRun::Uncertain(error) => (ExecutorOutcome::Uncertain, error),
    };
    let events = core.settle_job(&activation.job.job_id, outcome, now_ms(), detail.clone())?;
    println!(
        "SETTLE job_id={} outcome={:?} detail={} events={:?}",
        activation.job.job_id, outcome, detail, events
    );
    Ok(())
}

fn print_status(core: &ServiceCore) {
    println!("TELE11 STATUS");
    println!("journal_entries={}", core.journal_entries().len());
    println!("active_jobs={}", core.active_jobs().len());
    for route in &core.config().routes {
        println!(
            "destination={} resource={} queued={}",
            route.destination,
            route.resource,
            core.queue().queued_count_by_destination(&route.destination)
        );
    }
}

fn print_ledger(core: &ServiceCore) {
    for row in core.ledger() {
        println!(
            "request_id={} player={} destination={} summon_state={} payment_observed={} payment_settled={} job_id={}",
            row.request_id,
            row.player,
            row.destination,
            row.summon_state,
            row.payment_observed_copper,
            row.payment_settled_copper,
            row.job_id.as_deref().unwrap_or("-")
        );
    }
}

fn self_test() -> Result<(), String> {
    let _job = KillOnCloseJob::new()?;
    let text = usage();
    for required in [
        "status",
        "enqueue",
        "run-once",
        "ledger",
        "payment-observed",
        "payment-settled",
    ] {
        if !text.contains(required) {
            return Err(format!("usage missing command {required}"));
        }
    }
    println!("TELE11_SERVICE_SELFTEST_PASS containment=kill_on_job_close");
    Ok(())
}

fn usage() -> &'static str {
    "TELE11 service\n\
usage:\n\
  tele11_service status --config <path>\n\
  tele11_service enqueue --config <path> --player <name> --destination <id> [--raw <text>] [--request-id <id>]\n\
  tele11_service run-once --config <path> --resource <resource-key>\n\
  tele11_service ledger --config <path>\n\
  tele11_service payment-observed --config <path> --request-id <id> --payer <name> --copper <n>\n\
  tele11_service payment-settled --config <path> --request-id <id> --payer <name> --copper <n>"
}
