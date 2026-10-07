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

fn tele10_expected_price_copper() -> u64 {
    std::env::var("WOW112_TELE10_PRICE_COPPER")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(
            wow112_headless_android_probe::tele10_trade_payment::DEFAULT_EXPECTED_PRICE_COPPER,
        )
}

fn tele10_partial_enabled() -> bool {
    std::env::var("WOW112_TELE10_ACCEPT_PARTIAL")
        .ok()
        .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
}

fn tele10_record_ritual_started(target_name: &str, target_guid: u64) -> Result<String, String> {
    let mut ledger = LedgerStore::open(tele10_ledger_path())?;
    ledger.set_policy(tele10_expected_price_copper(), tele10_partial_enabled());
    let summoner_name = std::env::var("WOW112_CHARACTER").unwrap_or_else(|_| "unknown".to_string());
    let destination =
        std::env::var("WOW112_TELE_DESTINATION").unwrap_or_else(|_| "unknown".to_string());
    let trigger_message =
        std::env::var("WOW112_TELE_TRIGGER_MESSAGE").unwrap_or_else(|_| "unknown".to_string());
    let summon_id = ledger.record_ritual_started(
        unix_now(),
        target_name,
        target_guid,
        &summoner_name,
        &destination,
        &trigger_message,
    )?;
    println!(
        "[TELE10-LEDGER] SUMMON_CREATE summon_id={} client={:?} guid=0x{:016X} summoner={:?} destination={:?} expected={} path={}",
        summon_id,
        target_name,
        target_guid,
        summoner_name,
        destination,
        ledger.state.expected_price_copper,
        ledger.path().display()
    );
    Ok(summon_id)
}

fn tele10_active_summon_for_target(ledger: &LedgerStore, target_name: &str) -> Option<String> {
    ledger
        .state
        .summons
        .iter()
        .rev()
        .find(|record| record.client_name.eq_ignore_ascii_case(target_name))
        .map(|record| record.summon_id.clone())
}

