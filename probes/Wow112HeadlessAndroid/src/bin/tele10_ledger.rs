use std::env;
use std::path::PathBuf;
use wow112_headless_android_probe::tele10_trade_payment::{
    LedgerStore, PaymentStatus, SummonRecord,
};

fn ledger_path() -> PathBuf {
    env::var("WOW112_TELE10_LEDGER_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele10_payment_ledger.json"))
}

fn print_summon(record: &SummonRecord) {
    println!(
        "summon_id={} ts={} client={} guid=0x{:016X} summoner={} destination={} trigger={:?} expected={} summon_status={:?} payment_status={:?} paid={} payment_ts={} settlement={} failure={}",
        record.summon_id,
        record.timestamp_created,
        record.client_name,
        record.client_guid,
        record.summoner_name,
        record.destination,
        record.trigger_message,
        record.expected_price_copper,
        record.summon_status,
        record.payment_status,
        record.amount_paid_copper,
        record
            .payment_timestamp
            .map(|value| value.to_string())
            .unwrap_or_else(|| "-".to_string()),
        record.settlement_id.as_deref().unwrap_or("-"),
        record.failure_reason.as_deref().unwrap_or("-"),
    );
}

fn parse_status(value: &str) -> Option<PaymentStatus> {
    match value.to_ascii_lowercase().as_str() {
        "unpaid" => Some(PaymentStatus::Unpaid),
        "partial" => Some(PaymentStatus::Partial),
        "paid" => Some(PaymentStatus::Paid),
        "overpaid" => Some(PaymentStatus::Overpaid),
        "cancelled" | "canceled" => Some(PaymentStatus::Cancelled),
        "uncertain" => Some(PaymentStatus::Uncertain),
        _ => None,
    }
}

fn parse_limit(args: &[String], default_value: usize) -> usize {
    args.iter()
        .rev()
        .find_map(|value| value.parse::<usize>().ok())
        .unwrap_or(default_value)
        .clamp(1, 500)
}

fn usage() {
    println!("TELE10 terminal ledger");
    println!("  tele10_ledger status");
    println!("  tele10_ledger recent [N]");
    println!("  tele10_ledger player <name> [N]");
    println!("  tele10_ledger unpaid|partial|paid|overpaid|uncertain [N]");
    println!("  tele10_ledger payments [name] [N]");
    println!("  tele10_ledger since <minutes> [N]");
    println!("env: WOW112_TELE10_LEDGER_PATH=<path>");
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() || args[0] == "help" || args[0] == "--help" {
        usage();
        return Ok(());
    }
    let path = ledger_path();
    let ledger = LedgerStore::open(&path)?;
    match args[0].to_ascii_lowercase().as_str() {
        "status" => {
            let unpaid = ledger
                .state
                .summons
                .iter()
                .filter(|record| record.payment_status == PaymentStatus::Unpaid)
                .count();
            let partial = ledger
                .state
                .summons
                .iter()
                .filter(|record| record.payment_status == PaymentStatus::Partial)
                .count();
            let uncertain = ledger
                .state
                .summons
                .iter()
                .filter(|record| record.payment_status == PaymentStatus::Uncertain)
                .count();
            let paid = ledger
                .state
                .summons
                .iter()
                .filter(|record| {
                    matches!(
                        record.payment_status,
                        PaymentStatus::Paid | PaymentStatus::Overpaid
                    )
                })
                .count();
            let unresolved_mutations = ledger
                .state
                .mutations
                .iter()
                .filter(|record| !record.resolved)
                .count();
            println!(
                "ledger={} schema={} revision={} summons={} payments={} unpaid={} partial={} paid_or_overpaid={} uncertain={} unresolved_mutations={} expected_price={} partial_enabled={}",
                path.display(),
                ledger.state.schema_version,
                ledger.state.state_revision,
                ledger.state.summons.len(),
                ledger.state.payments.len(),
                unpaid,
                partial,
                paid,
                uncertain,
                unresolved_mutations,
                ledger.state.expected_price_copper,
                ledger.state.partial_enabled,
            );
        }
        "recent" => {
            for record in ledger.recent_summons(parse_limit(&args, 10)) {
                print_summon(record);
            }
        }
        "player" => {
            let name = args
                .get(1)
                .ok_or_else(|| "player requires <name>".to_string())?;
            for record in ledger.filtered_summons(
                Some(name),
                None,
                None,
                parse_limit(&args[2..], 20),
            ) {
                print_summon(record);
            }
        }
        "payments" => {
            let player = args
                .get(1)
                .filter(|value| value.parse::<usize>().is_err())
                .map(String::as_str);
            let limit = parse_limit(&args, 20);
            for record in ledger.recent_payments(player, limit) {
                println!(
                    "payment_event_id={} settlement={} summon={} ts={} partner={} guid=0x{:016X} amount={} status={:?} failure={}",
                    record.payment_event_id,
                    record.settlement_id.as_deref().unwrap_or("-"),
                    record.summon_id.as_deref().unwrap_or("-"),
                    record.timestamp,
                    record.trade_partner,
                    record.partner_guid,
                    record.amount_copper,
                    record.payment_status,
                    record.failure_reason.as_deref().unwrap_or("-"),
                );
            }
        }
        "since" => {
            let minutes = args
                .get(1)
                .ok_or_else(|| "since requires <minutes>".to_string())?
                .parse::<i64>()
                .map_err(|e| format!("invalid minutes: {e}"))?
                .max(0);
            let since = wow112_headless_android_probe::tele10_trade_payment::unix_now()
                .saturating_sub(minutes.saturating_mul(60));
            for record in ledger.filtered_summons(
                None,
                None,
                Some(since),
                parse_limit(&args[2..], 50),
            ) {
                print_summon(record);
            }
        }
        status_name => {
            let status = parse_status(status_name)
                .ok_or_else(|| format!("unknown ledger query {status_name:?}"))?;
            for record in ledger.filtered_summons(
                None,
                Some(status),
                None,
                parse_limit(&args[1..], 20),
            ) {
                print_summon(record);
            }
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE10-LEDGER] ERROR: {error}");
        std::process::exit(2);
    }
}
