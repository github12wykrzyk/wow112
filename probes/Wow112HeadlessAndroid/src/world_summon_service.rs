include!("world.rs");

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use wow_world_messages::vanilla::SMSG_MESSAGECHAT_ChatType;
use wow112_headless_android_probe::summon_service_core::{RequestPhase, ServiceState};
use wow112_headless_android_probe::summon_service_runtime::{
    ServiceRuntimeConfig, SummonServiceRuntime,
};
use wow112_headless_android_probe::tele_party_seq::{Action as PartyAction, PartySeq};

include!("tele10_trade_receiver_runtime.rs");

const SMSG_MESSAGECHAT_OPCODE: u16 = 0x0096;
const CMSG_MESSAGECHAT_OPCODE: u32 = 0x0095;
const CMSG_NAME_QUERY_OPCODE: u32 = 0x0050;
const SMSG_NAME_QUERY_RESPONSE_OPCODE: u16 = 0x0051;
const CHAT_TYPE_WHISPER: u32 = 6;
const LANGUAGE_UNIVERSAL: u32 = 0;

const CMSG_GROUP_INVITE_OPCODE: u32 = 0x006E;
const CMSG_GROUP_DISBAND_OPCODE: u32 = 0x007B;
const SMSG_GROUP_LIST_OPCODE: u16 = 0x007D;
const SMSG_GROUP_DECLINE_OPCODE: u16 = 0x0074;
const SMSG_PARTY_COMMAND_RESULT_OPCODE: u16 = 0x007F;

const CMSG_CAST_SPELL_OPCODE: u32 = 0x012E;
const CMSG_SET_SELECTION_OPCODE: u32 = 0x013D;
const SMSG_CAST_RESULT_OPCODE: u16 = 0x0130;
const SMSG_SPELL_START_OPCODE: u16 = 0x0131;
const SMSG_SPELL_GO_OPCODE: u16 = 0x0132;
const SMSG_SPELL_FAILURE_OPCODE: u16 = 0x0133;
const RITUAL_OF_SUMMONING_SPELL_ID: u32 = 698;

const DEFAULT_INVITE_TIMEOUT_MS: u64 = 45_000;
const DEFAULT_PAYMENT_GRACE_MS: u64 = 45_000;
const GROUP_RESET_SETTLE_MS: u64 = 1_200;

#[derive(Debug)]
enum DriverPhase {
    ResetGroup { sent_at_ms: Option<u64> },
    Party { seq: PartySeq },
    RitualWaiting {
        target_guid: u64,
        summon_id: Option<String>,
    },
    AwaitingPayment {
        since_ms: u64,
        summon_id: Option<String>,
    },
}

#[derive(Debug)]
struct ActiveDriver {
    request_id: String,
    customer: String,
    destination: String,
    trigger_message: String,
    phase: DriverPhase,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(default)
}

