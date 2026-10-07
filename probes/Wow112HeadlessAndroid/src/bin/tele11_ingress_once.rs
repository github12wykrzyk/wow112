use std::env;
use std::fs;
use std::net::{Shutdown, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "../auth.rs"]
mod auth;
#[path = "../wire_build.rs"]
mod wire_build;

use tele08_request_queue::QueueEvent;
use wire_build::OCTOWOW_WIRE_BUILD;
use wow112_headless_android_probe::tele08_whisper_parser::{
    classify_whisper, request_fingerprint, ParserConfig, WhisperClassification, WhisperIntent,
    WhisperObservation,
};
use wow112_headless_android_probe::tele_response_engine::{
    ResponseContext, ResponseEngine, ResponseEngineConfig,
};
use wow112_headless_android_probe::tele11_service_core::{
    RouteConfig, ServiceCore, ServiceCoreConfig,
};

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const DEFAULT_DEDUP_MS: u64 = 30_000;
const DEFAULT_EXPIRY_MS: u64 = 180_000;

#[derive(Clone, Debug)]
struct Config {
    account: String,
    character: String,
    destination: String,
    journal_path: PathBuf,
    status_path: Option<PathBuf>,
    listen_timeout: Option<Duration>,
    self_test: bool,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn env_u64(name: &str, default_value: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(default_value)
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].trim().to_string())
        .filter(|value| !value.is_empty())
}

fn config_from_args() -> Result<Config, String> {
    let args: Vec<String> = env::args().collect();
    let self_test = args.iter().any(|arg| arg == "--self-test");
    let destination = arg_value(&args, "--destination")
        .or_else(|| env::var("WOW112_TELE11_DESTINATION").ok())
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| if self_test { "winterspring".into() } else { String::new() });
    if destination.is_empty() {
        return Err("missing --destination or WOW112_TELE11_DESTINATION".into());
    }
    let account = env::var("WOW112_TELE11_SUMMONER_ACCOUNT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "taxi3".into());
    let character = env::var("WOW112_TELE11_SUMMONER_CHARACTER")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Teletanaris".into());
    let journal_path = env::var("WOW112_TELE11_JOURNAL_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele11_service_journal.jsonl"));
    let status_path = env::var("WOW112_TELE11_INGRESS_STATUS")
        .ok()
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty());
    let listen_timeout = env::var("WOW112_TELE11_INGRESS_TIMEOUT_SECS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .map(Duration::from_secs);
    Ok(Config {
        account,
        character,
        destination,
        journal_path,
        status_path,
        listen_timeout,
        self_test,
    })
}

fn service_core_config(destination: &str) -> ServiceCoreConfig {
    ServiceCoreConfig {
        schema_version: 1,
        dedup_window_ms: env_u64("WOW112_TELE11_DEDUP_MS", DEFAULT_DEDUP_MS),
        expiry_ms: env_u64("WOW112_TELE11_EXPIRY_MS", DEFAULT_EXPIRY_MS),
        routes: vec![RouteConfig {
            destination: destination.to_string(),
            resource: format!("summon/{destination}"),
        }],
    }
}

fn parser_config() -> ParserConfig {
    ParserConfig::default()
        .with_destination_alias("mount hyjal", "hyjal")
        .with_destination_alias("everlook", "winterspring")
        .with_destination_alias("hydraxian", "azshara")
        .with_destination_alias("hydraxian waterlords", "azshara")
        .with_destination_alias("waterlords", "azshara")
        .with_destination_alias("waterlord", "azshara")
}

fn actionable(classification: &WhisperClassification) -> bool {
    matches!(
        classification.intent,
        WhisperIntent::SummonRequest
            | WhisperIntent::InviteRequest
            | WhisperIntent::PresenceReady
            | WhisperIntent::GenericPositive
    )
}

fn write_status(config: &Config, state: &str, detail: &str) {
    let Some(path) = config.status_path.as_ref() else {
        return;
    };
    let safe = detail.replace(['\r', '\n'], " ");
    let temp = path.with_extension("tmp");
    let body = format!("state={state}\ndetail={safe}\ntimestamp_ms={}\n", now_ms());
    if fs::write(&temp, body).is_ok() {
        let _ = fs::rename(temp, path);
    }
}

