// Canonical TELE10 trade receiver runtime is intentionally restored from the proven
// live-tested source line. This file is included by the summon service world adapter;
// payment semantics remain in tele10_trade_payment.rs.

use wow112_headless_android_probe::tele10_trade_payment::{
    parse_trade_extended, parse_trade_status, unix_now, Correlation, LedgerStore,
    SettlementOutcome, TradeSession, CMSG_ACCEPT_TRADE_OPCODE, CMSG_BEGIN_TRADE_OPCODE,
    SMSG_TRADE_STATUS_EXTENDED_OPCODE, SMSG_TRADE_STATUS_OPCODE, TRADE_STATUS_BACK_TO_TRADE,
    TRADE_STATUS_BEGIN_TRADE, TRADE_STATUS_BUSY, TRADE_STATUS_CLOSE_WINDOW, TRADE_STATUS_NO_TARGET,
    TRADE_STATUS_OPEN_WINDOW, TRADE_STATUS_TARGET_TO_FAR, TRADE_STATUS_TRADE_ACCEPT,
    TRADE_STATUS_TRADE_CANCELED, TRADE_STATUS_TRADE_COMPLETE, TRADE_STATUS_TRADE_REJECTED,
};

fn tele10_ledger_path() -> std::path::PathBuf {
    std::env::var("WOW112_TELE10_LEDGER_PATH")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("tele10_payment_ledger.json"))
}

fn tele10_parse_price_env(name: &str) -> Option<u64> {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
}

fn tele10_price_key_component(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_string()
}

fn tele10_expected_price_copper() -> u64 {
    tele10_parse_price_env("WOW112_TELE10_PRICE_COPPER")
        .unwrap_or(wow112_headless_android_probe::tele10_trade_payment::DEFAULT_EXPECTED_PRICE_COPPER)
}

fn tele10_expected_price_for(summoner_name: &str, destination: &str) -> u64 {
    let summoner = tele10_price_key_component(summoner_name);
    let destination = tele10_price_key_component(destination);
    let summoner_destination = format!(
        "WOW112_SUMMON_PRICE_{}_{}_COPPER",
        summoner, destination
    );
    let destination_only = format!("WOW112_SUMMON_PRICE_{}_COPPER", destination);
    tele10_parse_price_env(&summoner_destination)
        .or_else(|| tele10_parse_price_env(&destination_only))
        .unwrap_or_else(tele10_expected_price_copper)
}

fn tele10_partial_enabled() -> bool {
    std::env::var("WOW112_TELE10_ACCEPT_PARTIAL")
        .ok()
        .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
}

fn tele10_record_ritual_started(
    target_name: &str,
    target_guid: u64,
    destination: &str,
    trigger_message: &str,
    summoner_name: &str,
) -> Result<String, String> {
    let mut ledger = LedgerStore::open(tele10_ledger_path())?;
    let expected_price = tele10_expected_price_for(summoner_name, destination);
    ledger.set_policy(expected_price, tele10_partial_enabled());
    let summon_id = ledger.record_ritual_started(
        unix_now(),
        target_name,
        target_guid,
        summoner_name,
        destination,
        trigger_message,
    )?;
    println!("[SUMMON-SERVICE][LEDGER] SUMMON_CREATE summon_id={} client={:?} guid=0x{:016X} summoner={:?} destination={:?} expected={} price_source=resolved", summon_id, target_name, target_guid, summoner_name, destination, ledger.state.expected_price_copper);
    Ok(summon_id)
}

fn tele10_refresh_correlation(
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
) -> Result<(), String> {
    if session.summon_id.is_some() { return Ok(()); }
    match ledger.correlate(session.partner_name.as_deref(), session.partner_guid, unix_now()) {
        Correlation::Unique(summon_id) => {
            session.summon_id = Some(summon_id.clone());
            println!("[SUMMON-SERVICE][TRADE] CORRELATED trade_id={} summon_id={}", session.trade_id, summon_id);
        }
        Correlation::Ambiguous(reason) => {
            println!("[SUMMON-SERVICE][TRADE] CORRELATION_AMBIGUOUS trade_id={} reason={}", session.trade_id, reason);
        }
        Correlation::None => {}
    }
    Ok(())
}

