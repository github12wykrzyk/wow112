use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

#[path = "../auth.rs"]
mod auth;
#[path = "../tele_party_observer.rs"]
mod tele_party_observer;
#[path = "../tele_party_seq.rs"]
mod tele_party_seq;
#[path = "../wire_build.rs"]
mod wire_build;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const DEFAULT_RECONNECT_LIMIT: u32 = 60;
const LOGIN_WATCHDOG_MS: u64 = 3000;

fn connect_with_login_watchdog(addr: &str, label: &str) -> Result<TcpStream, String> {
    let addrs = addr
        .to_socket_addrs()
        .map_err(|e| format!("{label} resolve {addr} failed: {e}"))?
        .collect::<Vec<_>>();
    if addrs.is_empty() {
        return Err(format!("{label} resolve {addr} returned no addresses"));
    }
    let mut last_error = None;
    for socket in addrs {
        match TcpStream::connect_timeout(&socket, Duration::from_millis(LOGIN_WATCHDOG_MS)) {
            Ok(stream) => {
                println!("[LOGIN-WATCHDOG] {label} connected addr={socket} timeout_ms={LOGIN_WATCHDOG_MS}");
                return Ok(stream);
            }
            Err(error) => {
                last_error = Some(format!("{error}"));
            }
        }
    }
    Err(format!(
        "TimedOut login watchdog label={label} addr={addr} timeout_ms={LOGIN_WATCHDOG_MS} last={}",
        last_error.unwrap_or_else(|| "unknown".to_string())
    ))
}

fn arm_login_watchdog(stream: &TcpStream, label: &str) -> Result<(), String> {
    let timeout = Some(Duration::from_millis(LOGIN_WATCHDOG_MS));
    stream
        .set_read_timeout(timeout)
        .map_err(|e| format!("{label} set login read watchdog failed: {e}"))?;
    stream
        .set_write_timeout(timeout)
        .map_err(|e| format!("{label} set login write watchdog failed: {e}"))?;
    println!("[LOGIN-WATCHDOG] {label} io_timeout_ms={LOGIN_WATCHDOG_MS}");
    Ok(())
}

fn publish_runner_state(state: &str, detail: &str) {
    let Ok(path) = env::var("WOW112_RUNNER_STATE_FILE") else {
        return;
    };
    if path.trim().is_empty() {
        return;
    }
    let session = env::var("WOW112_RUNNER_SESSION_ATTEMPT").unwrap_or_else(|_| "0".to_string());
    let safe_detail = detail.replace('\r', " ").replace('\n', " ");
    let body = format!("state={state}\nsession={session}\ndetail={safe_detail}\n");
    let _ = fs::write(path, body);
}

mod tele06a {
    include!("../world_tele.rs");

    use super::*;
    include!("../tele10_trade_receiver_runtime.rs");

    const CMSG_GROUP_INVITE_OPCODE: u32 = 0x006E;
    const CMSG_GROUP_DISBAND_OPCODE: u32 = 0x007B;
    const SMSG_GROUP_LIST_OPCODE: u16 = 0x007D;
    const CMSG_CAST_SPELL_OPCODE: u32 = 0x012E;
    const CMSG_SET_SELECTION_OPCODE: u32 = 0x013D;
    const SMSG_CAST_RESULT_OPCODE: u16 = 0x0130;
    const SMSG_SPELL_START_OPCODE: u16 = 0x0131;
    const SMSG_SPELL_GO_OPCODE: u16 = 0x0132;
    const SMSG_SPELL_FAILURE_OPCODE: u16 = 0x0133;
    const RITUAL_OF_SUMMONING_SPELL_ID: u32 = 698;
    const TARGET_FLAG_UNIT: u16 = 0x0002;

    static RESET_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static CAST_ATTEMPTED: AtomicBool = AtomicBool::new(false);

    fn env_csv(name: &str) -> Vec<String> {
        std::env::var(name)
            .ok()
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    }

