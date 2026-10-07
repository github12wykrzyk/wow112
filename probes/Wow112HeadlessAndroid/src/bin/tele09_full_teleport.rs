use std::collections::HashMap;
use std::env;
use std::fs::{self, File};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "../auth.rs"]
mod auth;
#[path = "../wire_build.rs"]
mod wire_build;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const CUSTOMER_ACCOUNT: &str = "taxi1";
const CUSTOMER_CHARACTER: &str = "Feltaxi";
const SUMMONER_ACCOUNT: &str = "taxi3";
const SUMMONER_CHARACTER: &str = "Teletanaris";
const SLAVE1_ACCOUNT: &str = "octowinter1";
const SLAVE1_CHARACTER: &str = "Winterone";
const SLAVE2_ACCOUNT: &str = "octowinter2";
const SLAVE2_CHARACTER: &str = "Wintertwoo";
const READY_TIMEOUT: Duration = Duration::from_secs(180);
const ACTIVE_TIMEOUT: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_millis(250);

#[derive(Debug)]
struct ManagedChild {
    label: &'static str,
    child: Child,
    state_path: PathBuf,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE09-FULL-TELEPORT] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|arg| arg == "--customer") {
        return run_customer();
    }
    if args.iter().any(|arg| arg == "--self-test") {
        println!("TELE09_FULL_TELEPORT_SELFTEST_PASS build=5875 wire={OCTOWOW_WIRE_BUILD}");
        return Ok(());
    }
    run_orchestrator()
}

fn run_orchestrator() -> Result<(), String> {
    let password = env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    if password.trim().is_empty() {
        return Err("WOW112_PASSWORD is empty".to_string());
    }

    let exe = env::current_exe().map_err(|e| format!("current_exe failed: {e}"))?;
    let root = exe
        .parent()
        .ok_or_else(|| "runner executable has no parent directory".to_string())?
        .to_path_buf();
    for required in ["tele06a_acceptor_runtime.exe", "tele06a_ritual_runtime.exe"] {
        if !root.join(required).exists() {
            return Err(format!("missing required runtime {}", root.join(required).display()));
        }
    }

    let run_dir = make_run_dir()?;
    println!(
        "[TELE09-FULL-TELEPORT] run_dir={} customer={}/{} summoner={}/{}",
        run_dir.display(), CUSTOMER_ACCOUNT, CUSTOMER_CHARACTER, SUMMONER_ACCOUNT, SUMMONER_CHARACTER
    );

    let mut children: HashMap<String, ManagedChild> = HashMap::new();
    children.insert(
        "CUSTOMER".into(),
        spawn_customer(&exe, &run_dir, &password)?,
    );
    thread::sleep(Duration::from_millis(250));
    children.insert(
        "SLAVE1".into(),
        spawn_clicker(
            &root,
            &run_dir,
            &password,
            "SLAVE1",
            SLAVE1_ACCOUNT,
            SLAVE1_CHARACTER,
            150,
        )?,
    );
    thread::sleep(Duration::from_millis(250));
    children.insert(
        "SLAVE2".into(),
        spawn_clicker(
            &root,
            &run_dir,
            &password,
            "SLAVE2",
            SLAVE2_ACCOUNT,
            SLAVE2_CHARACTER,
            300,
        )?,
    );

    let outcome = (|| {
        wait_ready(&mut children)?;
        println!("[TELE09-FULL-TELEPORT] READY_GATE PASS 3/3");
        children.insert(
            "SUMMONER".into(),
            spawn_summoner(&root, &run_dir, &password)?,
        );
        monitor_full_teleport(&mut children)
    })();

    stop_all(&mut children);

    match outcome {
        Ok(detail) => {
            let status = format!(
                "result=PASS\nchain=party>ritual>portal_use>SMSG_SUMMON_REQUEST>CMSG_SUMMON_RESPONSE>SMSG_NEW_WORLD>MSG_MOVE_WORLDPORT_ACK\ncustomer_account={}\ncustomer_character={}\nsummoner={}\ndetail={}\n",
                CUSTOMER_ACCOUNT,
                CUSTOMER_CHARACTER,
                SUMMONER_CHARACTER,
                sanitize(&detail)
            );
            fs::write(run_dir.join("STATUS.txt"), &status)
                .map_err(|e| format!("write STATUS failed: {e}"))?;
            println!("TELE09_FULL_TELEPORT_PASS {detail}");
            Ok(())
        }
        Err(error) => {
            let mut status = format!("result=FAIL\nreason={}\n", sanitize(&error));
            for label in ["CUSTOMER", "SLAVE1", "SLAVE2", "SUMMONER"] {
                let path = run_dir.join(format!("STATE_{label}.txt"));
                status.push_str(&format!("{label}={}\n", read_state_text(&path)));
            }
            let _ = fs::write(run_dir.join("STATUS.txt"), status);
            Err(format!("{error}; evidence={}", run_dir.display()))
        }
    }
}