fn tele10_try_accept(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
) -> Result<(), String> {
    tele10_refresh_correlation(ledger, session)?;
    let summon_id = match session.can_auto_accept(ledger) {
        Ok(value) => value.to_string(),
        Err(reason) => {
            println!("[SUMMON-SERVICE][TRADE] ACCEPT_GATE trade_id={} offered={} reason={}", session.trade_id, session.offered_copper, reason);
            return Ok(());
        }
    };
    let partner_name = session.partner_name.clone().unwrap_or_else(|| "unknown".to_string());
    let mutation_id = ledger.commit_accept_mutation(
        &session.trade_id,
        &summon_id,
        session.offered_copper,
        &partner_name,
        unix_now(),
    )?;
    session.accept_mutation_id = Some(mutation_id.clone());
    let payload = 0u32.to_le_bytes();
    if let Err(error) = write_encrypted_raw(stream, crypto.encrypter(), CMSG_ACCEPT_TRADE_OPCODE, &payload) {
        ledger.mark_accept_socket_uncertain(&mutation_id, unix_now(), &error)?;
        return Err(format!("TELE10_TRADE_ACCEPT_MUTATION_UNCERTAIN trade_id={} mutation_id={} retry_allowed=false cause={error}", session.trade_id, mutation_id));
    }
    session.accept_sent = true;
    println!("[SUMMON-SERVICE][TRADE-TX] opcode=0x011A trade_id={} summon_id={} offered={} retry_allowed=false", session.trade_id, summon_id, session.offered_copper);
    Ok(())
}

fn tele10_resolve_cancel(
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
    reason: &str,
) -> Result<(), String> {
    if session.terminal { return Ok(()); }
    let partner_name = session.partner_name.clone().unwrap_or_else(|| "unknown".to_string());
    ledger.resolve_cancelled_trade(
        session.accept_mutation_id.as_deref(),
        session.summon_id.as_deref(),
        &partner_name,
        session.partner_guid,
        unix_now(),
        reason,
    )?;
    session.terminal = true;
    Ok(())
}

fn tele10_settle_complete(
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
) -> Result<Option<(String, u64, String)>, String> {
    if session.terminal { return Ok(None); }
    let partner_name = session.partner_name.clone().unwrap_or_else(|| "unknown".to_string());
    let (Some(summon_id), Some(mutation_id)) = (session.summon_id.clone(), session.accept_mutation_id.clone()) else {
        ledger.mark_ambiguous_or_unassigned_payment(
            &partner_name,
            session.partner_guid,
            session.offered_copper,
            unix_now(),
            "server_trade_complete_without_terminal_accept_mutation",
        )?;
        session.terminal = true;
        return Err("TELE10_TRADE_COMPLETE_UNASSIGNED hard_stop=true".to_string());
    };
    let outcome = ledger.settle_trade_complete(
        &session.trade_id,
        &mutation_id,
        &summon_id,
        &partner_name,
        session.partner_guid,
        session.offered_copper,
        unix_now(),
    )?;
    session.terminal = true;
    match outcome {
        SettlementOutcome::Booked { settlement_id, event_id, status } => {
            println!("[SUMMON-SERVICE][PAYMENT] PASS summon_id={} partner={} amount={} status={:?} settlement_id={} event_id={}", summon_id, partner_name, session.offered_copper, status, settlement_id, event_id);
            Ok(Some((summon_id, session.offered_copper, settlement_id)))
        }
        SettlementOutcome::Duplicate(event_id) => {
            println!("[SUMMON-SERVICE][PAYMENT] DUPLICATE_IGNORED trade_id={} event_id={}", session.trade_id, event_id);
            Ok(None)
        }
    }
}
