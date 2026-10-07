use std::env;
use std::fs::{self, File};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "../auth.rs"]
mod auth;
#[path = "../tele_party_observer.rs"]
mod tele_party_observer;
#[path = "../wire_build.rs"]
mod wire_build;

use tele08_request_queue::{QueueConfig, QueueEngine, QueueEvent, ResourceKey};
use wire_build::OCTOWOW_WIRE_BUILD;
use wow112_headless_android_probe::destination_registry::{
    Availability, DestinationObservation, DestinationRegistry, ManualOverride, TeamHealth,
};
use wow112_headless_android_probe::tele08_bc_adapter::classification_to_request;
use wow112_headless_android_probe::tele08_whisper_parser::{
    classify_whisper, DestinationAlias, DestinationKey, ParserConfig, WhisperObservation,
};
use wow112_headless_android_probe::tele_response_engine::{
    DecisionReason, ResponseContext, ResponseEngine, ResponseEngineConfig, ResponseKind,
};

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const READY_TIMEOUT_SECS: u64 = 180;
const LIVE_TIMEOUT_SECS: u64 = 90;
const REQUEST_TEXT: &str = "winterspring pls";
const EXPECTED_DESTINATION: &str = "winterspring";
const EXPECTED_REPLY: &str = "Queued for winterspring. Position: 1/1.";
const SEED: &str = include_str!("../../config/tele08_destinations.example.json");

#[derive(Clone, Debug)]
struct RoleSpec {
    label: &'static str,
    account: String,
    character: String,
}

#[derive(Debug)]
struct ManagedRole {
    label: &'static str,
    child: Child,
    state_path: PathBuf,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE08-ROUNDTRIP] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if let Some(index) = args.iter().position(|arg| arg == "--role") {
        let role = args
            .get(index + 1)
            .ok_or_else(|| "--role requires CUSTOMER or SUMMONER".to_string())?;
        return run_role(role);
    }
    if args.iter().any(|arg| arg == "--self-test") {
        return self_test();
    }
    run_orchestrator()
}

fn self_test() -> Result<(), String> {
    let registry = healthy_registry()?;
    let parser = parser_config_from_registry(&registry);
    let classification = classify_whisper(
        &WhisperObservation {
            sender: "Feltaxi".into(),
            text: REQUEST_TEXT.into(),
            timestamp_ms: 1_000_000,
            source_role: Some("ROUNDTRIP_SELFTEST".into()),
            destination_context: None,
        },
        &parser,
    );
    if classification.destination.as_ref().map(|d| d.0.as_str()) != Some(EXPECTED_DESTINATION) {
        return Err(format!("B destination mismatch: {classification:?}"));
    }

    let mut queue = queue_from_registry(&registry)?;
    let request = classification_to_request(&classification)
        .map_err(|e| format!("B->C admission rejected: {e:?}"))?;
    let destination_id = registry
        .resolve_destination(&request.destination)
        .ok_or_else(|| format!("D could not resolve {}", request.destination))?;
    let status = registry
        .status(&destination_id)
        .ok_or_else(|| "D status missing".to_string())?;
    if status.availability != Availability::Enabled {
        return Err(format!("D destination not enabled: {:?}", status.availability));
    }

    let outcome = queue.enqueue(request);
    if !outcome.accepted {
        return Err(format!("C enqueue rejected: {outcome:?}"));
    }
    let position = queued_position(&outcome.events)
        .ok_or_else(|| "C emitted no RequestQueued position".to_string())?;
    let queue_len = queue.queued_count_by_destination(EXPECTED_DESTINATION);

    let mut engine = ResponseEngine::new(ResponseEngineConfig::default());
    let mut decisions = engine.handle_context(
        ResponseContext::RequestQueued {
            recipient: "Feltaxi".into(),
            destination: EXPECTED_DESTINATION.into(),
            queue_position: Some(position),
            queue_length: Some(queue_len),
        },
        100,
    );
    if decisions.len() != 1 {
        return Err(format!("E decision count={}", decisions.len()));
    }
    let decision = decisions.remove(0);
    if !decision.should_send
        || decision.reason != DecisionReason::Allowed
        || decision.response_kind != ResponseKind::Queued
        || decision.text != EXPECTED_REPLY
    {
        return Err(format!("E response mismatch: {decision:?}"));
    }
    println!("TELE08_FULL_ROUNDTRIP_SELFTEST_PASS response={:?}", decision.text);
    Ok(())
}

