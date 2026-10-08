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
#[path = "../tele08_whisper_parser.rs"]
mod tele08_whisper_parser;
#[path = "../wire_build.rs"]
mod wire_build;

use tele08_whisper_parser::{ParserConfig, WhisperObservation};
use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const READY_TIMEOUT_SECS: u64 = 180;
const LIVE_TIMEOUT_SECS: u64 = 120;
const SEND_GAP_MS: u64 = 2500;

#[derive(Clone, Copy, Debug)]
struct RoleSpec {
    label: &'static str,
    account: &'static str,
    character: &'static str,
    mode: &'static str,
}

const ROLES: [RoleSpec; 4] = [
    RoleSpec {
        label: "CUSTOMER",
        account: "octowar1",
        character: "Smokinpole",
        mode: "sender",
    },
    RoleSpec {
        label: "SLAVE1",
        account: "taxi2",
        character: "__FIRST__",
        mode: "sender_tail",
    },
    RoleSpec {
        label: "SLAVE2",
        account: "octowinter2",
        character: "Wintertwoo",
        mode: "passive",
    },
    RoleSpec {
        label: "SUMMONER",
        account: "taxi3",
        character: "Teletanaris",
        mode: "listener",
    },
];

#[derive(Clone, Copy, Debug)]
struct LiveCase {
    id: u32,
    text: &'static str,
    expected_intent: &'static str,
    expected_destination: Option<&'static str>,
}

const CASES: [LiveCase; 12] = [
    LiveCase { id: 1, text: "+", expected_intent: "GenericPositive", expected_destination: None },
    LiveCase { id: 2, text: "+ hyjal", expected_intent: "GenericPositive", expected_destination: Some("hyjal") },
    LiveCase { id: 3, text: "inv pls", expected_intent: "InviteRequest", expected_destination: None },
    LiveCase { id: 4, text: "invi", expected_intent: "InviteRequest", expected_destination: None },
    LiveCase { id: 5, text: "I need one", expected_intent: "SummonRequest", expected_destination: None },
    LiveCase { id: 6, text: "here", expected_intent: "PresenceReady", expected_destination: None },
    LiveCase { id: 7, text: "winterspring pls", expected_intent: "SummonRequest", expected_destination: Some("winterspring") },
    LiveCase { id: 8, text: "do you have feralas?", expected_intent: "DestinationQuery", expected_destination: None },
    LiveCase { id: 9, text: "selling summons cheaper today", expected_intent: "CompetitionMessage", expected_destination: None },
    LiveCase { id: 10, text: "what level are you?", expected_intent: "Irrelevant", expected_destination: None },
    LiveCase { id: 11, text: "sumon plz???", expected_intent: "Unknown", expected_destination: None },
    LiveCase { id: 12, text: "azshara please", expected_intent: "SummonRequest", expected_destination: Some("azshara") },
];

#[derive(Clone, Debug)]
struct CaseResult {
    id: u32,
    raw_text: String,
    expected_intent: String,
    actual_intent: String,
    expected_destination: Option<String>,
    actual_destination: Option<String>,
    sender: String,
    pass: bool,
    reason: String,
}

#[derive(Debug)]
struct ManagedRole {
    spec: RoleSpec,
    child: Child,
    state_path: PathBuf,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE08-B-LIVE] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if let Some(index) = args.iter().position(|arg| arg == "--role") {
        let label = args.get(index + 1).ok_or_else(|| "--role requires a value".to_string())?;
        return run_role(label);
    }

    if args.iter().any(|arg| arg == "--self-test") {
        return run_self_test();
    }

    run_orchestrator()
}

