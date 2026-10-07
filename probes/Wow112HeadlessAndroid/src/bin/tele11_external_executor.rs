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