fn env_csv(name: &str) -> Vec<String> {
    std::env::var(name)
        .ok()
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn service_root() -> PathBuf {
    std::env::var("WOW112_SUMMON_SERVICE_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("summon_service_v1"))
}

fn configured_destination() -> Option<String> {
    std::env::var("WOW112_TELE_DESTINATION")
        .ok()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
}

fn configured_helpers() -> Vec<String> {
    let mut helpers = env_csv("WOW112_SUMMON_HELPERS");
    if helpers.is_empty() {
        helpers = env_csv("WOW112_TELE_INVITE_LIST");
    }
    helpers
}

fn encode_group_invite_target(target: &str) -> Result<Vec<u8>, String> {
    let target = target.trim();
    if target.is_empty() || target.as_bytes().contains(&0) || target.len() > 64 {
        return Err(format!("invalid invite target={target:?}"));
    }
    let mut payload = Vec::with_capacity(target.len() + 1);
    payload.extend_from_slice(target.as_bytes());
    payload.push(0);
    Ok(payload)
}

fn encode_ritual_cast() -> Vec<u8> {
    let mut payload = Vec::with_capacity(6);
    payload.extend_from_slice(&RITUAL_OF_SUMMONING_SPELL_ID.to_le_bytes());
    payload.extend_from_slice(&0u16.to_le_bytes());
    payload
}

fn read_cstring(payload: &[u8], start: usize) -> Result<(String, usize), String> {
    let rest = payload
        .get(start..)
        .ok_or_else(|| format!("cstring offset out of range: {start}"))?;
    let nul = rest
        .iter()
        .position(|value| *value == 0)
        .ok_or_else(|| format!("unterminated cstring at offset {start}"))?;
    Ok((String::from_utf8_lossy(&rest[..nul]).into_owned(), start + nul + 1))
}

fn parse_name_query_response(payload: &[u8]) -> Result<(u64, String), String> {
    if payload.len() < 10 {
        return Err(format!("name response too short: {}", payload.len()));
    }
    let guid = u64::from_le_bytes(payload[0..8].try_into().unwrap());
    let (name, next) = read_cstring(payload, 8)?;
    let (_realm, _) = read_cstring(payload, next)?;
    if name.is_empty() {
        return Err("empty name query response".to_string());
    }
    Ok((guid, name))
}

fn send_name_query(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    guid: u64,
) -> Result<(), String> {
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_NAME_QUERY_OPCODE,
        &guid.to_le_bytes(),
    )
}

fn send_whisper(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    target: &str,
    text: &str,
) -> Result<(), String> {
    if target.is_empty() || target.as_bytes().contains(&0) || text.is_empty() || text.len() > 255 {
        return Err("invalid service whisper".to_string());
    }
    let mut payload = Vec::with_capacity(10 + target.len() + text.len());
    payload.extend_from_slice(&CHAT_TYPE_WHISPER.to_le_bytes());
    payload.extend_from_slice(&LANGUAGE_UNIVERSAL.to_le_bytes());
    payload.extend_from_slice(target.as_bytes());
    payload.push(0);
    payload.extend_from_slice(text.as_bytes());
    payload.push(0);
    write_encrypted_raw(stream, crypto.encrypter(), CMSG_MESSAGECHAT_OPCODE, &payload)
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

fn request_driver(runtime: &SummonServiceRuntime, request_id: &str) -> Result<ActiveDriver, String> {
    let record = runtime
        .request(request_id)
        .ok_or_else(|| format!("request missing id={request_id}"))?;
    let phase = match record.phase {
        RequestPhase::Inviting => DriverPhase::ResetGroup { sent_at_ms: None },
        RequestPhase::AwaitingPayment => DriverPhase::AwaitingPayment {
            since_ms: now_ms(),
            summon_id: None,
        },
        other => {
            return Err(format!(
                "cannot create active driver request_id={request_id} phase={other:?}"
            ))
        }
    };
    Ok(ActiveDriver {
        request_id: record.request_id.clone(),
        customer: record.customer.clone(),
        destination: record.destination.clone(),
        trigger_message: record.trigger_message.clone(),
        phase,
    })
}

fn reconcile_driver(
    runtime: &mut SummonServiceRuntime,
    driver: &mut Option<ActiveDriver>,
) -> Result<(), String> {
    if driver.is_none() {
        if let Some(request_id) = runtime.active_request_id().map(ToString::to_string) {
            *driver = Some(request_driver(runtime, &request_id)?);
            return Ok(());
        }
        if runtime.core().state() == ServiceState::BlockedUncertain {
            return Ok(());
        }
        if let Some(request_id) = runtime.start_next(now_ms())? {
            *driver = Some(request_driver(runtime, &request_id)?);
        }
    }
    Ok(())
}

fn drive_active(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    runtime: &mut SummonServiceRuntime,
    driver: &mut Option<ActiveDriver>,
    roster: &HashMap<String, u64>,
    helpers: &[String],
    invite_timeout_ms: u64,
    payment_grace_ms: u64,
) -> Result<(), String> {
    reconcile_driver(runtime, driver)?;
    let Some(active) = driver.as_mut() else { return Ok(()); };
    let now = now_ms();

    match &mut active.phase {
        DriverPhase::ResetGroup { sent_at_ms } => {
            if sent_at_ms.is_none() {
                println!("[SUMMON-SERVICE] request={} state=RESET_GROUP_COMMITTED retry_allowed=false", active.request_id);
                if let Err(error) = write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_GROUP_DISBAND_OPCODE,
                    &[],
                ) {
                    runtime.mark_uncertain(
                        &active.request_id,
                        &format!("group_reset_socket_uncertain:{error}"),
                        now,
                    )?;
                    return Err(format!("SUMMON_GROUP_RESET_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                }
                *sent_at_ms = Some(now);
                return Ok(());
            }
            if now.saturating_sub(sent_at_ms.unwrap_or(now)) < GROUP_RESET_SETTLE_MS {
                return Ok(());
            }
            let mut members = vec![active.customer.clone()];
            for helper in helpers {
                if !helper.eq_ignore_ascii_case(&active.customer)
                    && !members.iter().any(|value| value.eq_ignore_ascii_case(helper))
                {
                    members.push(helper.clone());
                }
            }
            active.phase = DriverPhase::Party {
                seq: PartySeq::new(&members, invite_timeout_ms),
            };
        }
        DriverPhase::Party { seq } => match seq.next_action(now) {
            PartyAction::Wait => {}
            PartyAction::SendInvite { index, name } => {
                let payload = encode_group_invite_target(&name)?;
                println!("[SUMMON-SERVICE] request={} invite={:?} state=COMMITTED retry_allowed=false", active.request_id, name);
                if let Err(error) = write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_GROUP_INVITE_OPCODE,
                    &payload,
                ) {
                    let _ = seq.on_write_uncertain(index);
                    runtime.mark_uncertain(
                        &active.request_id,
                        &format!("invite_socket_uncertain target={name:?}:{error}"),
                        now,
                    )?;
                    return Err(format!("SUMMON_INVITE_MUTATION_UNCERTAIN retry_allowed=false target={name:?} cause={error}"));
                }
            }
            PartyAction::Fail(reason) => {
                runtime.mark_terminal_failure(&active.request_id, &reason.describe(), now)?;
                *driver = None;
            }
            PartyAction::Done => {
                let target_guid = roster
                    .get(&active.customer.to_ascii_lowercase())
                    .copied()
                    .ok_or_else(|| format!("target {:?} missing after party convergence", active.customer))?;
                runtime.mark_ritual_committed(
                    &active.request_id,
                    &format!("ritual:{}", active.request_id),
                )?;
                if let Err(error) = write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_SET_SELECTION_OPCODE,
                    &target_guid.to_le_bytes(),
                ) {
                    runtime.mark_uncertain(
                        &active.request_id,
                        &format!("selection_socket_uncertain:{error}"),
                        now,
                    )?;
                    return Err(format!("SUMMON_SELECTION_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                }
                thread::sleep(Duration::from_millis(150));
                if let Err(error) = write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_CAST_SPELL_OPCODE,
                    &encode_ritual_cast(),
                ) {
                    runtime.mark_uncertain(
                        &active.request_id,
                        &format!("ritual_cast_socket_uncertain:{error}"),
                        now_ms(),
                    )?;
                    return Err(format!("SUMMON_RITUAL_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                }
                println!("[SUMMON-SERVICE] request={} spell=698 state=CAST_SENT retry_allowed=false", active.request_id);
                active.phase = DriverPhase::RitualWaiting {
                    target_guid,
                    summon_id: None,
                };
            }
        },
        DriverPhase::RitualWaiting { .. } => {}
        DriverPhase::AwaitingPayment { since_ms, .. } => {
            if now.saturating_sub(*since_ms) >= payment_grace_ms {
                runtime.mark_payment_missing(
                    &active.request_id,
                    "payment_grace_elapsed_late_payment_still_eligible_in_ledger",
                    now,
                )?;
                println!("[SUMMON-SERVICE] request={} payment=missing queue_released=true late_payment_ledger=true", active.request_id);
                *driver = None;
            }
        }
    }
    Ok(())
}

fn handle_whisper(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    runtime: &mut SummonServiceRuntime,
    name: &str,
    text: &str,
    destination_context: Option<&str>,
) -> Result<(), String> {
    let request = runtime.on_whisper(
        name,
        text,
        destination_context,
        Some("live_world"),
        now_ms(),
    )?;
    if let Some(request_id) = request {
        if let Some(record) = runtime.request(&request_id) {
            let reply = format!("Queued for {}.", record.destination);
            if let Err(error) = send_whisper(stream, crypto, name, &reply) {
                println!("[SUMMON-SERVICE][WHISPER-TX] target={name:?} uncertain_noncritical={error}");
            }
        }
    }
    Ok(())
}

pub fn login_summon_service(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
) -> Result<(), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
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
    let mut auth_ok = false;
    for _ in 0..16usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
            .map_err(|e| format!("read world pre-auth opcode failed: {e:?}"))?;
        if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) = opcode {
            auth_ok = matches!(*response, SMSG_AUTH_RESPONSE::AuthOk { .. });
            break;
        }
    }
    if !auth_ok { return Err("world auth did not return AuthOk".to_string()); }

    CMSG_CHAR_ENUM {}
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write char enum failed: {e:?}"))?;
    let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
        &mut *stream,
        crypto.decrypter(),
    )
    .map_err(|e| format!("read char enum failed: {e:?}"))?;
    let selected = match character_name {
        Some(wanted) => characters
            .characters
            .iter()
            .find(|character| character.name.eq_ignore_ascii_case(wanted))
            .ok_or_else(|| format!("character not found: {wanted}"))?,
        None => characters
            .characters
            .first()
            .ok_or_else(|| "character list empty".to_string())?,
    };
    let summoner_name = selected.name.clone();
    CMSG_PLAYER_LOGIN { guid: selected.guid }
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write player login failed: {e:?}"))?;
    let mut verified = false;
    for _ in 0..256usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
            .map_err(|e| format!("read before login verify failed: {e:?}"))?;
        if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
            verified = true;
            break;
        }
    }
    if !verified { return Err("SMSG_LOGIN_VERIFY_WORLD not received".to_string()); }

    let destination_context = configured_destination();
    let root = service_root();
    fs::create_dir_all(&root)
        .map_err(|error| format!("create service root {} failed: {error}", root.display()))?;
    let session_id = format!("{}-{}", summoner_name, unix_now());
    let mut config = ServiceRuntimeConfig::new(&root, session_id);
    if let Some(destination) = destination_context.as_ref() {
        if !config.destinations.iter().any(|value| value == destination) {
            config.destinations.push(destination.clone());
        }
    }
    let mut runtime = SummonServiceRuntime::open(config, now_ms())?;
    let helpers = configured_helpers();
    let invite_timeout_ms = env_u64("WOW112_TELE_INVITE_TIMEOUT_MS", DEFAULT_INVITE_TIMEOUT_MS);
    let payment_grace_ms = env_u64("WOW112_SUMMON_PAYMENT_GRACE_MS", DEFAULT_PAYMENT_GRACE_MS);
    let deadline = if soak_seconds == 0 { None } else { Some(Instant::now() + Duration::from_secs(soak_seconds)) };
    let mut driver: Option<ActiveDriver> = None;
    let mut roster = HashMap::<String, u64>::new();
    let mut name_cache = HashMap::<u64, String>::new();
    let mut pending_whispers = HashMap::<u64, Vec<String>>::new();
    let mut trade_session: Option<TradeSession> = None;
    let mut ledger = LedgerStore::open(tele10_ledger_path())?;
    ledger.set_policy(tele10_expected_price_copper(), tele10_partial_enabled());
    let mut last_ping = Instant::now();
    let mut ping_sequence = 1u32;
    let mut awaiting_pong: Option<(u32, Instant)> = None;
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set service read timeout failed: {e}"))?;

    println!("[SUMMON-SERVICE] READY summoner={:?} destination={:?} helpers={:?} state_root={} payment_grace_ms={}", summoner_name, destination_context, helpers, root.display(), payment_grace_ms);

    loop {
        if deadline.is_some_and(|value| Instant::now() >= value) { return Ok(()); }
        drive_active(
            stream,
            &mut crypto,
            &mut runtime,
            &mut driver,
            &roster,
            &helpers,
            invite_timeout_ms,
            payment_grace_ms,
        )?;

        if let Some((sequence, sent_at)) = awaiting_pong {
            if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                runtime.on_reconnect("world_keepalive_pong_timeout", now_ms())?;
                return Err(format!("world keepalive pong timeout sequence={sequence}"));
            }
        }
        if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS) && awaiting_pong.is_none() {
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
                        if awaiting_pong.map(|value| value.0) == Some(sequence) { awaiting_pong = None; }
                    }
                    continue;
                }

                if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                    if let Ok((guid, name)) = parse_name_query_response(&payload) {
                        name_cache.insert(guid, name.clone());
                        if let Some(items) = pending_whispers.remove(&guid) {
                            for text in items {
                                handle_whisper(
                                    stream,
                                    &mut crypto,
                                    &mut runtime,
                                    &name,
                                    &text,
                                    destination_context.as_deref(),
                                )?;
                            }
                        }
                        if let Some(active) = trade_session.as_mut() {
                            if active.partner_guid == guid && !active.terminal {
                                active.update_partner_name(&name);
                                tele10_refresh_correlation(&mut ledger, active)?;
                                tele10_try_accept(stream, &mut crypto, &mut ledger, active)?;
                            }
                        }
                    }
                    continue;
                }

                if opcode == SMSG_MESSAGECHAT_OPCODE {
                    if let Ok(ServerOpcodeMessage::SMSG_MESSAGECHAT(chat)) = parse_raw_server_message(opcode, &payload) {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            let guid = sender2.guid();
                            if let Some(name) = name_cache.get(&guid).cloned() {
                                handle_whisper(stream, &mut crypto, &mut runtime, &name, &chat.message, destination_context.as_deref())?;
                            } else {
                                let first = !pending_whispers.contains_key(&guid);
                                pending_whispers.entry(guid).or_default().push(chat.message);
                                if first { send_name_query(stream, &mut crypto, guid)?; }
                            }
                        }
                    }
                    continue;
                }

                if opcode == SMSG_GROUP_LIST_OPCODE {
                    if let Ok(next) = roster_from_group_list(&payload) {
                        roster = next;
                        if let Some(ActiveDriver { phase: DriverPhase::Party { seq }, .. }) = driver.as_mut() {
                            let names = roster.keys().cloned().collect::<Vec<_>>();
                            seq.on_group_list(&names);
                        }
                    }
                    continue;
                }
                if opcode == SMSG_PARTY_COMMAND_RESULT_OPCODE {
                    if let Some(ActiveDriver { phase: DriverPhase::Party { seq }, .. }) = driver.as_mut() {
                        let _ = seq.on_party_command_result(&payload);
                    }
                    continue;
                }
                if opcode == SMSG_GROUP_DECLINE_OPCODE {
                    if let Some(ActiveDriver { phase: DriverPhase::Party { seq }, .. }) = driver.as_mut() {
                        let _ = seq.on_group_decline(&payload);
                    }
                    continue;
                }

                if matches!(opcode, SMSG_CAST_RESULT_OPCODE | SMSG_SPELL_START_OPCODE | SMSG_SPELL_GO_OPCODE | SMSG_SPELL_FAILURE_OPCODE) {
                    let parsed = parse_raw_server_message(opcode, &payload)
                        .map(|message| format!("{message:?}"))
                        .unwrap_or_default();
                    if parsed.contains("698") || parsed.contains("0x02BA") {
                        if let Some(active) = driver.as_mut() {
                            if let DriverPhase::RitualWaiting { target_guid, summon_id } = &mut active.phase {
                                if matches!(opcode, SMSG_CAST_RESULT_OPCODE | SMSG_SPELL_FAILURE_OPCODE) {
                                    runtime.mark_terminal_failure(&active.request_id, &format!("server_ritual_reject:{parsed}"), now_ms())?;
                                    driver = None;
                                    continue;
                                }
                                if summon_id.is_none() {
                                    *summon_id = Some(tele10_record_ritual_started(
                                        &active.customer,
                                        *target_guid,
                                        &active.destination,
                                        &active.trigger_message,
                                        &summoner_name,
                                    )?);
                                }
                                if opcode == SMSG_SPELL_GO_OPCODE {
                                    let id = summon_id.clone().unwrap();
                                    ledger = LedgerStore::open(tele10_ledger_path())?;
                                    ledger.set_policy(tele10_expected_price_copper(), tele10_partial_enabled());
                                    ledger.mark_summoned(&id, unix_now())?;
                                    runtime.mark_summon_completed(&active.request_id, now_ms())?;
                                    active.phase = DriverPhase::AwaitingPayment { since_ms: now_ms(), summon_id: Some(id) };
                                }
                            }
                        }
                    }
                    continue;
                }

                if opcode == SMSG_TRADE_STATUS_EXTENDED_OPCODE {
                    if let Ok(update) = parse_trade_extended(&payload) {
                        if let Some(active) = trade_session.as_mut() {
                            if !active.terminal {
                                active.update_offer(&update);
                                tele10_refresh_correlation(&mut ledger, active)?;
                                tele10_try_accept(stream, &mut crypto, &mut ledger, active)?;
                            }
                        }
                    }
                    continue;
                }

                if opcode == SMSG_TRADE_STATUS_OPCODE {
                    let status = match parse_trade_status(&payload) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    match status.status {
                        TRADE_STATUS_BEGIN_TRADE => {
                            let busy_mutation = driver.as_ref().is_some_and(|value| !matches!(value.phase, DriverPhase::AwaitingPayment { .. }));
                            if busy_mutation {
                                println!("[SUMMON-SERVICE][TRADE] deferred begin during summon mutation window");
                                continue;
                            }
                            let partner_guid = status.trader_guid.unwrap_or(0);
                            if partner_guid == 0 || trade_session.as_ref().is_some_and(|value| !value.terminal) { continue; }
                            let trade_id = ledger.allocate_trade_id(unix_now())?;
                            trade_session = Some(TradeSession::new(trade_id.clone(), partner_guid));
                            let _ = send_name_query(stream, &mut crypto, partner_guid);
                            if let Err(error) = write_encrypted_raw(stream, crypto.encrypter(), CMSG_BEGIN_TRADE_OPCODE, &[]) {
                                if let Some(request_id) = runtime.active_request_id().map(ToString::to_string) {
                                    runtime.mark_uncertain(&request_id, &format!("trade_begin_socket_uncertain:{error}"), now_ms())?;
                                }
                                return Err(format!("TELE10_TRADE_BEGIN_MUTATION_UNCERTAIN trade_id={trade_id} retry_allowed=false cause={error}"));
                            }
                        }
                        TRADE_STATUS_TRADE_ACCEPT => {
                            if let Some(active) = trade_session.as_mut() {
                                if !active.terminal {
                                    active.partner_accepted = true;
                                    tele10_try_accept(stream, &mut crypto, &mut ledger, active)?;
                                }
                            }
                        }
                        TRADE_STATUS_BACK_TO_TRADE => {
                            if let Some(active) = trade_session.as_mut() {
                                active.partner_accepted = false;
                                if active.accept_mutation_id.is_some() {
                                    tele10_resolve_cancel(&mut ledger, active, "server_back_to_trade_after_accept_no_retry")?;
                                }
                            }
                        }
                        TRADE_STATUS_TRADE_COMPLETE => {
                            if let Some(active_trade) = trade_session.as_mut() {
                                if let Some((summon_id, amount, settlement_id)) = tele10_settle_complete(&mut ledger, active_trade)? {
                                    let mut matched_current = false;
                                    if let Some(active_job) = driver.as_ref() {
                                        if let DriverPhase::AwaitingPayment { summon_id: Some(expected), .. } = &active_job.phase {
                                            if *expected == summon_id {
                                                runtime.mark_payment_received(&active_job.request_id, amount, &settlement_id, now_ms())?;
                                                matched_current = true;
                                            }
                                        }
                                    }
                                    if matched_current { driver = None; }
                                    else { println!("[SUMMON-SERVICE][PAYMENT] late settlement summon_id={} amount={} queue_unchanged=true", summon_id, amount); }
                                }
                            }
                        }
                        TRADE_STATUS_TRADE_CANCELED | TRADE_STATUS_TRADE_REJECTED | TRADE_STATUS_CLOSE_WINDOW | TRADE_STATUS_BUSY | TRADE_STATUS_NO_TARGET | TRADE_STATUS_TARGET_TO_FAR => {
                            if let Some(active) = trade_session.as_mut() {
                                tele10_resolve_cancel(&mut ledger, active, &format!("server_trade_status_{}", status.status))?;
                            }
                        }
                        _ => {}
                    }
                    continue;
                }
            }
            Err(error) if error.contains("TimedOut") || error.contains("timed out") || error.contains("WouldBlock") => {}
            Err(error) => {
                runtime.on_reconnect(&error, now_ms())?;
                return Err(error);
            }
        }
    }
}
