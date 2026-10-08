use std::env;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use wow112_headless_android_probe::summon_service_history::{history_for_client, payment_status_label};
use wow112_headless_android_probe::tele10_trade_payment::LedgerStore;

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn usage() -> &'static str {
    "usage: summon_service_report [--ledger PATH] [--client NAME] [--since-seconds N]"
}

fn run() -> Result<(), String> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    let mut ledger_path = env::var("WOW112_TELE10_LEDGER_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele10_payment_ledger.json"));
    let mut client: Option<String> = None;
    let mut since_seconds: Option<i64> = None;
    let mut index = 0usize;
    while index < args.len() {
        match args[index].as_str() {
            "--ledger" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| usage().to_string())?;
                ledger_path = PathBuf::from(value);
            }
            "--client" => {
                index += 1;
                client = Some(args.get(index).ok_or_else(|| usage().to_string())?.clone());
            }
            "--since-seconds" => {
                index += 1;
                let raw = args.get(index).ok_or_else(|| usage().to_string())?;
                let value = raw
                    .parse::<i64>()
                    .map_err(|e| format!("invalid --since-seconds {raw:?}: {e}"))?;
                if value < 0 {
                    return Err("--since-seconds must be >= 0".to_string());
                }
                since_seconds = Some(value);
            }
            "-h" | "--help" => {
                println!("{}", usage());
                return Ok(());
            }
            other => return Err(format!("unknown argument {other:?}; {}", usage())),
        }
        index += 1;
    }

    let ledger = LedgerStore::open(&ledger_path)?;
    let since_unix = since_seconds.map(|seconds| unix_now().saturating_sub(seconds));
    let rows = history_for_client(&ledger.state, client.as_deref(), since_unix);

    println!(
        "SUMMON_REPORT ledger={} client={} since_unix={} rows={}",
        ledger_path.display(),
        client.as_deref().unwrap_or("*"),
        since_unix.map(|v| v.to_string()).unwrap_or_else(|| "*".to_string()),
        rows.len()
    );
    for row in rows {
        println!(
            "SUMMON_HISTORY summon_id={} client={} summoner={} destination={} created={} payment_status={} expected_copper={} paid_copper={} payment_timestamp={} settlement_id={}",
            row.summon_id,
            row.client_name,
            row.summoner_name,
            row.destination,
            row.timestamp_created,
            payment_status_label(row.payment_status),
            row.expected_price_copper,
            row.amount_paid_copper,
            row.payment_timestamp.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string()),
            row.settlement_id.as_deref().unwrap_or("-"),
        );
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("SUMMON_REPORT_FAIL {error}");
        std::process::exit(2);
    }
}
