use wow112_headless_android_probe::tele10_trade_payment::{
    parse_trade_status, CMSG_ACCEPT_TRADE_OPCODE, CMSG_INITIATE_TRADE_OPCODE,
    CMSG_SET_TRADE_GOLD_OPCODE, SMSG_TRADE_STATUS_OPCODE, TRADE_STATUS_BUSY,
    TRADE_STATUS_CLOSE_WINDOW, TRADE_STATUS_NO_TARGET, TRADE_STATUS_OPEN_WINDOW,
    TRADE_STATUS_TARGET_TO_FAR, TRADE_STATUS_TRADE_CANCELED, TRADE_STATUS_TRADE_COMPLETE,
    TRADE_STATUS_TRADE_REJECTED,
};

fn tele10_pay_target() -> Option<String> {
    std::env::var("WOW112_TELE10_PAY_SUMMONER")
        .ok()
        .or_else(|| std::env::var("WOW112_TELE08_SUMMONER_CHARACTER").ok())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty() && v != "__FIRST__")
}

fn tele10_pay_amount() -> u32 {
    std::env::var("WOW112_TELE10_PAY_COPPER")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(40_000)
}

fn tele10_publish_teleport_checkpoint(detail: &str) {
    if let Some(target) = tele10_pay_target() {
        publish_runner_state(
            "WAIT_PAYMENT_CLIENT",
            &format!("teleport_complete=true payment_target={target} detail={detail}"),
        );
    } else {
        publish_runner_state("PASS_TELEPORT_COMPLETE", detail);
    }
}

fn tele10_customer_pay_after_teleport(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
) -> Result<(), String> {
    let Some(target_name) = tele10_pay_target() else {
        return Ok(());
    };
    if TELE10_PAYMENT_ATTEMPTED
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Ok(());
    }
    let amount = tele10_pay_amount();
    publish_runner_state(
        "WAIT_PAYMENT_CLIENT",
        &format!("target={} amount={} teleport_complete=true", target_name, amount),
    );
    let settle_ms = std::env::var("WOW112_TELE10_PAY_SETTLE_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(750)
        .min(5_000);
    if settle_ms != 0 {
        thread::sleep(Duration::from_millis(settle_ms));
    }
    let target_guid = tele10_cached_guid(&target_name).ok_or_else(|| {
        format!("TELE10_PAYER_TARGET_GUID_UNKNOWN target={target_name:?} retry_allowed=false")
    })?;

    publish_runner_state(
        "PAYMENT_INITIATE_COMMITTED",
        &format!(
            "target={} guid=0x{:016X} amount={} retry_allowed=false",
            target_name, target_guid, amount
        ),
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_INITIATE_TRADE_OPCODE,
        &target_guid.to_le_bytes(),
    )
    .map_err(|e| format!("TELE10_PAYER_INITIATE_UNCERTAIN retry_allowed=false cause={e}"))?;
    println!(
        "[TELE10-PAYER-TX] opcode=0x0116 target={} guid=0x{:016X} amount={} sent_once",
        target_name, target_guid, amount
    );

    let previous_timeout = stream.read_timeout().ok().flatten();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set TELE10 payer timeout failed: {e}"))?;
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut gold_sent = false;
    let mut accept_sent = false;

    loop {
        if Instant::now() >= deadline {
            let _ = stream.set_read_timeout(previous_timeout);
            return Err(format!("TELE10_PAYER_TIMEOUT gold_sent={gold_sent} accept_sent={accept_sent} retry_allowed=false"));
        }
        match read_encrypted_raw(stream, crypto.decrypter()) {
            Ok((opcode, payload)) => {
                tele10_payer_observe_packet(opcode, &payload);
                tele_trace::trace_packet("Tele10Payer", opcode, &payload);
                if opcode != SMSG_TRADE_STATUS_OPCODE {
                    continue;
                }
                let status = match parse_trade_status(&payload) {
                    Ok(v) => v.status,
                    Err(e) => {
                        println!("[TELE10-PAYER-DIAG] bad trade status: {e}");
                        continue;
                    }
                };
                match status {
                    TRADE_STATUS_OPEN_WINDOW if !gold_sent => {
                        publish_runner_state(
                            "PAYMENT_GOLD_COMMITTED",
                            &format!("amount={} retry_allowed=false", amount),
                        );
                        write_encrypted_raw(
                            stream,
                            crypto.encrypter(),
                            CMSG_SET_TRADE_GOLD_OPCODE,
                            &amount.to_le_bytes(),
                        )
                        .map_err(|e| {
                            format!("TELE10_PAYER_SET_GOLD_UNCERTAIN retry_allowed=false cause={e}")
                        })?;
                        gold_sent = true;
                        publish_runner_state(
                            "PAYMENT_ACCEPT_COMMITTED",
                            &format!("amount={} retry_allowed=false", amount),
                        );
                        write_encrypted_raw(
                            stream,
                            crypto.encrypter(),
                            CMSG_ACCEPT_TRADE_OPCODE,
                            &0u32.to_le_bytes(),
                        )
                        .map_err(|e| {
                            format!("TELE10_PAYER_ACCEPT_UNCERTAIN retry_allowed=false cause={e}")
                        })?;
                        accept_sent = true;
                        publish_runner_state(
                            "WAIT_PAYMENT_COMPLETE",
                            &format!("target={} amount={}", target_name, amount),
                        );
                        println!("[TELE10-PAYER-TX] gold={} accept=sent_once", amount);
                    }
                    TRADE_STATUS_TRADE_COMPLETE => {
                        let _ = stream.set_read_timeout(previous_timeout);
                        publish_runner_state(
                            "PASS_TELEPORT_COMPLETE",
                            &format!(
                                "payment_sent=PASS target={} amount={} proof=server_TRADE_COMPLETE",
                                target_name, amount
                            ),
                        );
                        println!(
                            "[TELE10-PAYER] PASS target={} amount={} proof=TRADE_COMPLETE",
                            target_name, amount
                        );
                        return Ok(());
                    }
                    TRADE_STATUS_TRADE_CANCELED
                    | TRADE_STATUS_TRADE_REJECTED
                    | TRADE_STATUS_CLOSE_WINDOW
                    | TRADE_STATUS_BUSY
                    | TRADE_STATUS_NO_TARGET
                    | TRADE_STATUS_TARGET_TO_FAR => {
                        let _ = stream.set_read_timeout(previous_timeout);
                        return Err(format!(
                            "TELE10_PAYER_SERVER_REJECT status={status} retry_allowed=false"
                        ));
                    }
                    _ => {}
                }
            }
            Err(e)
                if e.contains("TimedOut")
                    || e.contains("timed out")
                    || e.contains("WouldBlock") => {}
            Err(e) => {
                let _ = stream.set_read_timeout(previous_timeout);
                return Err(format!("TELE10_PAYER_SOCKET_UNCERTAIN gold_sent={gold_sent} accept_sent={accept_sent} retry_allowed=false cause={e}"));
            }
        }
    }
}
