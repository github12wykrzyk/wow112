use crate::wire_build::OCTOWOW_WIRE_BUILD;
use sha1::{Digest, Sha1};
use std::io::{self, Write};
use std::net::{Ipv4Addr, TcpStream};
use std::time::Duration;
use wow_login_messages::all::{
    CMD_AUTH_LOGON_CHALLENGE_Client, Locale, Os, Platform, ProtocolVersion, Version,
};
use wow_login_messages::helper::expect_server_message;
use wow_login_messages::version_2::{
    CMD_AUTH_LOGON_PROOF_Server, CMD_REALM_LIST_Client, CMD_REALM_LIST_Server,
};
use wow_login_messages::version_3::{
    CMD_AUTH_LOGON_CHALLENGE_Server, CMD_AUTH_LOGON_PROOF_Client,
    CMD_AUTH_LOGON_PROOF_Client_SecurityFlag,
};
use wow_login_messages::Message;
use wow_srp::client::SrpClientChallenge;
use wow_srp::normalized_string::NormalizedString;
use wow_srp::{PublicKey, SESSION_KEY_LENGTH};

const VANILLA_5875_WIN_X86_INTEGRITY_HASH: [u8; 20] = [
    0x95, 0xED, 0xB2, 0x7C, 0x78, 0x23, 0xB3, 0x63, 0xCB, 0xDD, 0xAB, 0x56, 0xA3, 0x92, 0xE7, 0xCB,
    0x73, 0xFC, 0xCA, 0x20,
];

fn hex_prefix(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn diag_peek(stream: &TcpStream, label: &str, timeout: Duration) {
    let previous_timeout = stream.read_timeout().ok().flatten();
    if stream.set_read_timeout(Some(timeout)).is_err() {
        println!("[AUTH-DIAG] {label} unable-to-set-timeout");
        return;
    }

    let mut buf = [0u8; 32];
    match stream.peek(&mut buf) {
        Ok(count) => println!(
            "[AUTH-DIAG] {label} pending={count} bytes={}",
            hex_prefix(&buf[..count])
        ),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ) =>
        {
            println!("[AUTH-DIAG] {label} pending=0");
        }
        Err(error) => println!("[AUTH-DIAG] {label} peek-error={error}"),
    }

    let _ = stream.set_read_timeout(previous_timeout);
}

fn vanilla_5875_version_proof(client_public_key: &[u8; 32]) -> [u8; 20] {
    Sha1::new()
        .chain_update(client_public_key)
        .chain_update(VANILLA_5875_WIN_X86_INTEGRITY_HASH)
        .finalize()
        .into()
}

pub fn authenticate(
    auth_server: &mut TcpStream,
    username: &str,
    password: &str,
) -> Result<([u8; SESSION_KEY_LENGTH as usize], CMD_REALM_LIST_Server), String> {
    let challenge_request = CMD_AUTH_LOGON_CHALLENGE_Client {
        protocol_version: ProtocolVersion::Three,
        version: Version {
            major: 1,
            minor: 12,
            patch: 1,
            build: OCTOWOW_WIRE_BUILD,
        },
        platform: Platform::X86,
        os: Os::Windows,
        locale: Locale::EnGb,
        utc_timezone_offset: 0,
        client_ip_address: Ipv4Addr::LOCALHOST,
        account_name: username.to_string(),
    };

    let mut challenge_wire = Vec::new();
    challenge_request
        .write(&mut challenge_wire)
        .map_err(|e| format!("encode auth challenge failed: {e:?}"))?;
    let safe_prefix_len = challenge_wire.len().min(34);
    println!(
        "[AUTH-DIAG] challenge-out len={} prefix={} expected-wire-build={}",
        challenge_wire.len(),
        hex_prefix(&challenge_wire[..safe_prefix_len]),
        OCTOWOW_WIRE_BUILD
    );
    auth_server
        .write_all(&challenge_wire)
        .map_err(|e| format!("write auth challenge failed: {e:?}"))?;

    let response = expect_server_message::<CMD_AUTH_LOGON_CHALLENGE_Server, _>(&mut *auth_server)
        .map_err(|e| format!("read auth challenge failed: {e:?}"))?;

    diag_peek(auth_server, "after-challenge", Duration::from_millis(100));

    let challenge = if let CMD_AUTH_LOGON_CHALLENGE_Server::Success {
        generator,
        large_safe_prime,
        salt,
        server_public_key,
        ..
    } = response
    {
        let generator = generator[0];
        let large_safe_prime = large_safe_prime
            .try_into()
            .map_err(|_| "invalid SRP large safe prime".to_string())?;
        let server_public_key = PublicKey::from_le_bytes(server_public_key)
            .map_err(|e| format!("invalid SRP server public key: {e:?}"))?;

        SrpClientChallenge::new(
            NormalizedString::new(username).map_err(|e| format!("invalid account name: {e:?}"))?,
            NormalizedString::new(password).map_err(|e| format!("invalid password: {e:?}"))?,
            generator,
            large_safe_prime,
            server_public_key,
            salt,
        )
    } else {
        return Err(format!("auth challenge rejected: {response:?}"));
    };

    let client_public_key = *challenge.client_public_key();
    let crc_hash = vanilla_5875_version_proof(&client_public_key);
    println!(
        "[AUTH-DIAG] version-proof=vanilla-5875-files wire-build={}",
        OCTOWOW_WIRE_BUILD
    );

    CMD_AUTH_LOGON_PROOF_Client {
        client_public_key,
        client_proof: *challenge.client_proof(),
        crc_hash,
        telemetry_keys: vec![],
        security_flag: CMD_AUTH_LOGON_PROOF_Client_SecurityFlag::None,
    }
    .write(&mut *auth_server)
    .map_err(|e| format!("write auth proof failed: {e:?}"))?;

    diag_peek(auth_server, "proof-response", Duration::from_millis(1500));

    let proof = expect_server_message::<CMD_AUTH_LOGON_PROOF_Server, _>(&mut *auth_server)
        .map_err(|e| format!("read auth proof failed: {e:?}"))?;

    let session = if let CMD_AUTH_LOGON_PROOF_Server::Success { server_proof, .. } = proof {
        challenge
            .verify_server_proof(server_proof)
            .map_err(|e| format!("server proof verification failed: {e:?}"))?
    } else {
        return Err(format!("auth proof rejected: {proof:?}"));
    };

    CMD_REALM_LIST_Client {}
        .write(&mut *auth_server)
        .map_err(|e| format!("write realm-list request failed: {e:?}"))?;

    let realms = expect_server_message::<CMD_REALM_LIST_Server, _>(&mut *auth_server)
        .map_err(|e| format!("read realm-list failed: {e:?}"))?;

    println!("[AUTH] SRP6 PASS");
    Ok((*session.session_key(), realms))
}