fn run_self_test() -> Result<(), String> {
    if CASES.len() != 12 {
        return Err(format!("expected 12 live cases, got {}", CASES.len()));
    }
    if role_spec("CUSTOMER").map(|r| r.character) != Some("Smokinpole") {
        return Err("role table CUSTOMER contract failed".to_string());
    }
    if role_spec("SUMMONER").map(|r| r.character) != Some("Teletanaris") {
        return Err("role table SUMMONER contract failed".to_string());
    }

    for case in CASES {
        let observation = WhisperObservation {
            sender: "Smokinpole".into(),
            text: case.text.into(),
            timestamp_ms: 1,
            source_role: Some("SUMMONER".into()),
            destination_context: None,
        };
        let classification =
            tele08_whisper_parser::classify_whisper(&observation, &ParserConfig::default());
        let actual_intent = format!("{:?}", classification.intent);
        let actual_destination = classification.destination.as_ref().map(|value| value.0.as_str());
        if actual_intent != case.expected_intent
            || actual_destination != case.expected_destination
        {
            return Err(format!(
                "case {} offline contract mismatch text={:?} expected={}/{} actual={}/{}",
                case.id,
                case.text,
                case.expected_intent,
                case.expected_destination.unwrap_or("-"),
                actual_intent,
                actual_destination.unwrap_or("-")
            ));
        }
    }

    println!("TELE08 B LIVE HARNESS SELFTEST PASS cases={}", CASES.len());
    Ok(())
}

fn role_spec(label: &str) -> Option<RoleSpec> {
    ROLES.iter()
        .copied()
        .find(|spec| spec.label.eq_ignore_ascii_case(label))
}

fn role_env_name(label: &str, suffix: &str) -> String {
    format!("WOW112_TELE08_{}_{}", label, suffix)
}

fn resolved_role_spec(base: RoleSpec) -> RoleSpecOwned {
    let account = env::var(role_env_name(base.label, "ACCOUNT"))
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| base.account.to_string());
    let character = env::var(role_env_name(base.label, "CHARACTER"))
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| base.character.to_string());
    RoleSpecOwned {
        label: base.label.to_string(),
        account,
        character,
        mode: base.mode.to_string(),
    }
}

#[derive(Clone, Debug)]
struct RoleSpecOwned {
    label: String,
    account: String,
    character: String,
    mode: String,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn run_id() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{:03}", now.as_secs(), now.subsec_millis())
}

fn write_state(path: &Path, state: &str, role: &str, detail: &str) -> Result<(), String> {
    let safe_detail = detail.replace('\r', " ").replace('\n', " ");
    let body = format!(
        "state={state}\nrole={role}\ndetail={safe_detail}\ntimestamp_ms={}\n",
        now_ms()
    );
    let temp = path.with_extension("tmp");
    fs::write(&temp, body).map_err(|e| format!("write state temp {} failed: {e}", temp.display()))?;
    fs::rename(&temp, path).map_err(|e| format!("publish state {} failed: {e}", path.display()))
}

fn read_state(path: &Path) -> Option<(String, String)> {
    let text = fs::read_to_string(path).ok()?;
    let mut state = None;
    let mut detail = String::new();
    for line in text.lines() {
        if let Some((key, value)) = line.split_once('=') {
            match key.trim() {
                "state" => state = Some(value.trim().to_string()),
                "detail" => detail = value.trim().to_string(),
                _ => {}
            }
        }
    }
    state.map(|value| (value, detail))
}

fn orchestrator_run_dir() -> Result<PathBuf, String> {
    let root = env::var("WOW112_TELE08_RUN_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele08_b_live_runs"));
    let dir = root.join(format!("run_{}", run_id()));
    fs::create_dir_all(&dir)
        .map_err(|e| format!("create run dir {} failed: {e}", dir.display()))?;
    Ok(dir)
}