    fn configured_target_name() -> Result<String, String> {
        std::env::var("WOW112_RITUAL_TARGET_NAME")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "missing WOW112_RITUAL_TARGET_NAME".to_string())
    }

    fn encode_group_invite_target(target: &str) -> Result<Vec<u8>, String> {
        let target = target.trim();
        if target.is_empty() {
            return Err("invite target is empty".to_string());
        }
        if target.as_bytes().contains(&0) {
            return Err("invite target contains NUL".to_string());
        }
        if target.len() > 64 {
            return Err(format!("invite target too long: {} bytes", target.len()));
        }
        let mut payload = Vec::with_capacity(target.len() + 1);
        payload.extend_from_slice(target.as_bytes());
        payload.push(0);
        Ok(payload)
    }

    fn encode_packed_guid(guid: u64) -> Vec<u8> {
        let bytes = guid.to_le_bytes();
        let mut mask = 0u8;
        let mut payload = Vec::with_capacity(9);
        payload.push(0);
        for (index, value) in bytes.iter().enumerate() {
            if *value != 0 {
                mask |= 1u8 << index;
                payload.push(*value);
            }
        }
        payload[0] = mask;
        payload
    }

    fn encode_ritual_cast() -> Vec<u8> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&RITUAL_OF_SUMMONING_SPELL_ID.to_le_bytes());
        payload.extend_from_slice(&0u16.to_le_bytes());
        payload
    }

    fn maybe_reset_group(stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<(), String> {
        let enabled = std::env::var("WOW112_TELE_RESET_GROUP")
            .ok()
            .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        if !enabled {
            println!("[TELE-06A-RESET] disabled");
            return Ok(());
        }
        if RESET_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!("[TELE-06A-RESET] skip_already_attempted retry_allowed=false");
            return Ok(());
        }
        write_encrypted_raw(stream, crypto.encrypter(), CMSG_GROUP_DISBAND_OPCODE, &[])?;
        println!("[TELE-06A-RESET-TX] opcode=0x007B result=attempted_once retry_allowed=false");
        thread::sleep(Duration::from_millis(1200));
        Ok(())
    }

    static PARTY: std::sync::OnceLock<std::sync::Mutex<crate::tele_party_seq::PartySeq>> =
        std::sync::OnceLock::new();
    static PARTY_EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

    fn party_clock_ms() -> u64 {
        PARTY_EPOCH.get_or_init(Instant::now).elapsed().as_millis() as u64
    }

    fn party_lock(
    ) -> Result<std::sync::MutexGuard<'static, crate::tele_party_seq::PartySeq>, String> {
        PARTY
            .get()
            .ok_or_else(|| "party sequence not registered".to_string())?
            .lock()
            .map_err(|_| "party sequence lock poisoned".to_string())
    }

    /// Registers the sequential party engine ONCE per process. The engine lives in a
    /// static so a reconnect can never replay an invite (all guards stay committed).
    fn register_party_sequence(targets: &[String]) -> Result<(), String> {
        if targets.is_empty() {
            return Err("WOW112_TELE_INVITE_LIST is empty".to_string());
        }
        let timeout_seconds = std::env::var("WOW112_TELE_INVITE_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.trim().parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(45);
        let engine = crate::tele_party_seq::PartySeq::new(targets, timeout_seconds * 1000);
        if PARTY.set(std::sync::Mutex::new(engine)).is_err() {
            println!("[TELE-06A-PARTY] sequence=skip_already_registered retry_allowed=false");
            return Ok(());
        }
        PARTY_EPOCH.get_or_init(Instant::now);
        println!(
            "[TELE-06A-PARTY] mode=sequential members={:?} per_member_timeout={}s retry_allowed=false",
            targets, timeout_seconds
        );
        Ok(())
    }

    /// One engine step. Ok(true) = full roster confirmed sequentially.
    /// The member is marked INVITE_SENT inside next_action BEFORE the socket write.
    fn party_step(stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<bool, String> {
        use crate::tele_party_seq::{Action, FailReason};
        let mut party = party_lock()?;
        let action = party.next_action(party_clock_ms());
        match action {
            Action::Wait => Ok(false),
            Action::Done => {
                for line in party.report() {
                    println!("{line}");
                }
                Ok(true)
            }
            Action::SendInvite { index, name } => {
                let payload = encode_group_invite_target(&name)?;
                println!(
                    "[TELE-06A-PARTY] member={:?} state=INVITE_SENT guard_committed_before_write=true",
                    name
                );
                if let Err(error) = write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_GROUP_INVITE_OPCODE,
                    &payload,
                ) {
                    party.on_write_uncertain(index);
                    return Err(format!(
                        "TELE06A_INVITE_MUTATION_UNCERTAIN index={index} target={name:?} retry_allowed=false cause={error}"
                    ));
                }
                println!(
                    "[TELE-06A-INVITE-TX] index={} target={:?} opcode=0x006E mode=sequential result=attempted_once retry_allowed=false",
                    index + 1,
                    name
                );
                Ok(false)
            }
            Action::Fail(reason) => {
                for line in party.report() {
                    println!("{line}");
                }
                if matches!(reason, FailReason::WriteUncertain { .. }) {
                    Err(format!(
                        "TELE06A_INVITE_MUTATION_UNCERTAIN {}",
                        reason.describe()
                    ))
                } else {
                    Err(format!("TELE06A_ROSTER_TIMEOUT {}", reason.describe()))
                }
            }
        }
    }

    fn party_on_group_list(names: &[String]) {
        if let Ok(mut party) = party_lock() {
            party.on_group_list(names);
        }
    }

    fn party_on_packet(opcode: u16, payload: &[u8]) {
        let Ok(mut party) = party_lock() else {
            return;
        };
        if opcode == crate::tele_party_seq::SMSG_PARTY_COMMAND_RESULT_OPCODE {
            match party.on_party_command_result(payload) {
                Ok(parsed) => println!(
                    "[TELE-06A-PARTY] command_result op={} member={:?} result=0x{:02X} {}",
                    parsed.operation,
                    parsed.member,
                    parsed.result,
                    crate::tele_party_seq::party_result_name(parsed.result)
                ),
                Err(error) => {
                    println!("[TELE-06A-PARTY-DIAG] command_result parse failed: {error}")
                }
            }
        } else if opcode == crate::tele_party_seq::SMSG_GROUP_DECLINE_OPCODE {
            match party.on_group_decline(payload) {
                Ok(name) => println!("[TELE-06A-PARTY] group_decline member={name:?}"),
                Err(error) => println!("[TELE-06A-PARTY-DIAG] group_decline parse failed: {error}"),
            }
        }
    }

    fn send_ritual_cast_once(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        target_name: &str,
        target_guid: u64,
    ) -> Result<(), String> {
        let payload = encode_ritual_cast();
        if CAST_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!("[TELE-06A-CAST] result=skip_already_attempted retry_allowed=false");
            return Ok(());
        }

        if target_guid == 0 {
            return Err("ritual selection guid must not be zero".to_string());
        }
        let selection_payload = target_guid.to_le_bytes();
        write_encrypted_raw(
            stream,
            crypto.encrypter(),
            CMSG_SET_SELECTION_OPCODE,
            &selection_payload,
        )
        .map_err(|error| {
            format!(
                "TELE06A_SELECTION_MUTATION_UNCERTAIN target={target_name:?} guid=0x{target_guid:016X} retry_allowed=false cause={error}"
            )
        })?;
        println!(
            "[TELE-06A-SELECTION-TX] opcode=0x013D target={:?} target_guid=0x{:016X} bytes=8 result=attempted_once retry_allowed=false",
            target_name,
            target_guid
        );
        thread::sleep(Duration::from_millis(150));

        println!(
            "[TELE-06A-RITUAL] state=CAST_ATTEMPTED spell={} target={:?} target_guid=0x{:016X} target_mode=selection cast_target_mask=0x0000 shard_precheck=server_authoritative",
            RITUAL_OF_SUMMONING_SPELL_ID,
            target_name,
            target_guid
        );
        write_encrypted_raw(
            stream,
            crypto.encrypter(),
            CMSG_CAST_SPELL_OPCODE,
            &payload,
        )
        .map_err(|error| {
            format!(
                "TELE06A_CAST_MUTATION_UNCERTAIN spell={} target={target_name:?} guid=0x{target_guid:016X} retry_allowed=false cause={error}",
                RITUAL_OF_SUMMONING_SPELL_ID
            )
        })?;
        publish_runner_state(
            "CAST_SENT",
            "spell=698 target_mode=selection target_mask=0x0000",
        );
        println!(
            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} target_mode=selection target_mask=0x0000 bytes={} result=attempted_once retry_allowed=false",
            RITUAL_OF_SUMMONING_SPELL_ID,
            target_name,
            target_guid,
            payload.len()
        );
        Ok(())
    }

    fn roster_from_group_list(payload: &[u8]) -> Result<HashMap<String, u64>, String> {
        match parse_raw_server_message(SMSG_GROUP_LIST_OPCODE, payload)? {
            ServerOpcodeMessage::SMSG_GROUP_LIST(group) => Ok(group
                .members
                .iter()
                .map(|member| (member.name.to_ascii_lowercase(), member.guid.guid()))
                .collect()),
            other => Err(format!("unexpected group-list parse: {other:?}")),
        }
    }

    fn drive_roster_and_ritual(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        expected_members: &[String],
        target_name: &str,
    ) -> Result<(), String> {
        let previous_timeout = stream.read_timeout().ok().flatten();
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|e| format!("set TELE-06A read timeout failed: {e}"))?;

        let mut last_roster: HashMap<String, u64> = HashMap::new();
        let target_lower = target_name.to_ascii_lowercase();
        let roster_deadline = Instant::now() + Duration::from_secs(300);
        let mut cast_deadline: Option<Instant> = None;
        let mut cast_started = false;
        let mut last_ping = Instant::now();
        let mut ping_sequence = 1u32;
        let mut awaiting_pong: Option<(u32, Instant)> = None;

        println!(
            "[TELE-06A-ROSTER] waiting expected={:?} ritual_target={:?} mode=sequential overall_deadline=300s",
            expected_members, target_name
        );

        loop {
            if cast_deadline.is_none() && Instant::now() >= roster_deadline {
                let _ = stream.set_read_timeout(previous_timeout);
                return Err("TELE06A_ROSTER_TIMEOUT no cast sent".to_string());
            }
            if let Some(deadline) = cast_deadline {
                if Instant::now() >= deadline {
                    println!("[TELE-06A-RITUAL] outcome=TIMEOUT_UNCERTAIN retry_allowed=false observer_continues=true");
                    let _ = stream.set_read_timeout(previous_timeout);
                    return Ok(());
                }
            }

            if cast_deadline.is_none() && party_step(stream, crypto)? {
                let target_guid = *last_roster
                    .get(&target_lower)
                    .ok_or_else(|| format!("target {target_name:?} missing despite roster gate"))?;
                println!(
                    "[TELE-06A-ROSTER] PASS target={:?} target_guid=0x{:016X}",
                    target_name, target_guid
                );
                publish_runner_state("ROSTER_PASS", "full roster confirmed sequentially");
                send_ritual_cast_once(stream, crypto, target_name, target_guid)?;
                cast_deadline = Some(Instant::now() + Duration::from_secs(25));
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
                println!("[TELE-06A] keepalive ping sequence={ping_sequence}");
                awaiting_pong = Some((ping_sequence, Instant::now()));
                ping_sequence = ping_sequence.wrapping_add(1);
                last_ping = Instant::now();
            }

            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if opcode == SMSG_PONG_OPCODE {
                        if payload.len() >= 4 {
                            let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            println!("[TELE-06A] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                            }
                        }
                        continue;
                    }

                    if opcode == SMSG_GROUP_LIST_OPCODE {
                        crate::tele_party_observer::inspect_party_packet(opcode, &payload);
                        if cast_deadline.is_none() {
                            match roster_from_group_list(&payload) {
                                Ok(roster) => {
                                    let names = roster.keys().cloned().collect::<Vec<_>>();
                                    party_on_group_list(&names);
                                    println!(
                                        "[TELE-06A-ROSTER] observed={} members={:?}",
                                        roster.len(),
                                        names
                                    );
                                    last_roster = roster;
                                }
                                Err(error) => println!("[TELE-06A-ROSTER-DIAG] {error}"),
                            }
                        }
                        continue;
                    }

                    if cast_deadline.is_none() {
                        party_on_packet(opcode, &payload);
                    }
                    if crate::tele_party_observer::inspect_party_packet(opcode, &payload) {
                        continue;
                    }

                    if matches!(
                        opcode,
                        SMSG_CAST_RESULT_OPCODE
                            | SMSG_SPELL_START_OPCODE
                            | SMSG_SPELL_GO_OPCODE
                            | SMSG_SPELL_FAILURE_OPCODE
                    ) {
                        let parsed = parse_raw_server_message(opcode, &payload)
                            .map(|message| format!("{message:?}"))
                            .unwrap_or_else(|error| format!("PARSE_ERROR {error}"));
                        println!(
                            "[TELE-06A-SPELL-RX] opcode=0x{opcode:04X} payload={} parsed={parsed}",
                            payload.len()
                        );
                        if opcode == SMSG_CAST_RESULT_OPCODE && payload.len() >= 6 {
                            let raw_spell = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            let status = payload[4];
                            let reason = payload[5];
                            let reason_name = match reason {
                                0x09 => "BAD_IMPLICIT_TARGETS",
                                0x0A => "BAD_TARGETS",
                                0x13 => "CASTER_DEAD",
                                0x3C => "NOT_READY",
                                0x3E => "NOT_STANDING",
                                0x4D => "NO_POWER",
                                0x59 => "OUT_OF_RANGE",
                                0x5C => "REAGENTS",
                                0x61 => "SPELL_IN_PROGRESS",
                                0x65 => "TARGETS_DEAD",
                                0x66 => "TARGET_AFFECTING_COMBAT",
                                _ => "OTHER",
                            };
                            let raw_hex = payload
                                .iter()
                                .map(|byte| format!("{byte:02X}"))
                                .collect::<Vec<_>>()
                                .join(" ");
                            println!("[TELE-06A-CAST-RESULT-RAW] spell={} status={} reason=0x{:02X} reason_name={} raw={}", raw_spell, status, reason, reason_name, raw_hex);
                        }
                        let is_ritual = parsed.contains("698") || parsed.contains("0x02BA");
                        if !is_ritual {
                            continue;
                        }
                        match opcode {
                            SMSG_SPELL_START_OPCODE => {
                                let target_guid =
                                    *last_roster.get(&target_lower).ok_or_else(|| {
                                        format!("target {target_name:?} missing at ritual start")
                                    })?;
                                let summon_id =
                                    tele10_record_ritual_started(target_name, target_guid)?;
                                println!("[TELE10-LEDGER] ritual_start summon_id={summon_id}");
                                cast_started = true;
                                publish_runner_state(
                                    "PASS_RITUAL_STARTED",
                                    "SMSG_SPELL_START spell=698",
                                );
                                println!("[TELE-06A-RITUAL] LIVE_CAST_START_PASS spell=698 retry_allowed=false");
                                let _ = stream.set_read_timeout(previous_timeout);
                                return Ok(());
                            }
                            SMSG_SPELL_GO_OPCODE => {
                                let target_guid =
                                    *last_roster.get(&target_lower).ok_or_else(|| {
                                        format!("target {target_name:?} missing at ritual go")
                                    })?;
                                let summon_id =
                                    tele10_record_ritual_started(target_name, target_guid)?;
                                println!("[TELE10-LEDGER] ritual_go summon_id={summon_id}");
                                publish_runner_state(
                                    "PASS_RITUAL_STARTED",
                                    "SMSG_SPELL_GO spell=698",
                                );
                                println!("[TELE-06A-RITUAL] LIVE_CAST_GO_PASS spell=698 retry_allowed=false");
                                let _ = stream.set_read_timeout(previous_timeout);
                                return Ok(());
                            }
                            SMSG_CAST_RESULT_OPCODE | SMSG_SPELL_FAILURE_OPCODE => {
                                publish_runner_state(
                                    "FAIL_SERVER_REJECT",
                                    "spell=698 see raw cast-result log for reason",
                                );
                                println!(
                                    "[TELE-06A-RITUAL] SERVER_REJECT spell=698 cast_started={} retry_allowed=false details={}",
                                    cast_started, parsed
                                );
                                let _ = stream.set_read_timeout(previous_timeout);
                                return Ok(());
                            }
                            _ => {}
                        }
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

    pub fn login_tele06a(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: Option<&str>,
        soak_seconds: u64,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_millis(LOGIN_WATCHDOG_MS)))
            .map_err(|e| format!("set world read timeout failed: {e}"))?;

        let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
            .map_err(|e| format!("read world auth challenge failed: {e:?}"))?;
        let seed = ProofSeed::new();
        let seed_value = seed.seed();
        let normalized_username = NormalizedString::new(username)
            .map_err(|e| format!("invalid account name for world auth: {e:?}"))?;
        let (client_proof, mut crypto) = seed.into_client_header_crypto(
            &normalized_username,
            session_key,
            challenge.server_seed,
        );

        let auth_session = CMSG_AUTH_SESSION {
            build: OCTOWOW_WORLD_BUILD,
            server_id: server_id as u32,
            username: username.to_string(),
            client_seed: seed_value,
            client_proof,
            addon_info: octo_fingerprint_addons(),
        };
        let mut auth_wire = Vec::new();
        auth_session
            .write_unencrypted_client(&mut auth_wire)
            .map_err(|e| format!("encode world auth session failed: {e:?}"))?;
        stream
            .write_all(&auth_wire)
            .map_err(|e| format!("write world auth session failed: {e:?}"))?;

        world_diag_peek(stream, "auth-response-raw", Duration::from_millis(1500));
        skip_octowow_addon_info(stream, crypto.decrypter())?;
        let auth_response = {
            let mut found = None;
            for index in 0..16usize {
                let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                    .map_err(|e| format!("read world pre-auth opcode failed: {e:?}"))?;
                match opcode {
                    ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) => {
                        found = Some(response);
                        break;
                    }
                    other => {
                        if index < 8 {
                            println!("[WORLD] pre-auth rx[{index}] {other:?}");
                        }
                    }
                }
            }
            found.ok_or_else(|| "world auth response not received within 16 packets".to_string())?
        };
        if !matches!(*auth_response, SMSG_AUTH_RESPONSE::AuthOk { .. }) {
            return Err(format!("world auth rejected: {auth_response:?}"));
        }
        println!("[WORLD] auth PASS world-build={OCTOWOW_WORLD_BUILD}");

        CMSG_CHAR_ENUM {}
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|e| format!("write character enum request failed: {e:?}"))?;
        let characters =
            expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read character enum failed: {e:?}"))?;
        if characters.characters.is_empty() {
            return Err("account has no characters".to_string());
        }
        println!("[WORLD] characters={}", characters.characters.len());
        for (index, character) in characters.characters.iter().enumerate() {
            println!("[WORLD] character[{index}] name={}", character.name);
        }
        let selected = match character_name {
            Some(wanted) => characters
                .characters
                .iter()
                .find(|character| character.name.eq_ignore_ascii_case(wanted))
                .ok_or_else(|| format!("character not found: {wanted}"))?,
            None => &characters.characters[0],
        };
        println!("[WORLD] logging character={}", selected.name);
        tele_trace::set_local_guid(selected.guid.guid());
        CMSG_PLAYER_LOGIN {
            guid: selected.guid,
        }
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write player login failed: {e:?}"))?;

        let mut login_verified = false;
        for index in 0..256usize {
            let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;
            if index < 24 {
                println!("[WORLD] rx[{index}] {opcode:?}");
            }
            if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
                println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS");
                login_verified = true;
                break;
            }
        }
        if !login_verified {
            return Err(
                "world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets"
                    .to_string(),
            );
        }

        maybe_reset_group(stream, &mut crypto)?;
        let invite_targets = env_csv("WOW112_TELE_INVITE_LIST");
        let target_name = configured_target_name()?;
        register_party_sequence(&invite_targets)?;
        drive_roster_and_ritual(stream, &mut crypto, &invite_targets, &target_name)?;

        println!("[TELE-06A] cast checkpoint complete; TELE10 trade receiver active");
        tele10_trade_receiver_loop(stream, &mut crypto, soak_seconds, &target_name)?;
        println!("[TELE-06A] RUNTIME LOOP PASS");
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn ritual_wire_contract() {
            assert_eq!(CMSG_SET_SELECTION_OPCODE, 0x013D);
            assert_eq!(CMSG_CAST_SPELL_OPCODE, 0x012E);
            assert_eq!(RITUAL_OF_SUMMONING_SPELL_ID, 698);
            let guid = 0x0000_0000_3B9F_74DEu64;
            assert_eq!(
                guid.to_le_bytes(),
                [0xDE, 0x74, 0x9F, 0x3B, 0x00, 0x00, 0x00, 0x00]
            );
            let payload = encode_ritual_cast();
            assert_eq!(payload.len(), 6);
            assert_eq!(&payload[0..4], &698u32.to_le_bytes());
            assert_eq!(&payload[4..6], &0u16.to_le_bytes());
        }

        #[test]
        fn packed_guid_skips_zero_bytes() {
            assert_eq!(encode_packed_guid(0x0000_0000_0000_00FF), vec![0x01, 0xFF]);
            assert_eq!(
                encode_packed_guid(0x0000_0000_0100_0001),
                vec![0x09, 0x01, 0x01]
            );
        }
    }
}

