use crate::wire_build::OCTOWOW_WIRE_BUILD;
use std::net::TcpStream;
use std::time::Duration;
use wow_srp::normalized_string::NormalizedString;
use wow_srp::vanilla_header::ProofSeed;
use wow_srp::SESSION_KEY_LENGTH;
use wow_world_messages::vanilla::opcodes::ServerOpcodeMessage;
use wow_world_messages::vanilla::{
    expect_server_message, expect_server_message_encryption, AddonInfo, ClientMessage,
    CMSG_AUTH_SESSION, CMSG_CHAR_ENUM, CMSG_PLAYER_LOGIN, SMSG_AUTH_CHALLENGE,
    SMSG_AUTH_RESPONSE, SMSG_CHAR_ENUM,
};

pub fn login(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
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

    CMSG_AUTH_SESSION {
        build: OCTOWOW_WIRE_BUILD as u32,
        server_id: server_id as u32,
        username: username.to_string(),
        client_seed: seed_value,
        client_proof,
        addon_info: vec![AddonInfo {
            addon_name: "WoW112HeadlessProbe".to_string(),
            addon_crc: 0,
            addon_extra_crc: 0,
            addon_has_signature: 0,
        }],
    }
    .write_unencrypted_client(&mut *stream)
    .map_err(|e| format!("write world auth session failed: {e:?}"))?;

    let auth_response = expect_server_message_encryption::<SMSG_AUTH_RESPONSE, _>(
        &mut *stream,
        crypto.decrypter(),
    )
    .map_err(|e| format!("read world auth response failed: {e:?}"))?;

    if !matches!(auth_response, SMSG_AUTH_RESPONSE::AuthOk { .. }) {
        return Err(format!("world auth rejected: {auth_response:?}"));
    }
    println!("[WORLD] auth PASS wire-build={OCTOWOW_WIRE_BUILD}");

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

    for index in 0..256usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
            .map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;

        if index < 24 {
            println!("[WORLD] rx[{index}] {opcode:?}");
        }

        if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
            println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS");
            return Ok(());
        }
    }

    Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string())
}
