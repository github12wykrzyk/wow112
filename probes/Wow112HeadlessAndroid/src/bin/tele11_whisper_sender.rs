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

fn required(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing or empty {name}"))
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE11-SENDER] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    if env::args().any(|arg| arg == "--self-test") {
        println!("TELE11_WHISPER_SENDER_SELFTEST_PASS");
        return Ok(());
    }
    let account = required("WOW112_TELE11_SENDER_ACCOUNT")?;
    let character = required("WOW112_TELE11_SENDER_CHARACTER")?;
    let target = required("WOW112_TELE11_SENDER_TARGET")?;
    let text = required("WOW112_TELE11_SENDER_TEXT")?;
    let password = required("WOW112_PASSWORD")?;
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(1);
    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let username = account.to_ascii_uppercase();

    let mut auth_stream = TcpStream::connect(&auth_addr)
        .map_err(|error| format!("auth connect {auth_addr} failed: {error}"))?;
    auth_stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| format!("auth timeout setup failed: {error}"))?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, &username, &password)?;
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("realm index {realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = TcpStream::connect(&world_addr)
        .map_err(|error| format!("world connect {world_addr} failed: {error}"))?;
    live::login_and_send(
        &mut world_stream,
        session_key,
        realm.realm_id,
        &username,
        &character,
        &target,
        &text,
    )
}

mod live {
    include!("../world_tele.rs");

    use super::*;

    pub fn login_and_send(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: &str,
        target: &str,
        text: &str,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .map_err(|error| format!("set world timeout failed: {error}"))?;
        let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
            .map_err(|error| format!("read world challenge failed: {error:?}"))?;
        let seed = ProofSeed::new();
        let seed_value = seed.seed();
        let normalized_username = NormalizedString::new(username)
            .map_err(|error| format!("invalid account name: {error:?}"))?;
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
        let mut wire = Vec::new();
        auth_session
            .write_unencrypted_client(&mut wire)
            .map_err(|error| format!("encode auth session failed: {error:?}"))?;
        stream
            .write_all(&wire)
            .map_err(|error| format!("write auth session failed: {error:?}"))?;
        world_diag_peek(stream, "auth-response-raw", Duration::from_millis(1500));
        skip_octowow_addon_info(stream, crypto.decrypter())?;
        let mut auth_ok = false;
        for _ in 0..16usize {
            let message = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|error| format!("read pre-auth failed: {error:?}"))?;
            if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) = message {
                auth_ok = matches!(*response, SMSG_AUTH_RESPONSE::AuthOk { .. });
                break;
            }
        }
        if !auth_ok {
            return Err("world auth not OK".to_string());
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
            .ok_or_else(|| format!("sender character not found: {character_name}"))?;
        tele_trace::set_local_guid(selected.guid.guid());
        CMSG_PLAYER_LOGIN { guid: selected.guid }
            .write_encrypted_client(&mut *stream, crypto.encrypter())
            .map_err(|error| format!("write player login failed: {error:?}"))?;
        let mut verified = false;
        for _ in 0..256usize {
            let message = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|error| format!("read login verify failed: {error:?}"))?;
            if matches!(message, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
                verified = true;
                break;
            }
        }
        if !verified {
            return Err("sender login verify not received".to_string());
        }
        tele_send_whisper(stream, &mut crypto, target, text)?;
        println!(
            "[TELE11-SENDER] PASS character={} target={} text={:?}",
            selected.name, target, text
        );
        thread::sleep(Duration::from_millis(750));
        Ok(())
    }
}