fn parse_env_u64(name: &str, default_value: u64) -> Result<u64, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u64>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn parse_env_u32(name: &str, default_value: u32) -> Result<u32, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u32>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn is_transient_network_error(error: &str) -> bool {
    [
        "ConnectionReset",
        "Connection reset by peer",
        "BrokenPipe",
        "UnexpectedEof",
        "TimedOut",
        "timed out",
        "WouldBlock",
        "ConnectionRefused",
        "connection refused",
        "world socket closed",
        "world keepalive pong timeout",
        "10060",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE-06A] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password =
        env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let character_name = env::var("WOW112_CHARACTER").ok();
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);
    let soak_seconds = parse_env_u64("WOW112_SOAK_SECONDS", 0)?;
    let reconnect_limit = parse_env_u32("WOW112_RECONNECT_LIMIT", DEFAULT_RECONNECT_LIMIT)?.max(1);
    let reconnect_delay_ms = parse_env_u64("WOW112_RECONNECT_DELAY_MS", 0)?;
    let invite_list = env::var("WOW112_TELE_INVITE_LIST").unwrap_or_default();
    let ritual_target = env::var("WOW112_RITUAL_TARGET_NAME").unwrap_or_default();

    println!(
        "[WOW112-HEADLESS] binary-build=5875 wire-build={} protocol=vanilla target=windows-headless mode=tele06a-ritual-live",
        OCTOWOW_WIRE_BUILD
    );
    println!(
        "[TELE-06A] account={} character={} invite_list={:?} ritual_target={:?} reset_group={} reconnect_limit={} cast_retry=disabled portal_use=disabled shard_precheck=server_authoritative",
        username,
        character_name.as_deref().unwrap_or("first"),
        invite_list,
        ritual_target,
        env::var("WOW112_TELE_RESET_GROUP").unwrap_or_else(|_| "0".to_string()),
        reconnect_limit
    );

    for attempt in 1..=reconnect_limit {
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        env::set_var("WOW112_RUNNER_SESSION_ATTEMPT", attempt.to_string());
        publish_runner_state("CONNECTING", "new session attempt");
        match run_session(
            &auth_addr,
            realm_index,
            &username,
            &password,
            character_name.as_deref(),
            soak_seconds,
        ) {
            Ok(()) => {
                println!("[RESILIENCE] TELE-06A PASS attempts={attempt}");
                return Ok(());
            }
            Err(error) if is_transient_network_error(&error) && attempt < reconnect_limit => {
                let display_error = if error.contains("10060") {
                    "network timeout (WinSock 10060: remote host did not respond)".to_string()
                } else {
                    error.clone()
                };
                println!("[RESILIENCE] transient network failure: {display_error}");
                println!(
                    "[RESILIENCE] reconnecting; reset/invite/cast one-shot guards remain committed"
                );
                if reconnect_delay_ms != 0 {
                    thread::sleep(Duration::from_millis(reconnect_delay_ms));
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(format!(
        "TELE-06A reconnect limit exhausted after {reconnect_limit} attempts"
    ))
}

fn run_session(
    auth_addr: &str,
    realm_index: usize,
    username: &str,
    password: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
) -> Result<(), String> {
    println!("[AUTH] connecting to {auth_addr}");
    let mut auth_stream = connect_with_login_watchdog(auth_addr, "AUTH")?;
    arm_login_watchdog(&auth_stream, "AUTH")?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, username, password)?;
    if realms.realms.is_empty() {
        return Err("auth succeeded but realm list is empty".to_string());
    }
    println!("[AUTH] realms={}", realms.realms.len());
    for (index, realm) in realms.realms.iter().enumerate() {
        println!(
            "[AUTH] realm[{index}] name={} address={} id={}",
            realm.name, realm.address, realm.realm_id
        );
    }
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} is out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    println!(
        "[WORLD] connecting realm={} id={} address={}",
        realm.name, realm.realm_id, world_addr
    );
    let mut world_stream = connect_with_login_watchdog(&world_addr, "WORLD")?;
    arm_login_watchdog(&world_stream, "WORLD")?;

    tele06a::login_tele06a(
        &mut world_stream,
        session_key,
        realm.realm_id,
        username,
        character_name,
        soak_seconds,
    )
}