fn run_orchestrator() -> Result<(), String> {
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    if password.trim().is_empty() {
        return Err("WOW112_PASSWORD is empty".to_string());
    }

    let run_dir = make_run_dir()?;
    let exe = env::current_exe().map_err(|e| format!("current_exe failed: {e}"))?;
    let customer = RoleSpec {
        label: "CUSTOMER",
        account: env_value("WOW112_TELE08_CUSTOMER_ACCOUNT", "taxi1"),
        character: env_value("WOW112_TELE08_CUSTOMER_CHARACTER", "__FIRST__"),
    };
    let summoner = RoleSpec {
        label: "SUMMONER",
        account: env_value("WOW112_TELE08_SUMMONER_ACCOUNT", "taxi3"),
        character: env_value("WOW112_TELE08_SUMMONER_CHARACTER", "Teletanaris"),
    };

    println!(
        "[TELE08-ROUNDTRIP] run_dir={} binary-build=5875 wire-build={} request={:?} expected_reply={:?}",
        run_dir.display(), OCTOWOW_WIRE_BUILD, REQUEST_TEXT, EXPECTED_REPLY
    );

    let mut roles = vec![
        spawn_role(&exe, &run_dir, &password, &customer)?,
        spawn_role(&exe, &run_dir, &password, &summoner)?,
    ];

    let outcome = orchestrate(&run_dir, &mut roles);
    let _ = fs::write(run_dir.join("DONE"), "done\n");
    for role in &mut roles {
        if role.child.try_wait().ok().flatten().is_none() {
            let _ = role.child.kill();
        }
        let _ = role.child.wait();
    }

    match outcome {
        Ok(()) => {
            let summary = format!(
                "result=PASS\nchain=real_whisper_in>B_parser>C_queue>D_registry>E_response>real_whisper_out>customer_rx\nrequest={}\nexpected_reply={}\nroles=2/2\n",
                REQUEST_TEXT, EXPECTED_REPLY
            );
            fs::write(run_dir.join("STATUS.txt"), &summary)
                .map_err(|e| format!("write STATUS failed: {e}"))?;
            println!("TELE08_FULL_ROUNDTRIP_PASS");
            Ok(())
        }
        Err(error) => {
            let mut body = format!("result=FAIL\nreason={}\n", sanitize(&error));
            for role in &roles {
                body.push_str(&format!(
                    "{}={} stdout={} stderr={}\n",
                    role.label,
                    read_state(&role.state_path)
                        .map(|(s, d)| format!("{s}:{d}"))
                        .unwrap_or_else(|| "NO_STATE".into()),
                    role.stdout_path.display(),
                    role.stderr_path.display()
                ));
            }
            let _ = fs::write(run_dir.join("STATUS.txt"), body);
            Err(format!("{error}; evidence={}", run_dir.display()))
        }
    }
}

