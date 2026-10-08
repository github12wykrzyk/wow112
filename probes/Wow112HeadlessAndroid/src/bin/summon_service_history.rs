use std::env;

use wow112_headless_android_probe::summon_service_history::{history_for_client, payment_status_label};
use wow112_headless_android_probe::tele10_trade_payment::{unix_now, LedgerStore, PaymentStatus};

#[derive(Debug, Default)]
struct Args {
    ledger_path: String,
    client: Option<String>,
    hours: Option<i64>,
    status: Option<String>,
    limit: usize,
}

fn usage() -> &'static str {
    "usage: summon_service_history <ledger.json> [--client NAME] [--hours N] [--status paid|unpaid|partial|overpaid|cancelled|uncertain] [--limit N]"
}

fn parse_args() -> Result<Args, String> {
    let raw = env::args().skip(1).collect::<Vec<_>>();
    if raw.is_empty() {
        return Err(usage().to_string());
    }
    let mut out = Args {
        ledger_path: raw[0].clone(),
        limit: 50,
        ..Args::default()
    };
    let mut i = 1usize;
    while i < raw.len() {
        match raw[i].as_str() {
            "--client" => {
                i += 1;
                out.client = Some(raw.get(i).ok_or_else(|| "missing --client value".to_string())?.clone());
            }
            "--hours" => {
                i += 1;
                let value = raw.get(i).ok_or_else(|| "missing --hours value".to_string())?;
                let parsed = value.parse::<i64>().map_err(|e| format!("invalid --hours={value:?}: {e}"))?;
                if parsed <= 0 || parsed > 24 * 365 {
                    return Err("--hours must be within 1..8760".to_string());
                }
                out.hours = Some(parsed);
            }
            "--status" => {
                i += 1;
                out.status = Some(raw.get(i).ok_or_else(|| "missing --status value".to_string())?.to_ascii_lowercase());
            }
            "--limit" => {
                i += 1;
                let value = raw.get(i).ok_or_else(|| "missing --limit value".to_string())?;
                let parsed = value.parse::<usize>().map_err(|e| format!("invalid --limit={value:?}: {e}"))?;
                out.limit = parsed.clamp(1, 10_000);
            }
            other => return Err(format!("unknown argument {other:?}; {}", usage())),
        }
        i += 1;
    }
    Ok(out)
}

fn status_matches(status: PaymentStatus, wanted: Option<&str>) -> bool {
    match wanted {
        None => true,
        Some("paid") => status == PaymentStatus::Paid,
        Some("unpaid") => status == PaymentStatus::Unpaid,
        Some("partial") => status == PaymentStatus::Partial,
        Some("overpaid") => status == PaymentStatus::Overpaid,
        Some("cancelled") => status == PaymentStatus::Cancelled,
        Some("uncertain") => status == PaymentStatus::Uncertain,
        Some(_) => false,
    }
}

fn copper(value: u64) -> String {
    let gold = value / 10_000;
    let silver = (value % 10_000) / 100;
    let copper = value % 100;
    format!("{gold}g {silver:02}s {copper:02}c")
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    if let Some(status) = args.status.as_deref() {
        if !matches!(status, "paid" | "unpaid" | "partial" | "overpaid" | "cancelled" | "uncertain") {
            return Err(format!("invalid --status={status:?}; {}", usage()));
        }
    }

    let ledger = LedgerStore::open(&args.ledger_path)?;
    let since = args.hours.map(|hours| unix_now().saturating_sub(hours.saturating_mul(3600)));
    let rows = history_for_client(&ledger.state, args.client.as_deref(), since)
        .into_iter()
        .filter(|row| status_matches(row.payment_status, args.status.as_deref()))
        .take(args.limit)
        .collect::<Vec<_>>();

    println!(
        "SUMMON_HISTORY ledger={} rows={} client={} since={} status={} limit={}",
        args.ledger_path,
        rows.len(),
        args.client.as_deref().unwrap_or("*"),
        since.map(|v| v.to_string()).unwrap_or_else(|| "all".to_string()),
        args.status.as_deref().unwrap_or("*"),
        args.limit,
    );
    println!("created_unix\tclient\tdestination\tstatus\tpaid\texpected\tpayment_unix\tsummon_id\tsettlement_id");
    for row in rows {
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            row.timestamp_created,
            row.client_name,
            row.destination,
            payment_status_label(row.payment_status),
            copper(row.amount_paid_copper),
            copper(row.expected_price_copper),
            row.payment_timestamp.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string()),
            row.summon_id,
            row.settlement_id.unwrap_or_else(|| "-".to_string()),
        );
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("SUMMON_HISTORY_FAIL {error}");
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_filter_is_exact() {
        assert!(status_matches(PaymentStatus::Paid, Some("paid")));
        assert!(!status_matches(PaymentStatus::Overpaid, Some("paid")));
        assert!(status_matches(PaymentStatus::Uncertain, Some("uncertain")));
    }

    #[test]
    fn copper_format_is_human_readable() {
        assert_eq!(copper(40_000), "4g 00s 00c");
        assert_eq!(copper(12_345), "1g 23s 45c");
    }
}