fn make_run_dir() -> Result<PathBuf, String> {
    let root = env::var("WOW112_TELE09_FULL_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("tele09_full_teleport_runs"));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let path = root.join(format!("run_{}-{:03}", now.as_secs(), now.subsec_millis()));
    fs::create_dir_all(&path).map_err(|e| format!("create run dir failed: {e}"))?;
    Ok(path)
}

fn spawn_customer(exe: &Path, run_dir: &Path, password: &str) -> Result<ManagedChild, String> {
    let state_path = run_dir.join("STATE_CUSTOMER.txt");
    let stdout_path = run_dir.join("CUSTOMER.stdout.log");
    let stderr_path = run_dir.join("CUSTOMER.stderr.log");
    let stdout = File::create(&stdout_path).map_err(|e| format!("customer stdout failed: {e}"))?;
    let stderr = File::create(&stderr_path).map_err(|e| format!("customer stderr failed: {e}"))?;
    let child = Command::new(exe)
        .arg("--customer")
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_ACCOUNT", CUSTOMER_ACCOUNT)
        .env("WOW112_CHARACTER", CUSTOMER_CHARACTER)
        .env("WOW112_REALM_INDEX", "1")
        .env("WOW112_TELE09_STATE_FILE", &state_path)
        .spawn()
        .map_err(|e| format!("spawn CUSTOMER failed: {e}"))?;
    Ok(ManagedChild {
        label: "CUSTOMER",
        child,
        state_path,
        stdout_path,
        stderr_path,
    })
}

fn spawn_clicker(
    root: &Path,
    run_dir: &Path,
    password: &str,
    label: &'static str,
    account: &str,
    character: &str,
    settle_ms: u64,
) -> Result<ManagedChild, String> {
    let state_path = run_dir.join(format!("STATE_{label}.txt"));
    let stdout_path = run_dir.join(format!("{label}.stdout.log"));
    let stderr_path = run_dir.join(format!("{label}.stderr.log"));
    let stdout = File::create(&stdout_path).map_err(|e| format!("{label} stdout failed: {e}"))?;
    let stderr = File::create(&stderr_path).map_err(|e| format!("{label} stderr failed: {e}"))?;
    let child = Command::new(root.join("tele06a_acceptor_runtime.exe"))
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_ACCOUNT", account)
        .env("WOW112_CHARACTER", character)
        .env("WOW112_REALM_INDEX", "1")
        .env("WOW112_RECONNECT_LIMIT", "2")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path)
        .env("WOW112_TELE_AUTO_ACCEPT_FROM", SUMMONER_CHARACTER)
        .env("WOW112_TELE06B_ROLE", "clicker")
        .env("WOW112_TELE06B_MAX_RANGE", "5.8")
        .env("WOW112_TELE06B_CLICK_SETTLE_MS", settle_ms.to_string())
        .spawn()
        .map_err(|e| format!("spawn {label} failed: {e}"))?;
    Ok(ManagedChild {
        label,
        child,
        state_path,
        stdout_path,
        stderr_path,
    })
}

fn spawn_summoner(root: &Path, run_dir: &Path, password: &str) -> Result<ManagedChild, String> {
    let state_path = run_dir.join("STATE_SUMMONER.txt");
    let stdout_path = run_dir.join("SUMMONER.stdout.log");
    let stderr_path = run_dir.join("SUMMONER.stderr.log");
    let stdout = File::create(&stdout_path).map_err(|e| format!("summoner stdout failed: {e}"))?;
    let stderr = File::create(&stderr_path).map_err(|e| format!("summoner stderr failed: {e}"))?;
    let invite_list = format!("{CUSTOMER_CHARACTER},{SLAVE1_CHARACTER},{SLAVE2_CHARACTER}");
    let child = Command::new(root.join("tele06a_ritual_runtime.exe"))
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .env("WOW112_PASSWORD", password)
        .env("WOW112_ACCOUNT", SUMMONER_ACCOUNT)
        .env("WOW112_CHARACTER", SUMMONER_CHARACTER)
        .env("WOW112_REALM_INDEX", "1")
        .env("WOW112_RECONNECT_LIMIT", "2")
        .env("WOW112_RECONNECT_DELAY_MS", "0")
        .env("WOW112_SOAK_SECONDS", "0")
        .env("WOW112_RUNNER_STATE_FILE", &state_path)
        .env("WOW112_TELE_RESET_GROUP", "1")
        .env("WOW112_TELE_INVITE_LIST", invite_list)
        .env("WOW112_RITUAL_TARGET_NAME", CUSTOMER_CHARACTER)
        .spawn()
        .map_err(|e| format!("spawn SUMMONER failed: {e}"))?;
    Ok(ManagedChild {
        label: "SUMMONER",
        child,
        state_path,
        stdout_path,
        stderr_path,
    })
}

