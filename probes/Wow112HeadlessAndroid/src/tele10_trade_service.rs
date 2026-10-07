use wow112_headless_android_probe::tele10_trade_ledger::{unix_now, LedgerStore};
use wow112_headless_android_probe::tele10_trade_runtime::{
    encode_accept_trade_payload, TradeAction, TradeEngine, CMSG_ACCEPT_TRADE_OPCODE,
    CMSG_BEGIN_TRADE_OPCODE, SMSG_TRADE_STATUS_EXTENDED_OPCODE, SMSG_TRADE_STATUS_OPCODE,
};

fn tele10_enabled() -> bool {
    std::env::var("WOW112_TELE10_TRADE_ENABLED")
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn tele10_ledger_path(summoner_name: &str) -> std::path::PathBuf {
    if let Ok(path) = std::env::var("WOW112_TELE10_LEDGER_PATH") {
        if !path.trim().is_empty() {
            return std::path::PathBuf::from(path);
        }
    }
    let dir =
        std::env::var("WOW112_TELE10_LEDGER_DIR").unwrap_or_else(|_| "tele10_ledger".to_string());
    LedgerStore::stable_file_for(dir, summoner_name)
}

fn tele10_store(summoner_name: &str) -> LedgerStore {
    let mut store = LedgerStore::new(tele10_ledger_path(summoner_name));
    if let Ok(value) = std::env::var("WOW112_TELE10_PRICE_COPPER") {
        if let Ok(price) = value.trim().parse::<u32>() {
            if price > 0 {
                store.expected_price_copper = price;
            }
        }
    }
    store.partial_enabled = std::env::var("WOW112_TELE10_PARTIAL_ENABLED")
        .ok()
        .map(|value| {
            !matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "0" | "false" | "no" | "off"
            )
        })
        .unwrap_or(true);
    store
}

fn tele10_note_ritual_started(
    client_name: &str,
    summoner_name: &str,
    destination: &str,
) -> Result<String, String> {
    let store = tele10_store(summoner_name);
    let trigger = std::env::var("WOW112_TELE10_TRIGGER_MESSAGE").unwrap_or_default();
    let record = store.create_ritual_started(
        client_name,
        summoner_name,
        destination,
        &trigger,
        unix_now(),
    )?;
    println!(
        "[TELE10-LEDGER] summon_created id={} client={:?} summoner={:?} destination={:?} expected_copper={} status={}",
        record.summon_id,
        record.client_name,
        record.summoner_name,
        record.destination,
        record.expected_price_copper,
        record.summon_status
    );
    Ok(record.summon_id)
}

fn tele10_coinage_from_mask(object_guid: u64, mask: &UpdateMask, player_guid: u64) -> Option<u32> {
    match mask {
        UpdateMask::Player(player) if object_guid == player_guid => {
            player.player_field_coinage().map(|value| value as u32)
        }
        _ => None,
    }
}

fn tele10_coinage_from_update(opcode: u16, payload: &[u8], player_guid: u64) -> Option<u32> {
    if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
        return None;
    }
    let message = parse_raw_server_message(opcode, payload).ok()?;
    let objects = match message {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message) => message.objects,
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message) => message.objects,
        _ => return None,
    };
    let mut latest = None;
    for object in objects {
        let value = match object {
            Object::Values { guid1, mask1 } => {
                tele10_coinage_from_mask(guid1.guid(), &mask1, player_guid)
            }
            Object::CreateObject { guid3, mask2, .. }
            | Object::CreateObject2 { guid3, mask2, .. } => {
                tele10_coinage_from_mask(guid3.guid(), &mask2, player_guid)
            }
            _ => None,
        };
        if value.is_some() {
            latest = value;
        }
    }
    latest
}

fn tele10_monotonic_ms(epoch: &Instant) -> u64 {
    epoch.elapsed().as_millis() as u64
}

fn tele10_execute_actions(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    engine: &mut TradeEngine,
    actions: Vec<TradeAction>,
) -> Result<(), String> {
    for action in actions {
        match action {
            TradeAction::QueryPartnerName(guid) => {
                tele_send_name_query(stream, crypto, guid)?;
            }
            TradeAction::BeginTrade => {
                if write_encrypted_raw(stream, crypto.encrypter(), CMSG_BEGIN_TRADE_OPCODE, &[])
                    .is_err()
                {
                    return Err(
                        "TELE10_BEGIN_TRADE_MUTATION_UNCERTAIN retry_allowed=false".to_string()
                    );
                }
                println!(
                    "[TELE10-TRADE-TX] opcode=0x0117 action=BEGIN_TRADE result=sent_once retry_allowed=false"
                );
            }
            TradeAction::AcceptTrade { intent_id } => {
                let payload = encode_accept_trade_payload();
                if write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_ACCEPT_TRADE_OPCODE,
                    &payload,
                )
                .is_err()
                {
                    let event = engine.on_accept_write_uncertain(
                        &intent_id,
                        "world_socket_write_failed",
                        unix_now(),
                    )?;
                    println!(
                        "[TELE10-PAYMENT] status={} intent={} reason={}",
                        event.status, intent_id, event.reason
                    );
                    return Err(
                        "TELE10_TRADE_ACCEPT_MUTATION_UNCERTAIN retry_allowed=false".to_string()
                    );
                }
                engine.on_accept_write_success(&intent_id);
                println!(
                    "[TELE10-TRADE-TX] opcode=0x011A action=ACCEPT_TRADE intent={} result=sent_once retry_allowed=false",
                    intent_id
                );
            }
        }
    }
    Ok(())
}

