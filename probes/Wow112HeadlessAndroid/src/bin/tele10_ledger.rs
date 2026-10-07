use std::env;
use std::path::PathBuf;

use wow112_headless_android_probe::tele10_trade_ledger::{
    format_money, format_summon_line, LedgerStore,
};

fn ledger_path() -> Result<PathBuf, String> {
    if let Ok(path) = env::var("WOW112_TELE10_LEDGER_PATH") {
        if !path.trim().is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    let summoner = env::var("WOW112_CHARACTER")
        .or_else(|_| env::var("WOW112_TELE10_SUMMONER"))
        .map_err(|_| {
            "set WOW112_TELE10_LEDGER_PATH or WOW112_CHARACTER/WOW112_TELE10_SUMMONER".to_string()
        })?;
    let dir = env::var("WOW112_TELE10_LEDGER_DIR").unwrap_or_else(|_| "tele10_ledger".to_string());
    Ok(LedgerStore::stable_file_for(dir, &summoner))
}

fn parse_limit(value: Option<&String>, default_value: usize) -> usize {
    value
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default_value)
}

fn print_summons(records: impl IntoIterator<Item = wow112_headless_android_probe::tele10_trade_ledger::SummonRecord>) {
    for record in records {
        println!("{}", format_summon_line(&record));
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    let store = LedgerStore::new(ledger_path()?);
    let command = args.first().map(String::as_str).unwrap_or("recent");

    match command {
        "recent" => {
            let limit = parse_limit(args.get(1), 20);
            print_summons(store.recent_summons(limit)?);
        }
        "player" => {
            let player = args
                .get(1)
                .ok_or_else(|| "usage: tele10_ledger player <name>".to_string())?;
            print_summons(store.summons_for_player(player)?);
        }
        "unpaid" | "partial" | "paid" | "overpaid" | "uncertain" => {
            let limit = parse_limit(args.get(1), 20);
            print_summons(store.summons_by_payment_status(command, limit)?);
        }
        "payments" => {
            let (player, limit_index) = match args.get(1) {
                Some(value) if value.parse::<usize>().is_err() => (Some(value.as_str()), 2),
                _ => (None, 1),
            };
            let limit = parse_limit(args.get(limit_index), 20);
            for event in store.payments_for_player(player, limit)? {
                println!(
                    "{} | {} | offered {} | received {} | {} | summon={} | settlement={} | {}",
                    event.trade_partner,
                    event.timestamp,
                    format_money(event.offered_copper),
                    format_money(event.received_copper),
                    event.status.to_ascii_uppercase(),
                    event.summon_id.as_deref().unwrap_or("-"),
                    event.settlement_id.as_deref().unwrap_or("-"),
                    event.reason
                );
            }
        }
        "status" => {
            let state = store.load()?;
            println!("ledger={}", store.path().display());
            println!("summons={}", state.summons.len());
            println!("payments={}", state.payments.len());
            println!("pending_accept_intents={}", state.pending_intents.len());
            for status in ["unpaid", "partial", "paid", "overpaid", "uncertain"] {
                let count = state
                    .summons
                    .iter()
                    .filter(|record| record.payment_status == status)
                    .count();
                println!("{status}={count}");
            }
        }
        "help" | "--help" | "-h" => {
            println!("tele10_ledger recent [n]");
            println!("tele10_ledger player <name>");
            println!("tele10_ledger unpaid|partial|paid|overpaid|uncertain [n]");
            println!("tele10_ledger payments [name] [n]");
            println!("tele10_ledger status");
        }
        other => return Err(format!("unknown command {other:?}; use --help")),
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE10-LEDGER] ERROR: {error}");
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_limit_is_bounded_to_positive_values() {
        assert_eq!(parse_limit(Some(&"5".to_string()), 20), 5);
        assert_eq!(parse_limit(Some(&"0".to_string()), 20), 20);
        assert_eq!(parse_limit(Some(&"bad".to_string()), 20), 20);
    }
}
