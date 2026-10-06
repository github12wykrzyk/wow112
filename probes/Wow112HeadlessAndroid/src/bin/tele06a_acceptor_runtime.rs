use std::env;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

#[path = "../auth.rs"]
mod auth;
#[path = "../tele_party_observer.rs"]
mod tele_party_observer;
#[path = "../wire_build.rs"]
mod wire_build;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const DEFAULT_RECONNECT_LIMIT: u32 = 60;

mod agent {
    include!("../world_tele.rs");

    use super::*;

    const CMSG_GROUP_DISBAND_OPCODE: u32 = 0x007B;
    const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
    const CMSG_GROUP_ACCEPT_OPCODE: u32 = 0x0072;

    static RESET_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static ACCEPT_ATTEMPTED: AtomicBool = AtomicBool::new(false);

    fn configured_accept_from() -> Result<String, String> {
        std::env::var("WOW112_TELE_AUTO_ACCEPT_FROM")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "missing WOW112_TELE_AUTO_ACCEPT_FROM".to_string())
    }

    fn reset_group_once(stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<(), String> {
        if RESET_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!("[TELE-06A-ACCEPTOR-RESET] skip_already_attempted retry_allowed=false");
            return Ok(());
        }
        write_encrypted_raw(stream, crypto.encrypter(), CMSG_GROUP_DISBAND_OPCODE, &[])?;
        println!("[TELE-06A-ACCEPTOR-RESET-TX] opcode=0x007B result=attempted_once retry_allowed=false");
        thread::sleep(Duration::from_millis(1200));
        Ok(())
    }

    fn send_accept_once(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        inviter: &str,
    ) -> Result<(), String> {
        if ACCEPT_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!("[TELE-06A-ACCEPTOR] inviter={inviter:?} result=skip_already_attempted retry_allowed=false");
            return Ok(());
        }
        write_encrypted_raw(stream, crypto.encrypter(), CMSG_GROUP_ACCEPT_OPCODE, &[])
            .map_err(|error| format!("TELE06A_ACCEPT_MUTATION_UNCERTAIN inviter={inviter:?} retry_allowed=false cause={error}"))?;
        println!("[TELE-06A-ACCEPT-TX] inviter={inviter:?} opcode=0x0072 result=attempted_once retry_allowed=false");
        Ok(())
    }

    fn wait_for_invite(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        expected_inviter: &str,
    ) -> Result<(), String> {
        let previous_timeout = stream.read_timeout().ok().flatten();
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|e| format!("set acceptor timeout failed: {e}"))?;
        let deadline = Instant::now() + Duration::from_secs(180);
        let mut last_ping = Instant::now();
        let mut ping_sequence = 1u32;
        let mut awaiting_pong: Option<(u32, Instant)> = None;

        println!("[TELE-06A-ACCEPTOR] ARMED ONCE whitelist={expected_inviter:?} deadline=180s");
        loop {
            if Instant::now() >= deadline {
                let _ = stream.set_read_timeout(previous_timeout);
                return Err("TELE06A_ACCEPT_TIMEOUT no whitelisted invite observed".to_string());
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
                println!("[TELE-06A-ACCEPTOR] keepalive ping sequence={ping_sequence}");
                awaiting_pong = Some((ping_sequence, Instant::now()));
                ping_sequence = ping_sequence.wrapping_add(1);
                last_ping = Instant::now();
            }

            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if opcode == SMSG_PONG_OPCODE {
                        if payload.len() >= 4 {
                            let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            println!("[TELE-06A-ACCEPTOR] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                            }
                        }
                        continue;
                    }
                    if opcode == SMSG_GROUP_INVITE_OPCODE {
                        match parse_raw_server_message(opcode, &payload) {
                            Ok(ServerOpcodeMessage::SMSG_GROUP_INVITE(invite)) => {
                                println!("[TELE-06A-ACCEPT-RX] inviter={:?} expected={:?}", invite.name, expected_inviter);
                                if !invite.name.eq_ignore_ascii_case(expected_inviter) {
                                    println!("[TELE-06A-ACCEPTOR] inviter={:?} result=ignored_not_whitelisted", invite.name);
                                    continue;
                                }
                                send_accept_once(stream, crypto, &invite.name)?;
                                let _ = stream.set_read_timeout(previous_timeout);
                                return Ok(());
                            }
                            Ok(other) => println!("[TELE-06A-ACCEPTOR-DIAG] unexpected invite parse={other:?}"),
                            Err(error) => println!("[TELE-06A-ACCEPTOR-DIAG] invite parse failed: {error}"),
                        }
                        continue;
                    }
                    crate::tele_party_observer::inspect_party_packet(opcode, &payload);
                }
                Err(error)
                    if error.contains("TimedOut")
                        || error.contains("timed out")
                        || error.contains("WouldBlock") => {}
                Err(error) => return Err(error),
            }
        }
    }

    pub fn login_agent(
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
        let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(
            &mut *stream,
            crypto.decrypter(),
        )
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
        CMSG_PLAYER_LOGIN { guid: selected.guid }
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
            return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string());
        }

        reset_group_once(stream, &mut crypto)?;
        let inviter = configured_accept_from()?;
        wait_for_invite(stream, &mut crypto, &inviter)?;
        println!("[TELE-06A-ACCEPTOR] handshake complete; observer active");
        tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;
        Ok(())
    }
}