fn spawn_role(
    exe: &Path,
    run_dir: &Path,
    password: &str,
    spec: RoleSpec,
) -> Result<ManagedRole, String> {
    let state_path = run_dir.join(format!("STATE_{}.txt", spec.label));
    let stdout_path = run_dir.join(format!("{}.stdout.log", spec.label));
    let stderr_path = run_dir.join(format!("{}.stderr.log", spec.label));
    let stdout = File::create(&stdout_path)
        .map_err(|e| format!("create {} failed: {e}", stdout_path.display()))?;
    let stderr = File::create(&stderr_path)
        .map_err(|e| format!("create {} failed: {e}", stderr_path.display()))?;

    let go_file = run_dir.join("GO");
    let done_file = run_dir.join("DONE");
    let result_file = run_dir.join("RESULTS.json");
    let local_guid_file = run_dir.join(format!("GUID_{}.txt", spec.label));
    let expected_sender_guid_file = run_dir.join("GUID_CUSTOMER.txt");
    let expected_sender2_guid_file = run_dir.join("GUID_SLAVE1.txt");
    let ack_file = run_dir.join("ACK_COUNT.txt");

    let mut command = Command::new(exe);
    command
        .arg("--role")
        .arg(spec.label)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_TELE08_STATE_FILE", &state_path)
        .env("WOW112_TELE08_GO_FILE", &go_file)
        .env("WOW112_TELE08_DONE_FILE", &done_file)
        .env("WOW112_TELE08_RESULT_FILE", &result_file)
        .env("WOW112_TELE08_LOCAL_GUID_FILE", &local_guid_file)
        .env("WOW112_TELE08_EXPECTED_SENDER_GUID_FILE", &expected_sender_guid_file)
        .env("WOW112_TELE08_EXPECTED_SENDER2_GUID_FILE", &expected_sender2_guid_file)
        .env("WOW112_TELE08_ACK_FILE", &ack_file)
        .env("WOW112_TELE08_EXPECTED_SENDER", resolved_role_spec(ROLES[0]).character)
        .env("WOW112_TELE08_TARGET", resolved_role_spec(ROLES[3]).character);

    let child = command
        .spawn()
        .map_err(|e| format!("spawn {} failed: {e}", spec.label))?;

    Ok(ManagedRole {
        spec,
        child,
        state_path,
        stdout_path,
        stderr_path,
    })
}

fn run_orchestrator() -> Result<(), String> {
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    if password.is_empty() {
        return Err("WOW112_PASSWORD is empty".to_string());
    }

    let exe = env::current_exe().map_err(|e| format!("current_exe failed: {e}"))?;
    let run_dir = orchestrator_run_dir()?;

    println!(
        "[TELE08-B-LIVE] run_dir={} binary-build=5875 wire-build={} cases={} mutations=chat_only",
        run_dir.display(),
        OCTOWOW_WIRE_BUILD,
        CASES.len()
    );

    let mut roles = Vec::new();
    for spec in ROLES {
        roles.push(spawn_role(&exe, &run_dir, &password, spec)?);
    }

    let outcome = orchestrate(&run_dir, &mut roles);
    let _ = fs::write(run_dir.join("DONE"), b"done\n");
    for role in &mut roles {
        if role.child.try_wait().ok().flatten().is_none() {
            let _ = role.child.kill();
        }
        let _ = role.child.wait();
    }

    match outcome {
        Ok(()) => {
            let summary = format!(
                "TELE08 B LIVE E2E PASS\ncases={}\nroles=4/4\nresult={}\n",
                CASES.len(),
                run_dir.join("RESULTS.json").display()
            );
            fs::write(run_dir.join("SUMMARY.txt"), &summary)
                .map_err(|e| format!("write summary failed: {e}"))?;
            println!("{summary}");
            Ok(())
        }
        Err(error) => {
            let mut evidence = String::new();
            evidence.push_str("TELE08 B LIVE E2E FAIL\n");
            evidence.push_str(&format!("reason={error}\n"));
            for role in &roles {
                let state = read_state(&role.state_path)
                    .map(|(s, d)| format!("{s}: {d}"))
                    .unwrap_or_else(|| "NO_STATE".to_string());
                evidence.push_str(&format!(
                    "{} state={} stdout={} stderr={}\n",
                    role.spec.label,
                    state,
                    role.stdout_path.display(),
                    role.stderr_path.display()
                ));
            }
            let _ = fs::write(run_dir.join("SUMMARY.txt"), &evidence);
            Err(format!("{error}; evidence={}", run_dir.display()))
        }
    }
}