fn orchestrate(run_dir: &Path, roles: &mut [ManagedRole]) -> Result<(), String> {
    let ready_deadline = Instant::now() + Duration::from_secs(READY_TIMEOUT_SECS);
    loop {
        let mut ready = 0usize;
        for role in roles.iter_mut() {
            if let Some((state, detail)) = read_state(&role.state_path) {
                if state == "READY" || state == "PASS" {
                    ready += 1;
                } else if state == "FAIL" {
                    return Err(format!("{} failed before GO: {detail}", role.label));
                }
            }
            if let Some(status) = role.child.try_wait().map_err(|e| e.to_string())? {
                if read_state(&role.state_path).map(|s| s.0) != Some("PASS".into()) {
                    return Err(format!("{} exited before READY status={status}", role.label));
                }
            }
        }
        if ready == roles.len() {
            break;
        }
        if Instant::now() >= ready_deadline {
            return Err(format!("READY timeout ready={ready}/{}", roles.len()));
        }
        thread::sleep(Duration::from_millis(250));
    }

    fs::write(run_dir.join("GO"), "go\n").map_err(|e| format!("publish GO failed: {e}"))?;
    println!("[TELE08-ROUNDTRIP] 2/2 READY -> GO");

    let live_deadline = Instant::now() + Duration::from_secs(LIVE_TIMEOUT_SECS);
    loop {
        let mut passed = 0usize;
        for role in roles.iter_mut() {
            if let Some((state, detail)) = read_state(&role.state_path) {
                match state.as_str() {
                    "PASS" => passed += 1,
                    "FAIL" => return Err(format!("{} live FAIL: {detail}", role.label)),
                    _ => {}
                }
            }
            if let Some(status) = role.child.try_wait().map_err(|e| e.to_string())? {
                if read_state(&role.state_path).map(|s| s.0) != Some("PASS".into()) {
                    return Err(format!("{} exited during live status={status}", role.label));
                }
            }
        }
        if passed == roles.len() {
            return Ok(());
        }
        if Instant::now() >= live_deadline {
            return Err(format!("live timeout pass={passed}/{}", roles.len()));
        }
        thread::sleep(Duration::from_millis(250));
    }
}

fn spawn_role(
    exe: &Path,
    run_dir: &Path,
    password: &str,
    spec: &RoleSpec,
) -> Result<ManagedRole, String> {
    let state_path = run_dir.join(format!("STATE_{}.txt", spec.label));
    let stdout_path = run_dir.join(format!("{}.stdout.log", spec.label));
    let stderr_path = run_dir.join(format!("{}.stderr.log", spec.label));
    let stdout = File::create(&stdout_path)
        .map_err(|e| format!("create {} failed: {e}", stdout_path.display()))?;
    let stderr = File::create(&stderr_path)
        .map_err(|e| format!("create {} failed: {e}", stderr_path.display()))?;

    let mut command = Command::new(exe);
    command
        .arg("--role")
        .arg(spec.label)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_TELE08_ROLE_ACCOUNT", &spec.account)
        .env("WOW112_TELE08_ROLE_CHARACTER", &spec.character)
        .env("WOW112_TELE08_STATE_FILE", &state_path)
        .env("WOW112_TELE08_GO_FILE", run_dir.join("GO"))
        .env("WOW112_TELE08_DONE_FILE", run_dir.join("DONE"))
        .env(
            "WOW112_TELE08_LOCAL_GUID_FILE",
            run_dir.join(format!("GUID_{}.txt", spec.label)),
        )
        .env("WOW112_TELE08_CUSTOMER_GUID_FILE", run_dir.join("GUID_CUSTOMER.txt"))
        .env("WOW112_TELE08_SUMMONER_GUID_FILE", run_dir.join("GUID_SUMMONER.txt"))
        .env("WOW112_TELE08_TRANSCRIPT_FILE", run_dir.join("TRANSCRIPT.txt"));

    let child = command
        .spawn()
        .map_err(|e| format!("spawn {} failed: {e}", spec.label))?;

    Ok(ManagedRole {
        label: spec.label,
        child,
        state_path,
        stdout_path,
        stderr_path,
    })
}

