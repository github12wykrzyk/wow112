use std::net::{Ipv4Addr, TcpStream};
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

pub fn authenticate(
    auth_server: &mut TcpStream,
    username: &str,
    password: &str,
) -> Result<([u8; SESSION_KEY_LENGTH as usize], CMD_REALM_LIST_Server), String> {
    CMD_AUTH_LOGON_CHALLENGE_Client {
        protocol_version: ProtocolVersion::Three,
        version: Version {
            major: 1,
            minor: 12,
            patch: 1,
            build: 5875,
        },
        platform: Platform::X86,
        os: Os::Windows,
        locale: Locale::EnGb,
        utc_timezone_offset: 0,
        client_ip_address: Ipv4Addr::LOCALHOST,
        account_name: username.to_string(),
    }
    .write(&mut *auth_server)
    .map_err(|e| format!("write auth challenge failed: {e:?}"))?;

    let response = expect_server_message::<CMD_AUTH_LOGON_CHALLENGE_Server, _>(&mut *auth_server)
        .map_err(|e| format!("read auth challenge failed: {e:?}"))?;

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
            NormalizedString::new(username)
                .map_err(|e| format!("invalid account name: {e:?}"))?,
            NormalizedString::new(password)
                .map_err(|e| format!("invalid password: {e:?}"))?,
            generator,
            large_safe_prime,
            server_public_key,
            salt,
        )
    } else {
        return Err(format!("auth challenge rejected: {response:?}"));
    };

    CMD_AUTH_LOGON_PROOF_Client {
        client_public_key: *challenge.client_public_key(),
        client_proof: *challenge.client_proof(),
        crc_hash: [0u8; 20],
        telemetry_keys: vec![],
        security_flag: CMD_AUTH_LOGON_PROOF_Client_SecurityFlag::None,
    }
    .write(&mut *auth_server)
    .map_err(|e| format!("write auth proof failed: {e:?}"))?;

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