fn wait_ready(children: &mut HashMap<String, ManagedChild>) -> Result<(), String> {
    let deadline = Instant::now() + READY_TIMEOUT;
    loop {
        let mut ready = 0usize;
        for label in ["CUSTOMER", "SLAVE1", "SLAVE2"] {
            let child = children
                .get_mut(label)
                .ok_or_else(|| format!("missing child {label}"))?;
            if let Some(status) = child.child.try_wait().map_err(|e| e.to_string())? {
                return Err(format!("{label} exited before READY status={status}"));
            }
            if let Some((state, detail)) = read_state(&child.state_path) {
                if state == "READY" {
                    ready += 1;
                } else if state.starts_with("FAIL") {
                    return Err(format!("{label} state={state} detail={detail}"));
                }
            }
        }
        if ready == 3 {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!("READY timeout ready={ready}/3"));
        }
        thread::sleep(POLL);
    }
}

fn monitor_full_teleport(children: &mut HashMap<String, ManagedChild>) -> Result<String, String> {
    let deadline = Instant::now() + ACTIVE_TIMEOUT;
    loop {
        for label in ["CUSTOMER", "SLAVE1", "SLAVE2", "SUMMONER"] {
            let child = children
                .get_mut(label)
                .ok_or_else(|| format!("missing child {label}"))?;
            if let Some(status) = child.child.try_wait().map_err(|e| e.to_string())? {
                let state = read_state(&child.state_path).map(|v| v.0).unwrap_or_default();
                if !(label == "CUSTOMER" && state == "PASS_SUMMON_TELEPORTED") {
                    return Err(format!("{label} exited active status={status} state={state}"));
                }
            }
            if let Some((state, detail)) = read_state(&child.state_path) {
                if state.starts_with("FAIL") {
                    return Err(format!("{label} state={state} detail={detail}"));
                }
            }
        }

        let customer = state_name(children, "CUSTOMER");
        let slave1 = state_name(children, "SLAVE1");
        let slave2 = state_name(children, "SLAVE2");
        let summoner = state_name(children, "SUMMONER");
        if customer == "PASS_SUMMON_TELEPORTED"
            && slave1 == "PORTAL_USE_SENT"
            && slave2 == "PORTAL_USE_SENT"
            && summoner == "PASS_RITUAL_STARTED"
        {
            let detail = read_state(children["CUSTOMER"].state_path.as_path())
                .map(|v| v.1)
                .unwrap_or_else(|| "teleport confirmed".to_string());
            return Ok(detail);
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "active timeout CUSTOMER={customer} SLAVE1={slave1} SLAVE2={slave2} SUMMONER={summoner}"
            ));
        }
        thread::sleep(POLL);
    }
}

fn state_name(children: &HashMap<String, ManagedChild>, label: &str) -> String {
    children
        .get(label)
        .and_then(|child| read_state(&child.state_path))
        .map(|v| v.0)
        .unwrap_or_else(|| "NO_STATE".to_string())
}

fn stop_all(children: &mut HashMap<String, ManagedChild>) {
    for child in children.values_mut() {
        if child.child.try_wait().ok().flatten().is_none() {
            let _ = child.child.kill();
        }
        let _ = child.child.wait();
    }
}