fn orchestrate(run_dir: &Path, roles: &mut [ManagedRole]) -> Result<(), String> {
    let ready_deadline = Instant::now() + Duration::from_secs(READY_TIMEOUT_SECS);
    loop {
        let mut ready = 0usize;
        for role in roles.iter_mut() {
            if let Some(status) = role.child.try_wait().map_err(|e| e.to_string())? {
                return Err(format!(
                    "{} exited before READY status={status}",
                    role.spec.label
                ));
            }
            if read_state(&role.state_path)
                .map(|(state, _)| state == "READY")
                .unwrap_or(false)
            {
                ready += 1;
            }
        }
        if ready == roles.len() {
            println!("[TELE08-B-LIVE] 4/4 READY");
            break;
        }
        if Instant::now() >= ready_deadline {
            return Err(format!("READY timeout: {ready}/{} roles ready", roles.len()));
        }
        thread::sleep(Duration::from_millis(250));
    }

    fs::write(run_dir.join("GO"), b"go\n")
        .map_err(|e| format!("write GO failed: {e}"))?;
    println!("[TELE08-B-LIVE] GO cases={}", CASES.len());

    let live_deadline = Instant::now() + Duration::from_secs(LIVE_TIMEOUT_SECS);
    loop {
        for role in roles.iter_mut() {
            if let Some(status) = role.child.try_wait().map_err(|e| e.to_string())? {
                return Err(format!(
                    "{} exited during live test status={status}",
                    role.spec.label
                ));
            }
            if let Some((state, detail)) = read_state(&role.state_path) {
                if state == "FAIL" {
                    return Err(format!("{} FAIL: {detail}", role.spec.label));
                }
            }
        }

        let summoner = roles
            .iter()
            .find(|role| role.spec.label == "SUMMONER")
            .ok_or_else(|| "SUMMONER role missing".to_string())?;
        if let Some((state, detail)) = read_state(&summoner.state_path) {
            if state == "PASS" {
                println!("[TELE08-B-LIVE] SUMMONER PASS detail={detail}");
                if !run_dir.join("RESULTS.json").exists() {
                    return Err("SUMMONER PASS without RESULTS.json".to_string());
                }
                return Ok(());
            }
        }

        if Instant::now() >= live_deadline {
            return Err("live whisper/classification timeout".to_string());
        }
        thread::sleep(Duration::from_millis(250));
    }
}

fn run_role(label: &str) -> Result<(), String> {
    let base = role_spec(label).ok_or_else(|| format!("unknown role {label:?}"))?;
    let spec = resolved_role_spec(base);

    let state_path = env::var("WOW112_TELE08_STATE_FILE")
        .map(PathBuf::from)
        .map_err(|_| "missing WOW112_TELE08_STATE_FILE".to_string())?;
    let go_file = env::var("WOW112_TELE08_GO_FILE")
        .map(PathBuf::from)
        .map_err(|_| "missing WOW112_TELE08_GO_FILE".to_string())?;
    let done_file = env::var("WOW112_TELE08_DONE_FILE")
        .map(PathBuf::from)
        .map_err(|_| "missing WOW112_TELE08_DONE_FILE".to_string())?;
    let result_file = env::var("WOW112_TELE08_RESULT_FILE")
        .map(PathBuf::from)
        .map_err(|_| "missing WOW112_TELE08_RESULT_FILE".to_string())?;
    let expected_sender = env::var("WOW112_TELE08_EXPECTED_SENDER")
        .map_err(|_| "missing WOW112_TELE08_EXPECTED_SENDER".to_string())?;
    let target = env::var("WOW112_TELE08_TARGET")
        .map_err(|_| "missing WOW112_TELE08_TARGET".to_string())?;
    let password = env::var(role_env_name(&spec.label, "PASSWORD"))
        .or_else(|_| env::var("WOW112_PASSWORD"))
        .map_err(|_| format!("missing password for {}", spec.label))?;

    write_state(&state_path, "CONNECTING", &spec.label, "auth")?;

    let auth_addr = env::var("WOW112_AUTH_ADDR")
        .unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);

    let role_result = run_role_session(
        &spec,
        &password,
        &auth_addr,
        realm_index,
        &state_path,
        &go_file,
        &done_file,
        &result_file,
        &expected_sender,
        &target,
    );

    if let Err(error) = &role_result {
        let _ = write_state(&state_path, "FAIL", &spec.label, error);
    }
    role_result
}