fn parse_env_u64(name: &str, default_value: u64) -> Result<u64, String> {
    match env::var(name) {
        Ok(value) => value.parse::<u64>().map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn parse_env_u32(name: &str, default_value: u32) -> Result<u32, String> {
    match env::var(name) {
        Ok(value) => value.parse::<u32>().map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn is_transient_network_error(error: &str) -> bool {
    ["ConnectionReset", "Connection reset by peer", "BrokenPipe", "UnexpectedEof", "TimedOut", "timed out", "WouldBlock", "ConnectionRefused", "connection refused", "world socket closed", "world keepalive pong timeout"]
        .iter()
        .any(|needle| error.contains(needle))
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE-06A-ACCEPTOR] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let character_name = env::var("WOW112_CHARACTER").ok();
    let realm_index = env::var("WOW112_REALM_INDEX").ok().and_then(|value| value.parse::<usize>().ok()).unwrap_or(DEFAULT_REALM_INDEX);
    let soak_seconds = parse_env_u64("WOW112_SOAK_SECONDS", 0)?;
    let reconnect_limit = parse_env_u32("WOW112_RECONNECT_LIMIT", DEFAULT_RECONNECT_LIMIT)?.max(1);
    let reconnect_delay_ms = parse_env_u64("WOW112_RECONNECT_DELAY_MS", 0)?;
    let accept_from = env::var("WOW112_TELE_AUTO_ACCEPT_FROM").unwrap_or_default();

    println!("[WOW112-HEADLESS] binary-build=5875 wire-build={} protocol=vanilla target=windows-headless mode=tele06a-acceptor", OCTOWOW_WIRE_BUILD);
    println!("[TELE-06A-ACCEPTOR] account={} character={} accept_from={:?} reset_group=enabled reconnect_limit={} accept_retry=disabled", username, character_name.as_deref().unwrap_or("first"), accept_from, reconnect_limit);

    for attempt in 1..=reconnect_limit {
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        match run_session(&auth_addr, realm_index, &username, &password, character_name.as_deref(), soak_seconds) {
            Ok(()) => return Ok(()),
            Err(error) if is_transient_network_error(&error) && attempt < reconnect_limit => {
                println!("[RESILIENCE] transient network failure: {error}");
                println!("[RESILIENCE] reconnecting; reset/accept guards remain committed");
                if reconnect_delay_ms != 0 {
                    thread::sleep(Duration::from_millis(reconnect_delay_ms));
                }
            }
            Err(error) => return Err(error),
        }
    }
    Err(format!("acceptor reconnect limit exhausted after {reconnect_limit} attempts"))
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
    let mut auth_stream = TcpStream::connect(auth_addr).map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, username, password)?;
    if realms.realms.is_empty() {
        return Err("auth succeeded but realm list is empty".to_string());
    }
    println!("[AUTH] realms={}", realms.realms.len());
    for (index, realm) in realms.realms.iter().enumerate() {
        println!("[AUTH] realm[{index}] name={} address={} id={}", realm.name, realm.address, realm.realm_id);
    }
    let realm = realms.realms.get(realm_index).ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} is out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    println!("[WORLD] connecting realm={} id={} address={}", realm.name, realm.realm_id, world_addr);
    let mut world_stream = TcpStream::connect(&world_addr).map_err(|e| format!("world connect {world_addr} failed: {e}"))?;
    agent::login_agent(&mut world_stream, session_key, realm.realm_id, username, character_name, soak_seconds)
}
