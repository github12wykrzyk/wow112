use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use wow112_headless_android_probe::tele11_executor_contract::{
    classify_external_executor, ExecutorRuntimeState, ExecutorVerdictClass,
};
use wow112_headless_android_probe::tele11_executor_process::ExternalExecutorConfig;
use wow112_headless_android_probe::tele11_executor_runtime::run_external_executor;

fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    if args.iter().any(|arg| arg == "--self-test") {
        if let Err(error) = self_test() {
            eprintln!("[TELE11-EXTERNAL] SELFTEST ERROR: {error}");
            std::process::exit(2);
        }
        return;
    }

    if let Err(error) = wait_for_start_gate() {
        eprintln!("[TELE11-EXTERNAL] START GATE ERROR: {error}");
        std::process::exit(2);
    }

    let config = match ExternalExecutorConfig::from_env() {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[TELE11-EXTERNAL] CONFIG ERROR: {error}");
            std::process::exit(2);
        }
    };
    match run_external_executor(config) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("[TELE11-EXTERNAL] ERROR: {error}");
            std::process::exit(2);
        }
    }
}

fn wait_for_start_gate() -> Result<(), String> {
    let Ok(path) = std::env::var("WOW112_TELE11_START_GATE") else {
        return Ok(());
    };
    if path.trim().is_empty() {
        return Ok(());
    }
    let timeout_ms = std::env::var("WOW112_TELE11_START_GATE_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(30_000)
        .max(1_000);
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let gate = Path::new(&path);
    println!(
        "[TELE11-EXTERNAL] waiting containment start gate={} timeout_ms={timeout_ms}",
        gate.display()
    );
    loop {
        if gate.exists() {
            println!("[TELE11-EXTERNAL] containment start gate PASS");
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "containment start gate timeout path={} role processes were never spawned",
                gate.display()
            ));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn self_test() -> Result<(), String> {
    let config = ExternalExecutorConfig::self_test();
    if config.customer != "Customer"
        || config.summoner.character != "Summoner"
        || config.clicker1.character != "Clickone"
        || config.clicker2.character != "Clicktwo"
    {
        return Err("executor self-test config mismatch".to_string());
    }
    let state = |name: &str| ExecutorRuntimeState {
        state: name.to_string(),
        session: 1,
        detail: String::new(),
    };
    let verdict = classify_external_executor(
        &state("PASS_RITUAL_STARTED"),
        &state("PORTAL_USE_SENT"),
        &state("PORTAL_USE_SENT"),
        true,
        true,
        false,
        false,
        false,
    )
    .ok_or_else(|| "executor self-test produced no verdict".to_string())?;
    if verdict.class != ExecutorVerdictClass::Pass || verdict.code != "PASS_SUMMON_OFFERED" {
        return Err(format!("executor self-test wrong verdict: {verdict:?}"));
    }
    println!("TELE11_EXTERNAL_EXECUTOR_SELFTEST_PASS");
    Ok(())
}