fn run_role_session(
    spec: &RoleSpecOwned,
    password: &str,
    auth_addr: &str,
    realm_index: usize,
    state_path: &Path,
    go_file: &Path,
    done_file: &Path,
    result_file: &Path,
    expected_sender: &str,
    target: &str,
) -> Result<(), String> {
    println!(
        "[TELE08-B-LIVE:{}] auth={} account={} character={} mode={}",
        spec.label, auth_addr, spec.account, spec.character, spec.mode
    );
    let mut auth_stream = TcpStream::connect(auth_addr)
        .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let username = spec.account.to_ascii_uppercase();
    let (session_key, realms) = auth::authenticate(&mut auth_stream, &username, password)?;
    if realms.realms.is_empty() {
        return Err("auth succeeded but realm list is empty".to_string());
    }
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|e| format!("world connect {world_addr} failed: {e}"))?;

    live::login_and_run(
        &mut world_stream,
        session_key,
        realm.realm_id,
        &username,
        &spec.character,
        &spec.label,
        &spec.mode,
        state_path,
        go_file,
        done_file,
        result_file,
        expected_sender,
        target,
    )
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 8);
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn write_results(path: &Path, results: &[CaseResult]) -> Result<(), String> {
    let pass_count = results.iter().filter(|result| result.pass).count();
    let overall = pass_count == CASES.len() && results.len() == CASES.len();

    let mut json = String::new();
    json.push_str("{\n");
    json.push_str("  \"suite\": \"TELE08_B_LIVE_E2E\",\n");
    json.push_str(&format!("  \"overall\": \"{}\",\n", if overall { "PASS" } else { "FAIL" }));
    json.push_str(&format!("  \"expected_cases\": {},\n", CASES.len()));
    json.push_str(&format!("  \"received_cases\": {},\n", results.len()));
    json.push_str(&format!("  \"passed_cases\": {},\n", pass_count));
    json.push_str("  \"cases\": [\n");
    for (index, result) in results.iter().enumerate() {
        let comma = if index + 1 == results.len() { "" } else { "," };
        let expected_destination = result
            .expected_destination
            .as_deref()
            .map(|value| format!("\"{}\"", json_escape(value)))
            .unwrap_or_else(|| "null".to_string());
        let actual_destination = result
            .actual_destination
            .as_deref()
            .map(|value| format!("\"{}\"", json_escape(value)))
            .unwrap_or_else(|| "null".to_string());
        json.push_str(&format!(
            "    {{\"id\":{},\"raw_text\":\"{}\",\"sender\":\"{}\",\"expected_intent\":\"{}\",\"actual_intent\":\"{}\",\"expected_destination\":{},\"actual_destination\":{},\"pass\":{},\"reason\":\"{}\"}}{}\n",
            result.id,
            json_escape(&result.raw_text),
            json_escape(&result.sender),
            json_escape(&result.expected_intent),
            json_escape(&result.actual_intent),
            expected_destination,
            actual_destination,
            if result.pass { "true" } else { "false" },
            json_escape(&result.reason),
            comma
        ));
    }
    json.push_str("  ]\n}\n");

    fs::write(path, json).map_err(|e| format!("write results {} failed: {e}", path.display()))
}

mod live {
    include!("../world_tele.rs");

    use std::collections::HashMap;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::tele08_whisper_parser::{ParserConfig, WhisperObservation};

    pub fn login_and_run(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: &str,
        role_label: &str,
        role_mode: &str,
        state_path: &Path,
        go_file: &Path,
        done_file: &Path,
        result_file: &Path,
        expected_sender: &str,
        target: &str,
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

        let auth_response = {
            let mut found = None;
            for _ in 0..16usize {
                let opcode =
                    ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                        .map_err(|e| format!("read world pre-auth opcode failed: {e:?}"))?;
                if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) = opcode {
                    found = Some(response);
                    break;
                }
            }
            found.ok_or_else(|| "world auth response not received within 16 packets".to_string())?
        };

        if !matches!(*auth_response, SMSG_AUTH_RESPONSE::AuthOk { .. }) {
            return Err(format!("world auth rejected: {auth_response:?}"));
        }