fn run_role(label: &str) -> Result<(), String> {
    if label != "CUSTOMER" && label != "SUMMONER" {
        return Err(format!("unknown role {label:?}"));
    }
    let account = env::var("WOW112_TELE08_ROLE_ACCOUNT")
        .map_err(|_| "missing WOW112_TELE08_ROLE_ACCOUNT".to_string())?;
    let character = env::var("WOW112_TELE08_ROLE_CHARACTER")
        .map_err(|_| "missing WOW112_TELE08_ROLE_CHARACTER".to_string())?;
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let state_path = env_path("WOW112_TELE08_STATE_FILE")?;
    let go_file = env_path("WOW112_TELE08_GO_FILE")?;
    let done_file = env_path("WOW112_TELE08_DONE_FILE")?;
    let local_guid_file = env_path("WOW112_TELE08_LOCAL_GUID_FILE")?;
    let customer_guid_file = env_path("WOW112_TELE08_CUSTOMER_GUID_FILE")?;
    let summoner_guid_file = env_path("WOW112_TELE08_SUMMONER_GUID_FILE")?;
    let transcript_file = env_path("WOW112_TELE08_TRANSCRIPT_FILE")?;

    write_state(&state_path, "CONNECTING", label, "auth")?;
    let auth_addr = env_value("WOW112_AUTH_ADDR", DEFAULT_AUTH_ADDR);
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);

    let mut auth_stream = TcpStream::connect(&auth_addr)
        .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let username = account.to_ascii_uppercase();
    let (session_key, realms) = auth::authenticate(&mut auth_stream, &username, &password)?;
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|e| format!("world connect {world_addr} failed: {e}"))?;

    let result = live::login_and_roundtrip(
        &mut world_stream,
        session_key,
        realm.realm_id,
        &username,
        &character,
        label,
        &state_path,
        &go_file,
        &done_file,
        &local_guid_file,
        &customer_guid_file,
        &summoner_guid_file,
        &transcript_file,
    );
    if let Err(error) = &result {
        let _ = write_state(&state_path, "FAIL", label, error);
    }
    result
}

fn healthy_registry() -> Result<DestinationRegistry, String> {
    let mut registry = DestinationRegistry::from_json(SEED)
        .map_err(|e| format!("destination registry seed invalid: {e}"))?;
    for definition in registry.config().destinations.clone() {
        registry
            .set_observation(
                &definition.id,
                DestinationObservation {
                    shard_count: None,
                    manual_override: ManualOverride::Automatic,
                    team_health: TeamHealth::Healthy,
                },
            )
            .map_err(|e| format!("healthy observation failed for {}: {e}", definition.id))?;
    }
    Ok(registry)
}

fn queue_from_registry(registry: &DestinationRegistry) -> Result<QueueEngine, String> {
    let mut config = QueueConfig::new(10_000, 120_000);
    for definition in &registry.config().destinations {
        let resource = registry
            .resource_key(&definition.id)
            .ok_or_else(|| format!("missing resource key for {}", definition.id))?;
        config.map_destination_resource(definition.id.as_str(), ResourceKey::from(resource));
    }
    Ok(QueueEngine::new(config))
}

fn parser_config_from_registry(registry: &DestinationRegistry) -> ParserConfig {
    let mut parser = ParserConfig::default();
    parser.destination_aliases.clear();
    for definition in &registry.config().destinations {
        let key = DestinationKey::new(definition.id.as_str());
        parser.destination_aliases.push(DestinationAlias {
            alias: definition.id.as_str().to_string(),
            key: key.clone(),
        });
        parser.destination_aliases.push(DestinationAlias {
            alias: definition.display_name.clone(),
            key: key.clone(),
        });
        for alias in &definition.aliases {
            parser.destination_aliases.push(DestinationAlias {
                alias: alias.clone(),
                key: key.clone(),
            });
        }
    }
    parser
}

fn queued_position(events: &[QueueEvent]) -> Option<usize> {
    events.iter().find_map(|event| match event {
        QueueEvent::RequestQueued { position, .. } => Some(*position),
        _ => None,
    })
}

fn env_value(name: &str, default_value: &str) -> String {
    env::var(name)
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| default_value.to_string())
}

fn env_path(name: &str) -> Result<PathBuf, String> {
    env::var(name)
        .map(PathBuf::from)
        .map_err(|_| format!("missing {name}"))
}

fn make_run_dir() -> Result<PathBuf, String> {
    let root = env::var("WOW112_TELE08_ROUNDTRIP_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele08_roundtrip_runs"));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let dir = root.join(format!("run_{}-{:03}", now.as_secs(), now.subsec_millis()));
    fs::create_dir_all(&dir)
        .map_err(|e| format!("create run dir {} failed: {e}", dir.display()))?;
    Ok(dir)
}

fn sanitize(value: &str) -> String {
    value.replace('\r', " ").replace('\n', " ")
}

fn write_state(path: &Path, state: &str, role: &str, detail: &str) -> Result<(), String> {
    let body = format!(
        "state={state}\nrole={role}\ndetail={}\n",
        sanitize(detail)
    );
    let temp = path.with_extension("tmp");
    fs::write(&temp, body).map_err(|e| format!("write state temp failed: {e}"))?;
    fs::rename(&temp, path).map_err(|e| format!("publish state failed: {e}"))
}