fn request_id(classification: &WhisperClassification) -> String {
    format!(
        "tele11:{}:{}",
        classification.timestamp_ms,
        request_fingerprint(classification)
    )
}

fn queued_request_id(events: &[QueueEvent]) -> Option<String> {
    events.iter().find_map(|event| match event {
        QueueEvent::RequestQueued { request_id, .. } => Some(request_id.clone()),
        QueueEvent::DuplicateSuppressed {
            original_request_id, ..
        } => Some(original_request_id.clone()),
        _ => None,
    })
}

fn queued_position(events: &[QueueEvent]) -> Option<usize> {
    events.iter().find_map(|event| match event {
        QueueEvent::RequestQueued { position, .. } => Some(*position),
        _ => None,
    })
}

fn run_self_test(config: &Config) -> Result<(), String> {
    let parser = parser_config();
    for (text, expected) in [
        ("+", WhisperIntent::GenericPositive),
        ("invi", WhisperIntent::InviteRequest),
        ("here", WhisperIntent::PresenceReady),
        ("winterspring pls", WhisperIntent::SummonRequest),
    ] {
        let classification = classify_whisper(
            &WhisperObservation {
                sender: "Customer".into(),
                text: text.into(),
                timestamp_ms: 1,
                source_role: Some("TELE11_SELFTEST".into()),
                destination_context: Some(config.destination.clone()),
            },
            &parser,
        );
        if classification.intent != expected || !actionable(&classification) {
            return Err(format!("parser contract failed text={text:?} got={classification:?}"));
        }
    }
    let service_config = service_core_config(&config.destination);
    service_config.validate()?;
    println!("TELE11 INGRESS SELFTEST PASS destination={}", config.destination);
    Ok(())
}

fn main() {
    let config = match config_from_args() {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[TELE11-INGRESS] CONFIG ERROR: {error}");
            std::process::exit(2);
        }
    };
    if config.self_test {
        if let Err(error) = run_self_test(&config) {
            eprintln!("[TELE11-INGRESS] SELFTEST ERROR: {error}");
            std::process::exit(2);
        }
        return;
    }
    if let Err(error) = run(config) {
        eprintln!("[TELE11-INGRESS] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run(config: Config) -> Result<(), String> {
    let password = env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    if password.trim().is_empty() {
        return Err("WOW112_PASSWORD is empty".into());
    }
    let (core, recovered) = ServiceCore::create_or_open(
        &config.journal_path,
        service_core_config(&config.destination),
        now_ms(),
    )?;
    if !recovered.is_empty() {
        write_status(&config, "BLOCKED_RECONCILIATION", "journal contains recovered active job");
        return Err(format!(
            "TELE11 ingress blocked: {} recovered active job(s) require reconciliation",
            recovered.len()
        ));
    }
    if core
        .queue()
        .next_eligible_request(&tele08_request_queue::ResourceKey(format!(
            "summon/{}",
            config.destination
        )))
        .is_some()
    {
        write_status(&config, "HANDOFF", "queued request already exists; executor should run it");
        println!("[TELE11-INGRESS] queued request already exists -> HANDOFF");
        return Ok(());
    }
    drop(core);

    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);
    write_status(&config, "CONNECTING", "auth/world login");
    let mut auth_stream = TcpStream::connect(&auth_addr)
        .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let username = config.account.to_ascii_uppercase();
    let (session_key, realms) = auth::authenticate(&mut auth_stream, &username, &password)?;
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|e| format!("world connect {world_addr} failed: {e}"))?;
    live::login_and_listen(
        &mut world_stream,
        session_key,
        realm.realm_id,
        &username,
        &config,
    )?;
    let _ = world_stream.shutdown(Shutdown::Both);
    write_status(&config, "HANDOFF", "request durably queued; world socket closed");
    Ok(())
}

mod live {
    include!("../world_tele.rs");

    use std::collections::HashMap;

    use super::*;