fn tele10_print_terminal(event: &wow112_headless_android_probe::tele10_trade_ledger::PaymentEvent) {
    println!(
        "[TELE10-PAYMENT] event={} settlement={} summon={} partner={:?} offered={} received={} status={} reason={}",
        event.payment_event_id,
        event.settlement_id.as_deref().unwrap_or("-"),
        event.summon_id.as_deref().unwrap_or("-"),
        event.trade_partner,
        event.offered_copper,
        event.received_copper,
        event.status.to_ascii_uppercase(),
        event.reason
    );
}

fn tele10_trade_service_loop(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    soak_seconds: u64,
    player_guid: u64,
    summoner_name: &str,
) -> Result<(), String> {
    if !tele10_enabled() {
        println!("[TELE10-TRADE] disabled -> canonical TELE sniffer");
        return tele_sniffer_loop(stream, crypto, soak_seconds);
    }

    let previous_timeout = stream.read_timeout().ok().flatten();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|error| format!("set TELE10 trade read timeout failed: {error}"))?;
    let epoch = Instant::now();
    let deadline = if soak_seconds == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_secs(soak_seconds))
    };
    let mut last_ping = Instant::now();
    let mut ping_sequence = 1u32;
    let mut awaiting_pong: Option<(u32, Instant)> = None;
    let mut engine = TradeEngine::new(
        tele10_store(summoner_name),
        wow112_headless_android_probe::tele10_trade_ledger::DEFAULT_SETTLEMENT_TIMEOUT_MS,
    );

    println!(
        "[TELE10-TRADE] SERVICE ACTIVE summoner={:?} guid=0x{:016X} ledger={} partial_enabled={} gui=none",
        summoner_name,
        player_guid,
        engine.store().path().display(),
        engine.store().partial_enabled
    );

    loop {
        let now_ms = tele10_monotonic_ms(&epoch);
        if let Some(event) = engine.poll(unix_now(), now_ms)? {
            tele10_print_terminal(&event);
        }
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

                if let Some(coinage) = tele10_coinage_from_update(opcode, &payload, player_guid) {
                    if let Some(event) = engine.on_coinage(coinage, unix_now(), now_ms)? {
                        tele10_print_terminal(&event);
                    }
                    println!("[TELE10-COINAGE] copper={coinage}");
                }

                if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                    if let Ok((guid, name)) = tele_parse_name_query_response(&payload) {
                        let actions = engine.on_partner_name(guid, &name, unix_now())?;
                        if !actions.is_empty() {
                            println!(
                                "[TELE10-CORRELATION] partner={:?} guid=0x{:016X} result=eligible",
                                name, guid
                            );
                        }
                        tele10_execute_actions(stream, crypto, &mut engine, actions)?;
                    }
                    continue;
                }

                if opcode == SMSG_TRADE_STATUS_OPCODE {
                    let actions = engine.on_trade_status(&payload, unix_now(), now_ms)?;
                    tele10_execute_actions(stream, crypto, &mut engine, actions)?;
                    continue;
                }
                if opcode == SMSG_TRADE_STATUS_EXTENDED_OPCODE {
                    let snapshot = TradeEngine::parse_extended(&payload)?;
                    if snapshot.their_window {
                        println!(
                            "[TELE10-TRADE-RX] partner_offer_copper={}",
                            snapshot.offered_copper
                        );
                    }
                    let actions = engine.on_trade_extended(&payload, unix_now())?;
                    tele10_execute_actions(stream, crypto, &mut engine, actions)?;
                    continue;
                }

                // Keep party diagnostics alive without letting unrelated packets alter payment state.
                let _ = crate::tele_party_observer::inspect_party_packet(opcode, &payload);
            }
            Err(error)
                if error.contains("TimedOut")
                    || error.contains("timed out")
                    || error.contains("WouldBlock") => {}
            Err(error) => return Err(error),
        }
    }
}