fn read_state(path: &Path) -> Option<(String, String)> {
    let raw = fs::read_to_string(path).ok()?;
    let mut state = None;
    let mut detail = String::new();
    for line in raw.lines() {
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

fn read_state_text(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap_or_else(|_| "NO_STATE".to_string())
        .replace('\r', " ")
        .replace('\n', ";")
}

fn write_state(path: &Path, state: &str, detail: &str) -> Result<(), String> {
    let temp = path.with_extension("tmp");
    fs::write(
        &temp,
        format!("state={state}\ndetail={}\n", sanitize(detail)),
    )
    .map_err(|e| format!("write state temp failed: {e}"))?;
    fs::rename(&temp, path).map_err(|e| format!("publish state failed: {e}"))
}

fn sanitize(value: &str) -> String {
    value.replace('\r', " ").replace('\n', " ")
}

fn run_customer() -> Result<(), String> {
    let account = env::var("WOW112_ACCOUNT").unwrap_or_else(|_| CUSTOMER_ACCOUNT.to_string());
    let character = env::var("WOW112_CHARACTER").unwrap_or_else(|_| CUSTOMER_CHARACTER.to_string());
    let password = env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let state_path = env::var("WOW112_TELE09_STATE_FILE")
        .map(PathBuf::from)
        .map_err(|_| "missing WOW112_TELE09_STATE_FILE".to_string())?;
    write_state(&state_path, "CONNECTING", "auth")?;

    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
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
        .ok_or_else(|| format!("realm index {realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|e| format!("world connect {world_addr} failed: {e}"))?;

    let result = live::login_accept_and_teleport(
        &mut world_stream,
        session_key,
        realm.realm_id,
        &username,
        &character,
        &state_path,
    );
    if let Err(error) = &result {
        let _ = write_state(&state_path, "FAIL_CUSTOMER", error);
    }
    result
}

mod live {
    include!("../world_tele.rs");

    use super::*;

    const CMSG_GROUP_DISBAND_OPCODE: u32 = 0x007B;
    const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
    const CMSG_GROUP_ACCEPT_OPCODE: u32 = 0x0072;
    const SMSG_SUMMON_REQUEST_OPCODE: u16 = 0x02AB;
    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;
    const SMSG_NEW_WORLD_OPCODE: u16 = 0x003E;
    const MSG_MOVE_WORLDPORT_ACK_OPCODE: u32 = 0x00DC;

    pub fn login_accept_and_teleport(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: &str,
        state_path: &Path,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .map_err(|e| format!("set world timeout failed: {e}"))?;
        let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
            .map_err(|e| format!("world auth challenge failed: {e:?}"))?;
        let seed = ProofSeed::new();
        let seed_value = seed.seed();
        let normalized_username = NormalizedString::new(username)
            .map_err(|e| format!("invalid username: {e:?}"))?;
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
            .map_err(|e| format!("encode auth session failed: {e:?}"))?;
        stream
            .write_all(&auth_wire)
            .map_err(|e| format!("write auth session failed: {e:?}"))?;
        world_diag_peek(stream, "tele09-auth", Duration::from_millis(1500));
        skip_octowow_addon_info(stream, crypto.decrypter())?;
        let mut auth_ok = false;
        for _ in 0..16usize {
            let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read auth response failed: {e:?}"))?;
            if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) = opcode {
                auth_ok = matches!(*response, SMSG_AUTH_RESPONSE::AuthOk { .. });
                break;
            }
        }
        if !auth_ok {
            return Err("world auth did not return AuthOk".to_string());
        }

        CMSG_CHAR_ENUM {}
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|e| format!("write char enum failed: {e:?}"))?;
        let characters =
            expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read char enum failed: {e:?}"))?;
        let selected = characters
            .characters
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(character_name))
            .ok_or_else(|| format!("character not found: {character_name}"))?;
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
            return Err("SMSG_LOGIN_VERIFY_WORLD not received".to_string());
        }

        write_encrypted_raw(
            stream,
            crypto.encrypter(),
            CMSG_GROUP_DISBAND_OPCODE,
            &[],
        )?;
        thread::sleep(Duration::from_millis(1200));
        write_state(state_path, "READY", "login verified and group reset sent")?;
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|e| format!("set active timeout failed: {e}"))?;

        let deadline = Instant::now() + ACTIVE_TIMEOUT;
        let mut invite_accepted = false;
        let mut summon_response_committed = false;
        let mut awaiting_pong: Option<(u32, Instant)> = None;
        let mut ping_sequence = 1u32;
        let mut last_ping = Instant::now();

        loop {
            if Instant::now() >= deadline {
                return Err(format!(
                    "customer active timeout invite_accepted={invite_accepted} summon_response_committed={summon_response_committed}"
                ));
            }
            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("keepalive pong timeout sequence={sequence}"));
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
                            if awaiting_pong.map(|v| v.0) == Some(sequence) {
                                awaiting_pong = None;
                            }
                        }
                        continue;
                    }

                    if !invite_accepted && opcode == SMSG_GROUP_INVITE_OPCODE {
                        match parse_raw_server_message(opcode, &payload) {
                            Ok(ServerOpcodeMessage::SMSG_GROUP_INVITE(invite))
                                if invite.name.eq_ignore_ascii_case(SUMMONER_CHARACTER) =>
                            {
                                write_encrypted_raw(
                                    stream,
                                    crypto.encrypter(),
                                    CMSG_GROUP_ACCEPT_OPCODE,
                                    &[],
                                )?;
                                invite_accepted = true;
                                write_state(
                                    state_path,
                                    "PARTY_ACCEPTED",
                                    &format!("inviter={}", invite.name),
                                )?;
                                println!("[TELE09-CUSTOMER] GROUP_ACCEPT inviter={}", invite.name);
                                continue;
                            }
                            Ok(_) => continue,
                            Err(error) => {
                                println!("[TELE09-CUSTOMER] invite parse ignored: {error}");
                                continue;
                            }
                        }
                    }

                    if opcode == SMSG_SUMMON_REQUEST_OPCODE {
                        if payload.len() != 16 {
                            return Err(format!("SMSG_SUMMON_REQUEST malformed bytes={}", payload.len()));
                        }
                        if summon_response_committed {
                            return Err("duplicate SMSG_SUMMON_REQUEST after response commit".to_string());
                        }
                        let summoner_guid =
                            u64::from_le_bytes(payload[0..8].try_into().unwrap());
                        let area = u32::from_le_bytes(payload[8..12].try_into().unwrap());
                        let auto_decline_ms =
                            u32::from_le_bytes(payload[12..16].try_into().unwrap());
                        summon_response_committed = true;
                        write_state(
                            state_path,
                            "SUMMON_RESPONSE_COMMITTED",
                            &format!(
                                "summoner_guid=0x{summoner_guid:016X} area={area} auto_decline_ms={auto_decline_ms} retry_allowed=false"
                            ),
                        )?;
                        if let Err(error) = write_encrypted_raw(
                            stream,
                            crypto.encrypter(),
                            CMSG_SUMMON_RESPONSE_OPCODE,
                            &summoner_guid.to_le_bytes(),
                        ) {
                            write_state(
                                state_path,
                                "FAIL_SUMMON_RESPONSE_UNCERTAIN",
                                &format!("write failed after commit retry_allowed=false cause={error}"),
                            )?;
                            return Err(format!(
                                "CMSG_SUMMON_RESPONSE mutation uncertain retry_allowed=false cause={error}"
                            ));
                        }
                        write_state(
                            state_path,
                            "SUMMON_RESPONSE_SENT",
                            &format!("opcode=0x02AC summoner_guid=0x{summoner_guid:016X}"),
                        )?;
                        println!(
                            "[TELE09-CUSTOMER] CMSG_SUMMON_RESPONSE sent guid=0x{summoner_guid:016X}"
                        );
                        continue;
                    }

                    if summon_response_committed && opcode == SMSG_NEW_WORLD_OPCODE {
                        if payload.len() != 20 {
                            return Err(format!("SMSG_NEW_WORLD malformed bytes={}", payload.len()));
                        }
                        let map = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                        let x = f32::from_le_bytes(payload[4..8].try_into().unwrap());
                        let y = f32::from_le_bytes(payload[8..12].try_into().unwrap());
                        let z = f32::from_le_bytes(payload[12..16].try_into().unwrap());
                        let o = f32::from_le_bytes(payload[16..20].try_into().unwrap());
                        write_state(
                            state_path,
                            "WORLDPORT_ACK_COMMITTED",
                            &format!("map={map} x={x:.3} y={y:.3} z={z:.3} o={o:.3}"),
                        )?;
                        if let Err(error) = write_encrypted_raw(
                            stream,
                            crypto.encrypter(),
                            MSG_MOVE_WORLDPORT_ACK_OPCODE,
                            &[],
                        ) {
                            write_state(
                                state_path,
                                "FAIL_WORLDPORT_ACK_UNCERTAIN",
                                &format!("write failed after commit retry_allowed=false cause={error}"),
                            )?;
                            return Err(format!(
                                "MSG_MOVE_WORLDPORT_ACK mutation uncertain retry_allowed=false cause={error}"
                            ));
                        }
                        let detail = format!(
                            "SMSG_NEW_WORLD map={map} x={x:.3} y={y:.3} z={z:.3} o={o:.3}; MSG_MOVE_WORLDPORT_ACK sent"
                        );
                        write_state(state_path, "PASS_SUMMON_TELEPORTED", &detail)?;
                        println!("[TELE09-CUSTOMER] PASS {detail}");
                        return Ok(());
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
