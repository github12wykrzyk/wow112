use std::env;
use std::net::TcpStream;
use std::thread;
use std::time::Duration;

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

mod tele04 {
    include!("../world_tele.rs");

    use std::sync::atomic::{AtomicBool, Ordering};

    const CMSG_GROUP_INVITE_OPCODE: u32 = 0x006E;
    static INVITE_ATTEMPTED: AtomicBool = AtomicBool::new(false);

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

    fn configured_invite_target() -> Option<String> {
        std::env::var("WOW112_TELE_TEST_INVITE")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    fn send_group_invite_once(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
    ) -> Result<(), String> {
        let Some(target) = configured_invite_target() else {
            println!("[TELE-INVITE] disabled target=blank");
            return Ok(());
        };

        // Validate before consuming the one-shot guard. Once the guard flips,
        // it is intentionally process-lifetime and survives every reconnect.
        let payload = encode_group_invite_target(&target)?;
        if INVITE_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!(
                "[TELE-INVITE] target={target:?} result=skip_already_attempted retry_allowed=false"
            );
            return Ok(());
        }

        // IMPORTANT: guard is already committed BEFORE socket I/O. Any error
        // from here onward is mutation-uncertain and MUST NOT re-arm/retry.
        match write_encrypted_raw(
            stream,
            crypto.encrypter(),
            CMSG_GROUP_INVITE_OPCODE,
            &payload,
        ) {
            Ok(()) => {
                println!(
                    "[TELE-INVITE-TX] target={target:?} opcode=0x006E result=attempted_once retry_allowed=false"
                );
                Ok(())
            }
            Err(error) => Err(format!(
                "TELE_INVITE_MUTATION_UNCERTAIN target={target:?} retry_allowed=false cause={error}"
            )),
        }
    }

    pub fn login_tele04(
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

        // Mutation is deliberately impossible before LOGIN_VERIFY_WORLD.
        send_group_invite_once(stream, &mut crypto)?;
        println!("[TELE-04] party observer remains enabled; invite/accept/decline/uninvite/leader automation beyond this one-shot invite is disabled");

        // Reuse the live-proven TELE-03 whisper/name/party observer loop.
        tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;
        println!("[TELE-04] RUNTIME LOOP PASS");
        Ok(())
    }

    #[cfg(test)]
    mod tele04_tests {
        use super::*;

        #[test]
        fn invite_wire_is_vanilla_cstring() {
            assert_eq!(CMSG_GROUP_INVITE_OPCODE, 0x006E);
            assert_eq!(encode_group_invite_target("Teletanaris").unwrap(), b"Teletanaris\0");
        }

        #[test]
        fn invite_target_boundaries_fail_closed() {
            assert!(encode_group_invite_target("").is_err());
            assert!(encode_group_invite_target("bad\0name").is_err());
            assert!(encode_group_invite_target(&"x".repeat(65)).is_err());
            assert!(encode_group_invite_target(&"x".repeat(64)).is_ok());
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
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE-04] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR")
        .unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let character_name = env::var("WOW112_CHARACTER").ok();
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);
    let soak_seconds = parse_env_u64("WOW112_SOAK_SECONDS", 0)?;
    let reconnect_limit = parse_env_u32("WOW112_RECONNECT_LIMIT", DEFAULT_RECONNECT_LIMIT)?.max(1);
    let reconnect_delay_ms = parse_env_u64("WOW112_RECONNECT_DELAY_MS", 0)?;
    let invite_target = env::var("WOW112_TELE_TEST_INVITE")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    println!(
        "[WOW112-ANDROID-PROBE] binary-build=5875 wire-build={} protocol=vanilla target=headless mode=tele04-runtime-invite",
        OCTOWOW_WIRE_BUILD
    );
    println!(
        "[TELE-04] soak_seconds={} reconnect_limit={} invite={} retry_policy=fail_closed_after_attempt party_rx=enabled whisper_rx=enabled cast=disabled portal_use=disabled",
        soak_seconds,
        reconnect_limit,
        invite_target.as_deref().unwrap_or("disabled")
    );

    for attempt in 1..=reconnect_limit {
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        match run_session(
            &auth_addr,
            realm_index,
            &username,
            &password,
            character_name.as_deref(),
            soak_seconds,
        ) {
            Ok(()) => {
                println!("[RESILIENCE] TELE-04 RECONNECT/KEEPALIVE PASS attempts={attempt}");
                return Ok(());
            }
            Err(error) if is_transient_network_error(&error) && attempt < reconnect_limit => {
                println!("[RESILIENCE] transient network failure: {error}");
                println!("[RESILIENCE] reconnecting; TELE invite guard is process-lifetime and will NOT re-arm");
                if reconnect_delay_ms != 0 {
                    thread::sleep(Duration::from_millis(reconnect_delay_ms));
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(format!("TELE-04 reconnect limit exhausted after {reconnect_limit} attempts"))
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
    let mut auth_stream = TcpStream::connect(auth_addr)
        .map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, username, password)?;
    if realms.realms.is_empty() {
        return Err("auth succeeded but realm list is empty".to_string());
    }
    println!("[AUTH] realms={}", realms.realms.len());
    for (index, realm) in realms.realms.iter().enumerate() {
        println!("[AUTH] realm[{index}] name={} address={} id={}", realm.name, realm.address, realm.realm_id);
    }
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} is out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    println!("[WORLD] connecting realm={} id={} address={}", realm.name, realm.realm_id, world_addr);
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|e| format!("world connect {world_addr} failed: {e}"))?;

    tele04::login_tele04(
        &mut world_stream,
        session_key,
        realm.realm_id,
        username,
        character_name,
        soak_seconds,
    )
}