    pub fn login_and_listen(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        config: &Config,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
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
        world_diag_peek(stream, "tele11-auth-response-raw", Duration::from_millis(1500));
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
        if !auth_ok {
            return Err("world auth did not return AuthOk".into());
        }

        CMSG_CHAR_ENUM {}
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|e| format!("write char enum failed: {e:?}"))?;
        let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
            &mut *stream,
            crypto.decrypter(),
        )
        .map_err(|e| format!("read char enum failed: {e:?}"))?;
        let selected = characters
            .characters
            .iter()
            .find(|character| character.name.eq_ignore_ascii_case(&config.character))
            .ok_or_else(|| format!("character not found: {}", config.character))?;
        tele_trace::set_local_guid(selected.guid.guid());
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
        if !verified {
            return Err("SMSG_LOGIN_VERIFY_WORLD not received".into());
        }
        println!(
            "[TELE11-INGRESS] READY account={} character={} destination={} journal={}",
            config.account,
            config.character,
            config.destination,
            config.journal_path.display()
        );
        write_status(config, "LISTENING", "waiting for actionable whisper");

        let parser = parser_config();
        let mut response_engine = ResponseEngine::new(ResponseEngineConfig::default());
        let mut keepalive = Keepalive::new();
        let mut name_cache: HashMap<u64, String> = HashMap::new();
        let mut pending: HashMap<u64, Vec<String>> = HashMap::new();
        let deadline = config.listen_timeout.map(|timeout| Instant::now() + timeout);

        loop {
            if deadline.is_some_and(|value| Instant::now() >= value) {
                return Err("TELE11 ingress listen timeout".into());
            }
            keepalive.maybe_send(stream, &mut crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if keepalive.handle_pong(opcode, &payload) {
                        continue;
                    }
                    if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                        if let Ok((guid, name)) = tele_parse_name_query_response(&payload) {
                            name_cache.insert(guid, name.clone());
                            if let Some(messages) = pending.remove(&guid) {
                                for text in messages {
                                    if process_whisper(
                                        stream,
                                        &mut crypto,
                                        config,
                                        &mut response_engine,
                                        &name,
                                        &text,
                                    )? {
                                        return Ok(());
                                    }
                                }
                            }
                        }
                        continue;
                    }
                    if opcode != SMSG_MESSAGECHAT_OPCODE {
                        continue;
                    }
                    let message = match parse_raw_server_message(opcode, &payload) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            let guid = sender2.guid();
                            let text = chat.message;
                            if let Some(name) = name_cache.get(&guid).cloned() {
                                if process_whisper(
                                    stream,
                                    &mut crypto,
                                    config,
                                    &mut response_engine,
                                    &name,
                                    &text,
                                )? {
                                    return Ok(());
                                }
                            } else {
                                let first = !pending.contains_key(&guid);
                                pending.entry(guid).or_default().push(text);
                                if first {
                                    tele_send_name_query(stream, &mut crypto, guid)?;
                                }
                            }
                        }
                    }
                }
                Err(error) if transient_read(&error) => {}
                Err(error) => return Err(error),
            }
        }
    }

    fn process_whisper(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        config: &Config,
        response_engine: &mut ResponseEngine,
        sender: &str,
        text: &str,
    ) -> Result<bool, String> {
        let observed_at = now_ms();
        let classification = classify_whisper(
            &WhisperObservation {
                sender: sender.to_string(),
                text: text.to_string(),
                timestamp_ms: observed_at,
                source_role: Some("TELE11_INGRESS".into()),
                destination_context: Some(config.destination.clone()),
            },
            &parser_config(),
        );
        println!(
            "[TELE11-INGRESS] RX sender={sender:?} text={text:?} intent={:?} destination={:?} confidence={}",
            classification.intent,
            classification.destination.as_ref().map(|value| value.0.as_str()),
            classification.confidence
        );

        if classification.intent == WhisperIntent::CompetitionMessage {
            let mut decisions = response_engine.handle_context(
                ResponseContext::CompetitionMessage {
                    recipient: sender.to_string(),
                },
                observed_at / 1000,
            );
            if let Some(decision) = decisions.pop() {
                if decision.should_send {
                    tele_send_whisper(stream, crypto, sender, &decision.text)?;
                }
            }
            return Ok(false);
        }
        if !actionable(&classification) {
            return Ok(false);
        }

        let destination = classification
            .destination
            .as_ref()
            .map(|value| value.0.clone())
            .unwrap_or_else(|| config.destination.clone());
        if !destination.eq_ignore_ascii_case(&config.destination) {
            let mut decisions = response_engine.handle_context(
                ResponseContext::UnsupportedDestination {
                    recipient: sender.to_string(),
                    requested_destination: destination,
                    alternatives: vec![config.destination.clone()],
                },
                observed_at / 1000,
            );
            if let Some(decision) = decisions.pop() {
                if decision.should_send {
                    tele_send_whisper(stream, crypto, sender, &decision.text)?;
                }
            }
            return Ok(false);
        }

        let (mut core, recovered) = ServiceCore::create_or_open(
            &config.journal_path,
            service_core_config(&config.destination),
            observed_at,
        )?;
        if !recovered.is_empty() {
            return Err("TELE11 journal entered reconciliation while ingress was live".into());
        }
        let incoming_id = request_id(&classification);
        let events = core.enqueue_request(
            incoming_id,
            sender.to_string(),
            config.destination.clone(),
            text.to_string(),
            observed_at,
        )?;
        let Some(effective_id) = queued_request_id(&events) else {
            println!("[TELE11-INGRESS] request not admitted events={events:?}");
            return Ok(false);
        };
        let position = core.queue().position(&effective_id).or_else(|| queued_position(&events));
        let queue_len = core.queue().queued_count_by_destination(&config.destination);
        let mut decisions = response_engine.handle_context(
            ResponseContext::RequestQueued {
                recipient: sender.to_string(),
                destination: config.destination.clone(),
                queue_position: position,
                queue_length: Some(queue_len),
            },
            observed_at / 1000,
        );
        if let Some(decision) = decisions.pop() {
            if decision.should_send {
                tele_send_whisper(stream, crypto, sender, &decision.text)?;
            }
        }
        println!(
            "[TELE11-INGRESS] HANDOFF request_id={} player={} destination={} position={:?}",
            effective_id, sender, config.destination, position
        );
        Ok(true)
    }

    struct Keepalive {
        last_ping: Instant,
        next_sequence: u32,
        awaiting_pong: Option<(u32, Instant)>,
    }

    impl Keepalive {
        fn new() -> Self {
            Self {
                last_ping: Instant::now(),
                next_sequence: 1,
                awaiting_pong: None,
            }
        }

        fn maybe_send(
            &mut self,
            stream: &mut TcpStream,
            crypto: &mut HeaderCrypto,
        ) -> Result<(), String> {
            if let Some((sequence, sent_at)) = self.awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("world keepalive pong timeout sequence={sequence}"));
                }
            }
            if self.last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS)
                && self.awaiting_pong.is_none()
            {
                let sequence = self.next_sequence;
                let mut payload = Vec::with_capacity(8);
                payload.extend_from_slice(&sequence.to_le_bytes());
                payload.extend_from_slice(&0u32.to_le_bytes());
                write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
                self.awaiting_pong = Some((sequence, Instant::now()));
                self.next_sequence = self.next_sequence.wrapping_add(1);
                self.last_ping = Instant::now();
            }
            Ok(())
        }

        fn handle_pong(&mut self, opcode: u16, payload: &[u8]) -> bool {
            if opcode != SMSG_PONG_OPCODE || payload.len() < 4 {
                return false;
            }
            let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            if self.awaiting_pong.map(|value| value.0) == Some(sequence) {
                self.awaiting_pong = None;
            }
            true
        }
    }

    fn transient_read(error: &str) -> bool {
        error.contains("TimedOut") || error.contains("timed out") || error.contains("WouldBlock")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plus_and_here_are_actionable_with_destination_context() {
        let config = Config {
            account: "x".into(),
            character: "y".into(),
            destination: "hyjal".into(),
            journal_path: PathBuf::from("unused"),
            status_path: None,
            listen_timeout: None,
            self_test: true,
        };
        run_self_test(&config).unwrap();
    }

    #[test]
    fn request_ids_include_fingerprint() {
        let classification = classify_whisper(
            &WhisperObservation {
                sender: "Somebody".into(),
                text: "+".into(),
                timestamp_ms: 123,
                source_role: None,
                destination_context: Some("hyjal".into()),
            },
            &parser_config(),
        );
        let id = request_id(&classification);
        assert!(id.starts_with("tele11:123:"));
    }
}