fn read_state(path: &Path) -> Option<(String, String)> {
    let raw = fs::read_to_string(path).ok()?;
    let mut state = None;
    let mut detail = String::new();
    for line in raw.lines() {
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "state" => state = Some(value.trim().to_string()),
                "detail" => detail = value.trim().to_string(),
                _ => {}
            }
        }
    }
    state.map(|s| (s, detail))
}

mod live {
    include!("../world_tele.rs");

    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::{
        classify_whisper, classification_to_request, healthy_registry, parser_config_from_registry,
        queue_from_registry, queued_position, ResponseContext, ResponseEngine, ResponseEngineConfig,
        WhisperObservation, EXPECTED_DESTINATION, EXPECTED_REPLY, REQUEST_TEXT,
    };

    pub fn login_and_roundtrip(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: &str,
        role_label: &str,
        state_path: &Path,
        go_file: &Path,
        done_file: &Path,
        local_guid_file: &Path,
        customer_guid_file: &Path,
        summoner_guid_file: &Path,
        transcript_file: &Path,
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
                if matches!(*response, SMSG_AUTH_RESPONSE::AuthOk { .. }) {
                    auth_ok = true;
                }
                break;
            }
        }
        if !auth_ok {
            return Err("world auth did not return AuthOk".to_string());
        }

        CMSG_CHAR_ENUM {}
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|e| format!("write char enum failed: {e:?}"))?;
        let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
            &mut *stream,
            crypto.decrypter(),
        )
        .map_err(|e| format!("read char enum failed: {e:?}"))?;
        let selected = if character_name.eq_ignore_ascii_case("__FIRST__") {
            characters
                .characters
                .first()
                .ok_or_else(|| "character list empty".to_string())?
        } else {
            characters
                .characters
                .iter()
                .find(|c| c.name.eq_ignore_ascii_case(character_name))
                .ok_or_else(|| format!("character not found: {character_name}"))?
        };
        tele_trace::set_local_guid(selected.guid.guid());
        fs::write(
            local_guid_file,
            format!("guid={}\nname={}\n", selected.guid.guid(), selected.name),
        )
        .map_err(|e| format!("write guid sidecar failed: {e}"))?;
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
            return Err("SMSG_LOGIN_VERIFY_WORLD not received".to_string());
        }

        crate::write_state(state_path, "READY", role_label, "LOGIN_VERIFY_WORLD")?;
        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .map_err(|e| format!("set live timeout failed: {e}"))?;
        wait_for_file(stream, &mut crypto, role_label, go_file, done_file)?;

        match role_label {
            "CUSTOMER" => customer_loop(
                stream,
                &mut crypto,
                role_label,
                state_path,
                done_file,
                summoner_guid_file,
                transcript_file,
            ),
            "SUMMONER" => summoner_loop(
                stream,
                &mut crypto,
                role_label,
                state_path,
                done_file,
                customer_guid_file,
                transcript_file,
            ),
            _ => Err(format!("unsupported role {role_label}")),
        }
    }

    fn customer_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        done_file: &Path,
        summoner_guid_file: &Path,
        transcript_file: &Path,
    ) -> Result<(), String> {
        let (summoner_guid, summoner_name) = read_guid_meta(summoner_guid_file)?;
        tele_send_whisper(stream, crypto, &summoner_name, REQUEST_TEXT)?;
        println!(
            "[TELE08-ROUNDTRIP:CUSTOMER] TX target={:?} text={:?}",
            summoner_name, REQUEST_TEXT
        );

        let deadline = Instant::now() + Duration::from_secs(crate::LIVE_TIMEOUT_SECS);
        let mut keepalive = Keepalive::new();
        loop {
            keepalive.maybe_send(stream, crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if keepalive.handle_pong(opcode, &payload) {
                        continue;
                    }
                    if opcode != SMSG_MESSAGECHAT_OPCODE {
                        continue;
                    }
                    let message = match parse_raw_server_message(opcode, &payload) {
                        Ok(message) => message,
                        Err(_) => continue,
                    };
                    if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            if sender2.guid() != summoner_guid {
                                continue;
                            }
                            println!(
                                "[TELE08-ROUNDTRIP:CUSTOMER] RX sender={:?} text={:?}",
                                summoner_name, chat.message
                            );
                            if chat.message != EXPECTED_REPLY {
                                return Err(format!(
                                    "reply mismatch expected={EXPECTED_REPLY:?} actual={:?}",
                                    chat.message
                                ));
                            }
                            append_transcript(
                                transcript_file,
                                &format!("CUSTOMER_RX\t{}\t{}\n", summoner_name, chat.message),
                            )?;
                            crate::write_state(
                                state_path,
                                "PASS",
                                role_label,
                                "received exact E response from real server whisper",
                            )?;
                            wait_for_done(stream, crypto, role_label, done_file)?;
                            return Ok(());
                        }
                    }
                }
                Err(error) if transient_read(&error) => {}
                Err(error) => return Err(error),
            }
            if Instant::now() >= deadline {
                return Err("customer timed out waiting for response whisper".to_string());
            }
        }
    }

    fn summoner_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        done_file: &Path,
        customer_guid_file: &Path,
        transcript_file: &Path,
    ) -> Result<(), String> {
        let (customer_guid, customer_name) = read_guid_meta(customer_guid_file)?;
        let registry = healthy_registry()?;
        let parser = parser_config_from_registry(&registry);
        let mut queue = queue_from_registry(&registry)?;
        let mut engine = ResponseEngine::new(ResponseEngineConfig::default());
        let deadline = Instant::now() + Duration::from_secs(crate::LIVE_TIMEOUT_SECS);
        let mut keepalive = Keepalive::new();

        loop {
            keepalive.maybe_send(stream, crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if keepalive.handle_pong(opcode, &payload) {
                        continue;
                    }
                    if opcode != SMSG_MESSAGECHAT_OPCODE {
                        continue;
                    }
                    let message = match parse_raw_server_message(opcode, &payload) {
                        Ok(message) => message,
                        Err(_) => continue,
                    };
                    if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            if sender2.guid() != customer_guid {
                                continue;
                            }
                            if chat.message != REQUEST_TEXT {
                                return Err(format!(
                                    "request mismatch expected={REQUEST_TEXT:?} actual={:?}",
                                    chat.message
                                ));
                            }

                            let classification = classify_whisper(
                                &WhisperObservation {
                                    sender: customer_name.clone(),
                                    text: chat.message.clone(),
                                    timestamp_ms: unix_ms(),
                                    source_role: Some("SUMMONER_FULL_ROUNDTRIP".into()),
                                    destination_context: None,
                                },
                                &parser,
                            );
                            let request = classification_to_request(&classification)
                                .map_err(|e| format!("B->C admission rejected: {e:?}"))?;
                            if request.destination != EXPECTED_DESTINATION {
                                return Err(format!(
                                    "B destination mismatch expected={} actual={}",
                                    EXPECTED_DESTINATION, request.destination
                                ));
                            }

                            let destination_id = registry
                                .resolve_destination(&request.destination)
                                .ok_or_else(|| format!("D unresolved {}", request.destination))?;
                            let status = registry
                                .status(&destination_id)
                                .ok_or_else(|| "D status missing".to_string())?;
                            if status.availability != crate::Availability::Enabled {
                                return Err(format!("D unavailable: {:?}", status.availability));
                            }

                            let outcome = queue.enqueue(request);
                            if !outcome.accepted {
                                return Err(format!("C enqueue rejected: {outcome:?}"));
                            }
                            let position = queued_position(&outcome.events)
                                .ok_or_else(|| "C emitted no queued position".to_string())?;
                            let queue_len = queue.queued_count_by_destination(EXPECTED_DESTINATION);

                            let mut decisions = engine.handle_context(
                                ResponseContext::RequestQueued {
                                    recipient: customer_name.clone(),
                                    destination: EXPECTED_DESTINATION.into(),
                                    queue_position: Some(position),
                                    queue_length: Some(queue_len),
                                },
                                100,
                            );
                            if decisions.len() != 1 {
                                return Err(format!("E decision count={}", decisions.len()));
                            }
                            let decision = decisions.remove(0);
                            if !decision.should_send || decision.text != EXPECTED_REPLY {
                                return Err(format!("E decision mismatch: {decision:?}"));
                            }

                            append_transcript(
                                transcript_file,
                                &format!(
                                    "SUMMONER_CHAIN\tB={:?}\tC=queued:{}\tD={:?}\tE={}\n",
                                    classification.intent,
                                    position,
                                    status.availability,
                                    decision.text
                                ),
                            )?;
                            tele_send_whisper(stream, crypto, &customer_name, &decision.text)?;
                            println!(
                                "[TELE08-ROUNDTRIP:SUMMONER] TX target={:?} text={:?}",
                                customer_name, decision.text
                            );
                            crate::write_state(
                                state_path,
                                "PASS",
                                role_label,
                                "B>C>D>E decision sent through real CMSG_MESSAGECHAT",
                            )?;
                            wait_for_done(stream, crypto, role_label, done_file)?;
                            return Ok(());
                        }
                    }
                }
                Err(error) if transient_read(&error) => {}
                Err(error) => return Err(error),
            }
            if Instant::now() >= deadline {
                return Err("summoner timed out waiting for request whisper".to_string());
            }
        }
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
        fn maybe_send(&mut self, stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<(), String> {
            if let Some((sequence, sent_at)) = self.awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("pong timeout sequence={sequence}"));
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
            if self.awaiting_pong.map(|v| v.0) == Some(sequence) {
                self.awaiting_pong = None;
            }
            true
        }
        fn poll(&mut self, stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<(), String> {
            self.maybe_send(stream, crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    self.handle_pong(opcode, &payload);
                    Ok(())
                }
                Err(error) if transient_read(&error) => Ok(()),
                Err(error) => Err(error),
            }
        }
    }

    fn wait_for_file(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        go_file: &Path,
        done_file: &Path,
    ) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(crate::READY_TIMEOUT_SECS);
        let mut keepalive = Keepalive::new();
        while !go_file.exists() {
            if done_file.exists() {
                return Err(format!("{role_label}: DONE before GO"));
            }
            keepalive.poll(stream, crypto)?;
            if Instant::now() >= deadline {
                return Err(format!("{role_label}: GO timeout"));
            }
        }
        Ok(())
    }

    fn wait_for_done(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        done_file: &Path,
    ) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut keepalive = Keepalive::new();
        while !done_file.exists() {
            keepalive.poll(stream, crypto)?;
            if Instant::now() >= deadline {
                return Err(format!("{role_label}: DONE timeout"));
            }
        }
        Ok(())
    }

    fn read_guid_meta(path: &Path) -> Result<(u64, String), String> {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Ok(raw) = fs::read_to_string(path) {
                let mut guid = None;
                let mut name = None;
                for line in raw.lines() {
                    if let Some((key, value)) = line.split_once('=') {
                        match key {
                            "guid" => guid = value.trim().parse::<u64>().ok(),
                            "name" => name = Some(value.trim().to_string()),
                            _ => {}
                        }
                    }
                }
                if let (Some(guid), Some(name)) = (guid, name.filter(|v| !v.is_empty())) {
                    return Ok((guid, name));
                }
            }
            if Instant::now() >= deadline {
                return Err(format!("guid sidecar timeout: {}", path.display()));
            }
            thread::sleep(Duration::from_millis(100));
        }
    }

    fn append_transcript(path: &Path, line: &str) -> Result<(), String> {
        use std::fs::OpenOptions;
        use std::io::Write;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| format!("open transcript failed: {e}"))?;
        file.write_all(line.as_bytes())
            .map_err(|e| format!("write transcript failed: {e}"))?;
        file.flush().map_err(|e| format!("flush transcript failed: {e}"))
    }

    fn unix_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u64::MAX as u128) as u64
    }

    fn transient_read(error: &str) -> bool {
        error.contains("TimedOut") || error.contains("timed out") || error.contains("WouldBlock")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_chain_offline_contract() {
        self_test().unwrap();
    }
}
