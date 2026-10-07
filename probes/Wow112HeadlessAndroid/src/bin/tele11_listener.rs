use std::collections::HashMap;
use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::net::TcpStream;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "../auth.rs"]
mod auth;
#[path = "../tele_party_observer.rs"]
mod tele_party_observer;
#[path = "../wire_build.rs"]
mod wire_build;

use wire_build::OCTOWOW_WIRE_BUILD;
use wow112_headless_android_probe::tele08_whisper_parser::{
    classify_whisper, ParserConfig, WhisperIntent, WhisperObservation,
};
use wow112_headless_android_probe::tele11_ingress::{classify_ingress, write_spool_event};
use wow112_headless_android_probe::tele11_service_config::{ListenerConfig, ServiceFileConfig};

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_RECONNECT_LIMIT: u32 = 60;

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE11-LISTENER] ERROR: {error}");
        std::process::exit(2);
    }
}

fn config_path(args: &[String]) -> Result<std::path::PathBuf, String> {
    if let Some(index) = args.iter().position(|arg| arg == "--config") {
        return args
            .get(index + 1)
            .map(std::path::PathBuf::from)
            .ok_or_else(|| "--config requires a path".to_string());
    }
    env::var("WOW112_TELE11_CONFIG")
        .map(std::path::PathBuf::from)
        .map_err(|_| "missing --config or WOW112_TELE11_CONFIG".to_string())
}

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    if args.iter().any(|arg| arg == "--self-test") {
        println!("TELE11_LISTENER_SELFTEST_PASS");
        return Ok(());
    }
    let config = ServiceFileConfig::load(&config_path(&args)?)?;
    let listener = config.listener()?.clone();
    let parser = config.parser_config()?;
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let reconnect_limit = env::var("WOW112_RECONNECT_LIMIT")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(DEFAULT_RECONNECT_LIMIT)
        .max(1);

    println!(
        "[TELE11-LISTENER] START account={} character={} inbox={} default_destination={:?} wire_build={} reconnect_limit={}",
        listener.account,
        listener.character,
        listener.inbox_dir,
        listener.default_destination,
        OCTOWOW_WIRE_BUILD,
        reconnect_limit
    );

    for attempt in 1..=reconnect_limit {
        println!("[TELE11-LISTENER] session attempt={attempt}/{reconnect_limit}");
        match run_session(
            &auth_addr,
            config.realm_index,
            &listener,
            &parser,
            &password,
        ) {
            Ok(()) => return Ok(()),
            Err(error) if is_transient(&error) && attempt < reconnect_limit => {
                eprintln!("[TELE11-LISTENER] transient session failure: {error}");
                thread::sleep(Duration::from_millis(250));
            }
            Err(error) => return Err(error),
        }
    }
    Err(format!(
        "TELE11 listener reconnect limit exhausted after {reconnect_limit} attempts"
    ))
}

fn is_transient(error: &str) -> bool {
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
        "pong timeout",
        "10060",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn run_session(
    auth_addr: &str,
    realm_index: usize,
    listener: &ListenerConfig,
    parser: &ParserConfig,
    password: &str,
) -> Result<(), String> {
    let username = listener.account.to_ascii_uppercase();
    let mut auth_stream = TcpStream::connect(auth_addr)
        .map_err(|error| format!("auth connect {auth_addr} failed: {error}"))?;
    auth_stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| format!("auth timeout setup failed: {error}"))?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, &username, password)?;
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|error| format!("world connect {world_addr} failed: {error}"))?;
    live::login_and_listen(
        &mut world_stream,
        session_key,
        realm.realm_id,
        &username,
        &listener.character,
        listener,
        parser,
    )
}

fn append_unknown(path: &Path, sender: &str, text: &str, reason: &str) {
    let record = serde_json::json!({
        "at_ms": unix_ms(),
        "sender": sender,
        "text": text,
        "reason": reason
    });
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}", record);
        let _ = file.flush();
    }
}

mod live {
    include!("../world_tele.rs");

    use super::*;

