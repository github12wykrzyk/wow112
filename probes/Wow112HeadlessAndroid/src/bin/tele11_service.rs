use std::env;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use tele08_request_queue::ResourceKey;
use wow112_headless_android_probe::tele11_executor_contract::ExecutorVerdictClass;
use wow112_headless_android_probe::tele11_executor_runtime::run_external_executor;
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

    let result = run_external_executor(exec);
    let (outcome, detail) = match result {
        Ok(0) => (ExecutorOutcome::Pass, "executor PASS_SUMMON_OFFERED".to_string()),
        Ok(2) => (
            ExecutorOutcome::SafePreActiveFailure,
            "executor failed before summoner activation; safe requeue".to_string(),
        ),
        Ok(3) => (
            ExecutorOutcome::Uncertain,
            "executor active outcome uncertain; automatic replay forbidden".to_string(),
        ),
        Ok(code) => (
            ExecutorOutcome::Uncertain,
            format!("executor unexpected exit code={code}; conservative no-replay"),
        ),
        Err(error) => (
            ExecutorOutcome::Uncertain,
            format!("executor returned error after durable activation: {error}; conservative no-replay"),
        ),
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
    let _ = ExecutorVerdictClass::Pass;
    let text = usage();
    for required in ["status", "enqueue", "run-once", "ledger", "payment-observed", "payment-settled"] {
        if !text.contains(required) {
            return Err(format!("usage missing command {required}"));
        }
    }
    println!("TELE11_SERVICE_SELFTEST_PASS");
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