        CMSG_CHAR_ENUM {}
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|e| format!("write character enum request failed: {e:?}"))?;
        let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
            &mut *stream,
            crypto.decrypter(),
        )
        .map_err(|e| format!("read character enum failed: {e:?}"))?;

        let selected = if character_name.eq_ignore_ascii_case("__FIRST__") {
            characters
                .characters
                .first()
                .ok_or_else(|| "character list empty".to_string())?
        } else {
            characters
                .characters
                .iter()
                .find(|character| character.name.eq_ignore_ascii_case(character_name))
                .ok_or_else(|| format!("character not found: {character_name}"))?
        };
        println!("[TELE08-B-LIVE:{role_label}] selected_character={}", selected.name);

        tele_trace::set_local_guid(selected.guid.guid());
        if let Ok(path) = std::env::var("WOW112_TELE08_LOCAL_GUID_FILE") {
            let body = format!("guid={}\nname={}\n", selected.guid.guid(), selected.name);
            std::fs::write(&path, body)
                .map_err(|e| format!("write local guid file {path} failed: {e}"))?;
        }
        CMSG_PLAYER_LOGIN { guid: selected.guid }
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|e| format!("write player login failed: {e:?}"))?;

        let mut login_verified = false;
        for _ in 0..256usize {
            let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read world opcode before login verify failed: {e:?}"))?;
            if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
                login_verified = true;
                break;
            }
        }
        if !login_verified {
            return Err("SMSG_LOGIN_VERIFY_WORLD not received within 256 packets".to_string());
        }

        crate::write_state(state_path, "READY", role_label, "LOGIN_VERIFY_WORLD")?;
        println!("[TELE08-B-LIVE:{role_label}] READY");

        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .map_err(|e| format!("set live read timeout failed: {e}"))?;

        match role_mode {
            "sender" | "sender_tail" => sender_loop(stream, &mut crypto, role_label, state_path, go_file, done_file, target),
            "listener" => listener_loop(
                stream,
                &mut crypto,
                role_label,
                state_path,
                go_file,
                done_file,
                result_file,
                expected_sender,
            ),
            "passive" => passive_loop(stream, &mut crypto, role_label, state_path, done_file),
            other => Err(format!("unknown role mode {other:?}")),
        }
    }

    fn wait_for_go_with_keepalive(
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
                return Err("DONE published before GO".to_string());
            }
            keepalive.poll(stream, crypto, role_label)?;
            if Instant::now() >= deadline {
                return Err("GO wait timeout".to_string());
            }
        }
        Ok(())
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

        fn poll(
            &mut self,
            stream: &mut TcpStream,
            crypto: &mut HeaderCrypto,
            role_label: &str,
        ) -> Result<(), String> {
            self.maybe_send(stream, crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if self.handle_pong(opcode, &payload) {
                        return Ok(());
                    }
                    if opcode == SMSG_MESSAGECHAT_OPCODE {
                        println!("[TELE08-B-LIVE:{role_label}] ignored chat while waiting/passive");
                    }
                    Ok(())
                }
                Err(error)
                    if error.contains("TimedOut")
                        || error.contains("timed out")
                        || error.contains("WouldBlock") =>
                {
                    Ok(())
                }
                Err(error) => Err(error),
            }
        }
    }

    fn sender_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        go_file: &Path,
        done_file: &Path,
        target: &str,
    ) -> Result<(), String> {
        wait_for_go_with_keepalive(stream, crypto, role_label, go_file, done_file)?;
        let (start_index, end_index) = if role_label.eq_ignore_ascii_case("CUSTOMER") {
            (0usize, 6usize)
        } else {
            (6usize, crate::CASES.len())
        };
        let ack_path = std::env::var("WOW112_TELE08_ACK_FILE")
            .map_err(|_| "missing WOW112_TELE08_ACK_FILE".to_string())?;
        if start_index > 0 {
            let phase_deadline = Instant::now() + Duration::from_secs(60);
            loop {
                let ack = std::fs::read_to_string(&ack_path)
                    .ok()
                    .and_then(|value| value.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if ack >= start_index {
                    println!("[TELE08-B-LIVE:{role_label}] phase-start ack={ack}");
                    break;
                }
                if Instant::now() >= phase_deadline {
                    return Err(format!("phase-start ACK timeout expected={} observed={ack}", start_index));
                }
                thread::sleep(Duration::from_millis(100));
            }
        }
        for case in crate::CASES[start_index..end_index].iter().copied() {
            tele_send_whisper(stream, crypto, target, case.text)?;
            println!(
                "[TELE08-B-LIVE:{role_label}] TX case={} target={:?} text={:?}",
                case.id, target, case.text
            );
            let ack_deadline = Instant::now() + Duration::from_secs(20);
            loop {
                let ack = std::fs::read_to_string(&ack_path)
                    .ok()
                    .and_then(|value| value.trim().parse::<u32>().ok())
                    .unwrap_or(0);
                if ack >= case.id {
                    println!("[TELE08-B-LIVE:{role_label}] ACK case={} count={ack}", case.id);
                    break;
                }
                if Instant::now() >= ack_deadline {
                    return Err(format!("ACK timeout case={} observed={ack}", case.id));
                }
                thread::sleep(Duration::from_millis(100));
            }
            thread::sleep(Duration::from_millis(crate::SEND_GAP_MS));
        }
        crate::write_state(
            state_path,
            "SENT",
            role_label,
            &format!("sent cases {}..{}", start_index + 1, end_index),
        )?;
        let mut keepalive = Keepalive::new();
        while !done_file.exists() {
            keepalive.poll(stream, crypto, role_label)?;
        }
        crate::write_state(state_path, "DONE", role_label, "orchestrator complete")?;
        Ok(())
    }

    fn passive_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        done_file: &Path,
    ) -> Result<(), String> {
        let mut keepalive = Keepalive::new();
        while !done_file.exists() {
            keepalive.poll(stream, crypto, role_label)?;
        }
        crate::write_state(state_path, "DONE", role_label, "orchestrator complete")?;
        Ok(())
    }

    fn observation_timestamp_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u64::MAX as u128) as u64
    }

    fn listener_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        go_file: &Path,
        done_file: &Path,
        result_file: &Path,
        expected_sender: &str,
    ) -> Result<(), String> {
        wait_for_go_with_keepalive(stream, crypto, role_label, go_file, done_file)?;
        let deadline = Instant::now() + Duration::from_secs(crate::LIVE_TIMEOUT_SECS);
        fn read_sender_meta(path_var: &str) -> Result<(u64, String), String> {
            let path = std::env::var(path_var)
                .map_err(|_| format!("missing {path_var}"))?;
            let meta = std::fs::read_to_string(&path)
                .map_err(|e| format!("read sender guid file {path} failed: {e}"))?;
            let mut guid = None;
            let mut name = None;
            for line in meta.lines() {
                if let Some((key, value)) = line.split_once('=') {
                    match key.trim() {
                        "guid" => guid = value.trim().parse::<u64>().ok(),
                        "name" => name = Some(value.trim().to_string()),
                        _ => {}
                    }
                }
            }
            Ok((
                guid.ok_or_else(|| format!("sender guid missing in {path}"))?,
                name.filter(|value| !value.is_empty()).unwrap_or_else(|| "UNKNOWN".to_string()),
            ))
        }

        let (direct_expected_guid, direct_expected_name) =
            read_sender_meta("WOW112_TELE08_EXPECTED_SENDER_GUID_FILE")?;
        let (direct_expected_guid2, direct_expected_name2) =
            read_sender_meta("WOW112_TELE08_EXPECTED_SENDER2_GUID_FILE")?;
        println!(
            "[TELE08-B-LIVE:{role_label}] direct_senders first=0x{direct_expected_guid:016X}/{direct_expected_name} second=0x{direct_expected_guid2:016X}/{direct_expected_name2}"
        );

        let mut keepalive = Keepalive::new();
        let mut name_cache: HashMap<u64, String> = HashMap::new();
        let mut pending: HashMap<u64, Vec<String>> = HashMap::new();
        let mut results: Vec<crate::CaseResult> = Vec::new();

        while results.len() < crate::CASES.len() {
            keepalive.maybe_send(stream, crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if keepalive.handle_pong(opcode, &payload) {
                        continue;
                    }

                    if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                        match tele_parse_name_query_response(&payload) {
                            Ok((guid, name)) => {
                                name_cache.insert(guid, name.clone());
                                if let Some(items) = pending.remove(&guid) {
                                    for text in items {
                                        if name.eq_ignore_ascii_case(expected_sender) {
                                            classify_case(&name, &text, &mut results)?;
                                        }
                                    }
                                }
                            }
                            Err(error) => println!(
                                "[TELE08-B-LIVE:{role_label}] name response skipped: {error}"
                            ),
                        }
                        continue;
                    }

                    if opcode != SMSG_MESSAGECHAT_OPCODE {
                        continue;
                    }

                    let message = match parse_raw_server_message(opcode, &payload) {
                        Ok(message) => message,
                        Err(error) => {
                            println!(
                                "[TELE08-B-LIVE:{role_label}] chat decode skipped: {error}"
                            );
                            continue;
                        }
                    };

                    if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            let guid = sender2.guid();
                            let text = chat.message;
                            let direct_name = if guid == direct_expected_guid {
                                Some(direct_expected_name.as_str())
                            } else if guid == direct_expected_guid2 {
                                Some(direct_expected_name2.as_str())
                            } else {
                                None
                            };
                            if let Some(name) = direct_name {
                                classify_case(name, &text, &mut results)?;
                                if let Ok(path) = std::env::var("WOW112_TELE08_ACK_FILE") {
                                    std::fs::write(&path, format!("{}\n", results.len()))
                                        .map_err(|e| format!("write ACK file {path} failed: {e}"))?;
                                }
                            } else if let Some(name) = name_cache.get(&guid).cloned() {
                                if name.eq_ignore_ascii_case(expected_sender) {
                                    classify_case(&name, &text, &mut results)?;
                                }
                            } else {
                                let first = !pending.contains_key(&guid);
                                pending.entry(guid).or_default().push(text);
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

            if Instant::now() >= deadline {
                crate::write_results(result_file, &results)?;
                return Err(format!(
                    "listener timeout received={}/{}",
                    results.len(),
                    crate::CASES.len()
                ));
            }
        }

        crate::write_results(result_file, &results)?;
        let failed = results.iter().filter(|result| !result.pass).count();
        if failed != 0 {
            crate::write_state(
                state_path,
                "FAIL",
                role_label,
                &format!("{failed} classification mismatches"),
            )?;
            return Err(format!("{failed} classification mismatches"));
        }

        crate::write_state(
            state_path,
            "PASS",
            role_label,
            &format!("{} real whisper classifications passed", results.len()),
        )?;

        while !done_file.exists() {
            keepalive.poll(stream, crypto, role_label)?;
        }
        Ok(())
    }

    fn classify_case(
        sender: &str,
        text: &str,
        results: &mut Vec<crate::CaseResult>,
    ) -> Result<(), String> {
        let index = results.len();
        let case = crate::CASES
            .get(index)
            .ok_or_else(|| format!("unexpected extra whisper from {sender}: {text:?}"))?;

        let observation = WhisperObservation {
            sender: sender.to_string(),
            text: text.to_string(),
            timestamp_ms: observation_timestamp_ms(),
            source_role: Some("SUMMONER".to_string()),
            destination_context: None,
        };
        let classification =
            crate::tele08_whisper_parser::classify_whisper(&observation, &ParserConfig::default());

        let actual_intent = format!("{:?}", classification.intent);
        let actual_destination = classification.destination.as_ref().map(|value| value.0.clone());
        let text_match = text == case.text;
        let intent_match = actual_intent == case.expected_intent;
        let destination_match =
            actual_destination.as_deref() == case.expected_destination;
        let pass = text_match && intent_match && destination_match;
        let reason = if pass {
            "transport_and_classification_match".to_string()
        } else {
            format!(
                "text_match={} intent_match={} destination_match={}",
                text_match, intent_match, destination_match
            )
        };

        println!(
            "[TELE08-B-LIVE:SUMMONER] CASE {} {} raw={:?} expected={}/{} actual={}/{}",
            case.id,
            if pass { "PASS" } else { "FAIL" },
            text,
            case.expected_intent,
            case.expected_destination.unwrap_or("-"),
            actual_intent,
            actual_destination.as_deref().unwrap_or("-")
        );

        results.push(crate::CaseResult {
            id: case.id,
            raw_text: text.to_string(),
            expected_intent: case.expected_intent.to_string(),
            actual_intent,
            expected_destination: case.expected_destination.map(str::to_string),
            actual_destination,
            sender: sender.to_string(),
            pass,
            reason,
        });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_case_contract_is_exactly_twelve_and_offline_green() {
        run_self_test().unwrap();
    }

    #[test]
    fn state_parser_round_trip() {
        let dir = env::temp_dir().join(format!("tele08_b_live_test_{}", now_ms()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.txt");
        write_state(&path, "READY", "CUSTOMER", "hello").unwrap();
        assert_eq!(
            read_state(&path),
            Some(("READY".to_string(), "hello".to_string()))
        );
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn json_escape_is_valid_for_core_control_chars() {
        assert_eq!(json_escape("a\"b\\c\n"), "a\\\"b\\\\c\\n");
    }
}