    pub fn login_and_listen(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: &str,
        listener: &ListenerConfig,
        parser: &ParserConfig,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .map_err(|error| format!("set world read timeout failed: {error}"))?;
        let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
            .map_err(|error| format!("read world auth challenge failed: {error:?}"))?;
        let seed = ProofSeed::new();
        let seed_value = seed.seed();
        let normalized_username = NormalizedString::new(username)
            .map_err(|error| format!("invalid account name for world auth: {error:?}"))?;
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
            .map_err(|error| format!("encode world auth session failed: {error:?}"))?;
        stream
            .write_all(&auth_wire)
            .map_err(|error| format!("write world auth session failed: {error:?}"))?;
        world_diag_peek(stream, "auth-response-raw", Duration::from_millis(1500));
        skip_octowow_addon_info(stream, crypto.decrypter())?;

        let mut auth_ok = false;
        for _ in 0..16usize {
            let message = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|error| format!("read pre-auth opcode failed: {error:?}"))?;
            if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) = message {
                auth_ok = matches!(*response, SMSG_AUTH_RESPONSE::AuthOk { .. });
                break;
            }
        }
        if !auth_ok {
            return Err("world auth did not return AuthOk".to_string());
        }

        CMSG_CHAR_ENUM {}
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|error| format!("write char enum failed: {error:?}"))?;
        let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
            &mut *stream,
            crypto.decrypter(),
        )
        .map_err(|error| format!("read char enum failed: {error:?}"))?;
        let selected = characters
            .characters
            .iter()
            .find(|character| character.name.eq_ignore_ascii_case(character_name))
            .ok_or_else(|| format!("listener character not found: {character_name}"))?;
        tele_trace::set_local_guid(selected.guid.guid());
        CMSG_PLAYER_LOGIN { guid: selected.guid }
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|error| format!("write player login failed: {error:?}"))?;

        let mut verified = false;
        for _ in 0..256usize {
            let message = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|error| format!("read before login verify failed: {error:?}"))?;
            if matches!(message, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
                verified = true;
                break;
            }
        }
        if !verified {
            return Err("listener did not reach SMSG_LOGIN_VERIFY_WORLD".to_string());
        }
        println!("[TELE11-LISTENER] LOGIN PASS character={}", selected.name);
        listen_loop(stream, &mut crypto, listener, parser)
    }

    fn handle_resolved_whisper(
        sender_name: &str,
        text: &str,
        listener: &ListenerConfig,
        parser: &ParserConfig,
    ) -> Result<(), String> {
        let at_ms = unix_ms();
        let observation = WhisperObservation {
            sender: sender_name.to_string(),
            text: text.to_string(),
            timestamp_ms: at_ms,
            source_role: Some("TELE11_LISTENER".to_string()),
            destination_context: listener.default_destination.clone(),
        };
        if let Some(event) = classify_ingress(&observation, parser) {
            let path = write_spool_event(Path::new(&listener.inbox_dir), &event)?;
            println!(
                "[TELE11-INGRESS] ADMIT request_id={} sender={} destination={} intent={} confidence={} spool={}",
                event.request_id,
                event.sender,
                event.destination,
                event.intent,
                event.confidence,
                path.display()
            );
            return Ok(());
        }

        let classification = classify_whisper(&observation, parser);
        println!(
            "[TELE11-INGRESS] IGNORE sender={} intent={:?} destination={:?} confidence={} reason={} text={:?}",
            sender_name,
            classification.intent,
            classification.destination.as_ref().map(|value| value.0.as_str()),
            classification.confidence,
            classification.reason,
            text
        );
        if classification.intent == WhisperIntent::Unknown {
            if let Some(path) = listener.unknown_log.as_deref() {
                append_unknown(Path::new(path), sender_name, text, &classification.reason);
            }
        }
        Ok(())
    }

    fn listen_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        listener: &ListenerConfig,
        parser: &ParserConfig,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|error| format!("set listener read timeout failed: {error}"))?;
        let mut last_ping = Instant::now();
        let mut ping_sequence = 1u32;
        let mut awaiting_pong: Option<(u32, Instant)> = None;
        let mut name_cache = HashMap::<u64, String>::new();
        let mut pending = HashMap::<u64, Vec<String>>::new();
        println!("[TELE11-LISTENER] ACTIVE whisper_rx=true mutations=request_spool_only");

        loop {
            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("pong timeout sequence={sequence}"));
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
                    if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                        match tele_parse_name_query_response(&payload) {
                            Ok((guid, name)) => {
                                name_cache.insert(guid, name.clone());
                                if let Some(messages) = pending.remove(&guid) {
                                    for text in messages {
                                        handle_resolved_whisper(&name, &text, listener, parser)?;
                                    }
                                }
                            }
                            Err(error) => eprintln!(
                                "[TELE11-LISTENER] NAME_QUERY parse skipped: {error}"
                            ),
                        }
                        continue;
                    }
                    if opcode != SMSG_MESSAGECHAT_OPCODE {
                        continue;
                    }
                    let message = match parse_raw_server_message(opcode, &payload) {
                        Ok(value) => value,
                        Err(error) => {
                            eprintln!("[TELE11-LISTENER] chat parse skipped: {error}");
                            continue;
                        }
                    };
                    if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            let guid = sender2.guid();
                            if let Some(name) = name_cache.get(&guid).cloned() {
                                handle_resolved_whisper(&name, &chat.message, listener, parser)?;
                            } else {
                                let first = !pending.contains_key(&guid);
                                pending.entry(guid).or_default().push(chat.message);
                                if first {
                                    tele_send_name_query(stream, crypto, guid)?;
                                }
                            }
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
}
