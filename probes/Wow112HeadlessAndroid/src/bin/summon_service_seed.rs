use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use wow112_headless_android_probe::summon_service_core::{OperatorCommand, StructuredEvent};
use wow112_headless_android_probe::summon_service_runtime::{
    ServiceRuntimeConfig, SummonServiceRuntime,
};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn value(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing {name}"))
}

fn run() -> Result<(), String> {
    let root = PathBuf::from(value("WOW112_SUMMON_SERVICE_ROOT")?);
    let customer = value("WOW112_SUMMON_SEED_CUSTOMER")?;
    let destination = value("WOW112_SUMMON_SEED_DESTINATION")?.to_ascii_lowercase();
    let text = env::var("WOW112_SUMMON_SEED_TEXT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("{destination} pls"));
    let session_id = env::var("WOW112_SUMMON_SEED_SESSION_ID")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("seed-{}", now_ms()));

    let mut config = ServiceRuntimeConfig::new(&root, session_id);
    if !config.destinations.iter().any(|item| item == &destination) {
        config.destinations.push(destination.clone());
    }
    let events_path = config.events_path.clone();
    let mut runtime = SummonServiceRuntime::open(config, now_ms())?;
    runtime.operator(OperatorCommand::ManualWhisper {
        customer: customer.clone(),
        text: text.clone(),
        destination_context: Some(destination.clone()),
        now_ms: now_ms(),
    })?;

    let raw = fs::read_to_string(&events_path)
        .map_err(|error| format!("read durable events {} failed: {error}", events_path.display()))?;
    let request = raw
        .lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<StructuredEvent>(line).ok())
        .find(|event| {
            event.event_type == "RequestQueued"
                && event.customer.eq_ignore_ascii_case(&customer)
                && event.destination.eq_ignore_ascii_case(&destination)
        })
        .map(|event| event.request_id)
        .ok_or_else(|| "manual seed did not persist RequestQueued".to_string())?;
    println!(
        "SUMMON_SERVICE_SEED_PASS request_id={} customer={} destination={} text={:?} root={}",
        request,
        customer,
        destination,
        text,
        root.display()
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("SUMMON_SERVICE_SEED_FAIL {error}");
        std::process::exit(2);
    }
}