fn tele10_refresh_correlation(
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
    target_name: &str,
) -> Result<(), String> {
    if session.summon_id.is_some() {
        return Ok(());
    }
    match ledger.correlate(
        session.partner_name.as_deref(),
        session.partner_guid,
        unix_now(),
    ) {
        Correlation::Unique(summon_id) => {
            ledger.mark_summoned(&summon_id, unix_now())?;
            println!(
                "[TELE10-TRADE] CORRELATED trade_id={} summon_id={} partner={} guid=0x{:016X}",
                session.trade_id,
                summon_id,
                session.partner_name.as_deref().unwrap_or(target_name),
                session.partner_guid
            );
            session.summon_id = Some(summon_id);
        }
        Correlation::Ambiguous(reason) => {
            println!(
                "[TELE10-TRADE] CORRELATION_AMBIGUOUS trade_id={} partner={:?} guid=0x{:016X} reason={}",
                session.trade_id,
                session.partner_name,
                session.partner_guid,
                reason
            );
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
    target_name: &str,
) -> Result<(), String> {
    tele10_refresh_correlation(ledger, session, target_name)?;
    let summon_id = match session.can_auto_accept(ledger) {
        Ok(value) => value.to_string(),
        Err(reason) => {
            println!(
                "[TELE10-TRADE] ACCEPT_GATE wait/block trade_id={} partner={:?} offered={} partner_accepted={} reason={}",
                session.trade_id,
                session.partner_name,
                session.offered_copper,
                session.partner_accepted,
                reason
            );
            return Ok(());
        }
    };
    let partner_name = session
        .partner_name
        .clone()
        .unwrap_or_else(|| target_name.to_string());
    let mutation_id = ledger.commit_accept_mutation(
        &session.trade_id,
        &summon_id,
        session.offered_copper,
        &partner_name,
        unix_now(),
    )?;
    session.accept_mutation_id = Some(mutation_id.clone());
    publish_runner_state(
        "TRADE_ACCEPT_COMMITTED",
        &format!(
            "trade_id={} summon_id={} offered={} mutation_id={} retry_allowed=false",
            session.trade_id, summon_id, session.offered_copper, mutation_id
        ),
    );
    println!(
        "[TELE10-TRADE-TX] state=COMMITTED opcode=0x011A trade_id={} summon_id={} offered={} mutation_id={} retry_allowed=false",
        session.trade_id, summon_id, session.offered_copper, mutation_id
    );
    let payload = 0u32.to_le_bytes();
    if let Err(error) = write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_ACCEPT_TRADE_OPCODE,
        &payload,
    ) {
        ledger.mark_accept_socket_uncertain(&mutation_id, unix_now(), &error)?;
        publish_runner_state(
            "FAIL_TRADE_ACCEPT_UNCERTAIN",
            &format!(
                "trade_id={} mutation_id={} socket_write_uncertain retry_allowed=false",
                session.trade_id, mutation_id
            ),
        );
        return Err(format!(
            "TELE10_TRADE_ACCEPT_MUTATION_UNCERTAIN trade_id={} mutation_id={} retry_allowed=false cause={error}",
            session.trade_id, mutation_id
        ));
    }
    session.accept_sent = true;
    publish_runner_state(
        "WAIT_TRADE_COMPLETE",
        &format!(
            "trade_id={} summon_id={} offered={} accept_write=success server_completion_required=true",
            session.trade_id, summon_id, session.offered_copper
        ),
    );
    println!(
        "[TELE10-TRADE-TX] state=SENT opcode=0x011A trade_id={} summon_id={} offered={} retry_allowed=false",
        session.trade_id, summon_id, session.offered_copper
    );
    Ok(())
}

fn tele10_resolve_cancel(
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
    target_name: &str,
    reason: &str,
) -> Result<(), String> {
    if session.terminal {
        return Ok(());
    }
    let partner_name = session
        .partner_name
        .clone()
        .unwrap_or_else(|| target_name.to_string());
    ledger.resolve_cancelled_trade(
        session.accept_mutation_id.as_deref(),
        session.summon_id.as_deref(),
        &partner_name,
        session.partner_guid,
        unix_now(),
        reason,
    )?;
    session.terminal = true;
    println!(
        "[TELE10-TRADE] CANCELLED trade_id={} summon_id={} partner={} offered={} reason={}",
        session.trade_id,
        session.summon_id.as_deref().unwrap_or("-"),
        partner_name,
        session.offered_copper,
        reason
    );
    Ok(())
}

fn tele10_settle_complete(
    ledger: &mut LedgerStore,
    session: &mut TradeSession,
    target_name: &str,
) -> Result<(), String> {
    if session.terminal {
        println!(
            "[TELE10-TRADE] duplicate terminal TRADE_COMPLETE ignored trade_id={}",
            session.trade_id
        );
        return Ok(());
    }
    let partner_name = session
        .partner_name
        .clone()
        .unwrap_or_else(|| target_name.to_string());
    let (Some(summon_id), Some(mutation_id)) = (
        session.summon_id.clone(),
        session.accept_mutation_id.clone(),
    ) else {
        ledger.mark_ambiguous_or_unassigned_payment(
            &partner_name,
            session.partner_guid,
            session.offered_copper,
            unix_now(),
            "server_trade_complete_without_terminal_accept_mutation",
        )?;
        session.terminal = true;
        publish_runner_state(
            "FAIL_TRADE_SETTLEMENT_UNASSIGNED",
            &format!(
                "trade_id={} partner={} offered={} server_complete=true no_accept_mutation=true",
                session.trade_id, partner_name, session.offered_copper
            ),
        );
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
        SettlementOutcome::Booked {
            settlement_id,
            event_id,
            status,
        } => {
            publish_runner_state(
                "PASS_PAYMENT_COMPLETE",
                &format!(
                    "trade_id={} summon_id={} partner={} amount={} status={:?} settlement_id={} payment_event_id={}",
                    session.trade_id,
                    summon_id,
                    partner_name,
                    session.offered_copper,
                    status,
                    settlement_id,
                    event_id
                ),
            );
            println!(
                "[TELE10-PAYMENT] PASS trade_id={} summon_id={} partner={} amount={} status={:?} settlement_id={} event_id={}",
                session.trade_id,
                summon_id,
                partner_name,
                session.offered_copper,
                status,
                settlement_id,
                event_id
            );
        }
        SettlementOutcome::Duplicate(event_id) => {
            println!(
                "[TELE10-PAYMENT] DUPLICATE_IGNORED trade_id={} event_id={}",
                session.trade_id, event_id
            );
        }
    }
    Ok(())
}

fn tele10_trade_receiver_loop(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    soak_seconds: u64,
    target_name: &str,
) -> Result<(), String> {
    let previous_timeout = stream.read_timeout().ok().flatten();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set TELE10 trade read timeout failed: {e}"))?;
    let deadline = if soak_seconds == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_secs(soak_seconds))
    };
    let mut ledger = LedgerStore::open(tele10_ledger_path())?;
    ledger.set_policy(tele10_expected_price_copper(), tele10_partial_enabled());
    let active_summon_id = tele10_active_summon_for_target(&ledger, target_name)
        .ok_or_else(|| format!("TELE10 ledger has no summon for target={target_name:?}"))?;
    let mut active_marked_summoned = false;
    let mut session: Option<TradeSession> = None;
    let mut last_ping = Instant::now();
    let mut ping_sequence = 1u32;
    let mut awaiting_pong: Option<(u32, Instant)> = None;

    println!(
        "[TELE10-TRADE] RECEIVER_ACTIVE target={:?} summon_id={} ledger={} expected={} partial={} settlement=server_TRADE_COMPLETE_only",
        target_name,
        active_summon_id,
        ledger.path().display(),
        ledger.state.expected_price_copper,
        ledger.state.partial_enabled
    );

    loop {
        tele_trace::poll_outcome("Tele10Trade");
        if deadline.is_some_and(|value| Instant::now() >= value) {
            let _ = stream.set_read_timeout(previous_timeout);
            return Ok(());
        }
        if let Some((sequence, sent_at)) = awaiting_pong {
            if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                return Err(format!("world keepalive pong timeout sequence={sequence}"));
            }
        }
        if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS)
            && awaiting_pong.is_none()
        {
            let mut payload = Vec::with_capacity(8);
            payload.extend_from_slice(&ping_sequence.to_le_bytes());
            payload.extend_from_slice(&0u32.to_le_bytes());
            write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
            awaiting_pong = Some((ping_sequence, Instant::now()));
            ping_sequence = ping_sequence.wrapping_add(1);
            last_ping = Instant::now();
        }

        match read_encrypted_raw(stream, crypto.decrypter()) {
            Ok((opcode, payload)) => {
                if opcode == SMSG_PONG_OPCODE {
                    if payload.len() >= 4 {
                        let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                        if awaiting_pong.map(|value| value.0) == Some(sequence) {
                            awaiting_pong = None;
                        }
                    }
                    continue;
                }
                tele_trace::trace_packet("Tele10Trade", opcode, &payload);

                if opcode == SMSG_SPELL_GO_OPCODE && !active_marked_summoned {
                    let parsed = parse_raw_server_message(opcode, &payload)
                        .map(|message| format!("{message:?}"))
                        .unwrap_or_default();
                    if parsed.contains("698") || parsed.contains("0x02BA") {
                        ledger.mark_summoned(&active_summon_id, unix_now())?;
                        active_marked_summoned = true;
                        println!(
                            "[TELE10-LEDGER] SUMMON_MARKED summon_id={} proof=SMSG_SPELL_GO spell=698",
                            active_summon_id
                        );
                    }
                }

                if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                    if let Ok((guid, name)) = tele_parse_name_query_response(&payload) {
                        if let Some(active) = session.as_mut() {
                            if active.partner_guid == guid && !active.terminal {
                                active.update_partner_name(&name);
                                tele10_refresh_correlation(&mut ledger, active, target_name)?;
                                tele10_try_accept(
                                    stream,
                                    crypto,
                                    &mut ledger,
                                    active,
                                    target_name,
                                )?;
                            }
                        }
                    }
                    continue;
                }

                if opcode == SMSG_TRADE_STATUS_EXTENDED_OPCODE {
                    match parse_trade_extended(&payload) {
                        Ok(update) => {
                            if let Some(active) = session.as_mut() {
                                if !active.terminal {
                                    active.update_offer(&update);
                                    println!(
                                        "[TELE10-TRADE] EXTENDED trade_id={} trader_state={} offered={} items={} spell={} bytes={}",
                                        active.trade_id,
                                        update.trader_state,
                                        update.offered_copper,
                                        update.has_items,
                                        update.spell_id,
                                        payload.len()
                                    );
                                    tele10_refresh_correlation(&mut ledger, active, target_name)?;
                                    tele10_try_accept(
                                        stream,
                                        crypto,
                                        &mut ledger,
                                        active,
                                        target_name,
                                    )?;
                                }
                            }
                        }
                        Err(error) => println!(
                            "[TELE10-TRADE-DIAG] extended parse skipped bytes={} reason={error}",
                            payload.len()
                        ),
                    }
                    continue;
                }

                if opcode != SMSG_TRADE_STATUS_OPCODE {
                    continue;
                }
                let status = match parse_trade_status(&payload) {
                    Ok(value) => value,
                    Err(error) => {
                        println!(
                            "[TELE10-TRADE-DIAG] status parse skipped bytes={} reason={error}",
                            payload.len()
                        );
                        continue;
                    }
                };
                println!(
                    "[TELE10-TRADE] STATUS status={} guid={:?} bytes={}",
                    status.status,
                    status.trader_guid,
                    payload.len()
                );
                match status.status {
                    TRADE_STATUS_BEGIN_TRADE => {
                        let partner_guid = status.trader_guid.unwrap_or(0);
                        if partner_guid == 0 {
                            println!("[TELE10-TRADE-DIAG] begin trade missing guid");
                            continue;
                        }
                        if session.as_ref().is_some_and(|value| !value.terminal) {
                            println!(
                                "[TELE10-TRADE] HARD_STOP overlapping trade begin partner_guid=0x{partner_guid:016X}"
                            );
                            continue;
                        }
                        let trade_id = ledger.allocate_trade_id(unix_now())?;
                        session = Some(TradeSession::new(trade_id.clone(), partner_guid));
                        if let Some(active) = session.as_mut() {
                            tele10_refresh_correlation(&mut ledger, active, target_name)?;
                        }
                        let _ = tele_send_name_query(stream, crypto, partner_guid);
                        publish_runner_state(
                            "TRADE_BEGIN_COMMITTED",
                            &format!(
                                "trade_id={} partner_guid=0x{:016X} opcode=0x0117 retry_allowed=false",
                                trade_id, partner_guid
                            ),
                        );
                        if let Err(error) = write_encrypted_raw(
                            stream,
                            crypto.encrypter(),
                            CMSG_BEGIN_TRADE_OPCODE,
                            &[],
                        ) {
                            publish_runner_state(
                                "FAIL_TRADE_BEGIN_UNCERTAIN",
                                &format!(
                                    "trade_id={} partner_guid=0x{:016X} retry_allowed=false",
                                    trade_id, partner_guid
                                ),
                            );
                            return Err(format!(
                                "TELE10_TRADE_BEGIN_MUTATION_UNCERTAIN trade_id={trade_id} retry_allowed=false cause={error}"
                            ));
                        }
                        println!(
                            "[TELE10-TRADE-TX] opcode=0x0117 trade_id={} partner_guid=0x{:016X} result=sent_once retry_allowed=false",
                            trade_id, partner_guid
                        );
                    }
                    TRADE_STATUS_OPEN_WINDOW => {
                        println!("[TELE10-TRADE] OPEN_WINDOW");
                    }
                    TRADE_STATUS_TRADE_ACCEPT => {
                        if let Some(active) = session.as_mut() {
                            if !active.terminal {
                                active.partner_accepted = true;
                                tele10_try_accept(
                                    stream,
                                    crypto,
                                    &mut ledger,
                                    active,
                                    target_name,
                                )?;
                            }
                        }
                    }
                    TRADE_STATUS_BACK_TO_TRADE => {
                        if let Some(active) = session.as_mut() {
                            active.partner_accepted = false;
                            if active.accept_mutation_id.is_some() {
                                tele10_resolve_cancel(
                                    &mut ledger,
                                    active,
                                    target_name,
                                    "server_back_to_trade_after_accept_no_retry",
                                )?;
                            }
                        }
                    }
                    TRADE_STATUS_TRADE_COMPLETE => {
                        if let Some(active) = session.as_mut() {
                            tele10_settle_complete(&mut ledger, active, target_name)?;
                        } else {
                            ledger.mark_ambiguous_or_unassigned_payment(
                                "unknown",
                                0,
                                0,
                                unix_now(),
                                "server_trade_complete_without_session",
                            )?;
                            return Err(
                                "TELE10_TRADE_COMPLETE_WITHOUT_SESSION hard_stop=true".to_string()
                            );
                        }
                    }
                    TRADE_STATUS_TRADE_CANCELED
                    | TRADE_STATUS_TRADE_REJECTED
                    | TRADE_STATUS_CLOSE_WINDOW
                    | TRADE_STATUS_BUSY
                    | TRADE_STATUS_NO_TARGET
                    | TRADE_STATUS_TARGET_TO_FAR => {
                        if let Some(active) = session.as_mut() {
                            tele10_resolve_cancel(
                                &mut ledger,
                                active,
                                target_name,
                                &format!("server_trade_status_{}", status.status),
                            )?;
                        }
                    }
                    _ => {}
                }
            }
            Err(error)
                if error.contains("TimedOut")
                    || error.contains("timed out")
                    || error.contains("WouldBlock") => {}
            Err(error) => return Err(error),
        }
    }
}
