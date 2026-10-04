use std::collections::HashSet;
use std::env;
use std::io::{self, Cursor, Read, Write};
use std::net::TcpStream;
use std::time::Duration;
use wow_srp::normalized_string::NormalizedString;
use wow_srp::vanilla_header::{DecrypterHalf, EncrypterHalf, HeaderCrypto, ProofSeed};
use wow_srp::SESSION_KEY_LENGTH;
use wow_world_messages::vanilla::opcodes::ServerOpcodeMessage;
use wow_world_messages::vanilla::{
    expect_server_message, expect_server_message_encryption, AddonInfo, ClientMessage, Object,
    UpdateMask, CMSG_AUTH_SESSION, CMSG_CHAR_ENUM, CMSG_PLAYER_LOGIN, SMSG_AUTH_CHALLENGE,
    SMSG_AUTH_RESPONSE, SMSG_CHAR_ENUM,
};

const OCTOWOW_WORLD_BUILD: u32 = 5875;
const VANILLA_MODULUS_CRC: u32 = 0x4C1C776D;
const SMSG_ADDON_INFO_OPCODE: u16 = 0x02EF;
const SMSG_UPDATE_OBJECT_OPCODE: u16 = 0x00A9;
const SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE: u16 = 0x01F6;
const MSG_AUCTION_HELLO_OPCODE: u16 = 0x0255;
const CMSG_AUCTION_LIST_ITEMS_OPCODE: u32 = 0x0258;
const SMSG_AUCTION_LIST_RESULT_OPCODE: u16 = 0x025C;
const UNIT_NPC_FLAG_AUCTIONEER: u32 = 0x0000_1000;
const AUCTION_RECORD_SIZE: usize = 64;

fn hex_prefix(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn world_diag_peek(stream: &TcpStream, label: &str, timeout: Duration) {
    let previous_timeout = stream.read_timeout().ok().flatten();
    if stream.set_read_timeout(Some(timeout)).is_err() {
        println!("[WORLD-DIAG] {label} unable-to-set-timeout");
        return;
    }

    let mut buf = [0u8; 32];
    match stream.peek(&mut buf) {
        Ok(count) => println!(
            "[WORLD-DIAG] {label} pending={count} bytes={}",
            hex_prefix(&buf[..count])
        ),
        Err(error)
            if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) =>
        {
            println!("[WORLD-DIAG] {label} pending=0");
        }
        Err(error) => println!("[WORLD-DIAG] {label} peek-error={error}"),
    }

    let _ = stream.set_read_timeout(previous_timeout);
}

fn skip_octowow_addon_info(
    stream: &mut TcpStream,
    decrypter: &mut DecrypterHalf,
) -> Result<(), String> {
    let header = decrypter
        .read_and_decrypt_server_header(&mut *stream)
        .map_err(|e| format!("read Octo addon-info header failed: {e:?}"))?;

    if header.size < 2 {
        return Err(format!(
            "invalid Octo pre-auth header size={} opcode=0x{:04X}",
            header.size, header.opcode
        ));
    }

    let payload_len = usize::from(header.size - 2);
    let mut payload = vec![0u8; payload_len];
    stream
        .read_exact(&mut payload)
        .map_err(|e| format!("read Octo addon-info payload failed: {e:?}"))?;

    let prefix_len = payload.len().min(32);
    println!(
        "[WORLD-DIAG] pre-auth-raw opcode=0x{:04X} size={} payload={} prefix={}",
        header.opcode,
        header.size,
        payload_len,
        hex_prefix(&payload[..prefix_len])
    );

    if header.opcode != SMSG_ADDON_INFO_OPCODE {
        return Err(format!(
            "expected Octo SMSG_ADDON_INFO opcode=0x{SMSG_ADDON_INFO_OPCODE:04X}, got 0x{:04X}",
            header.opcode
        ));
    }

    println!("[WORLD] custom SMSG_ADDON_INFO skipped payload={payload_len}");
    Ok(())
}

fn octo_fingerprint_addons() -> Vec<AddonInfo> {
    [
        "Blizzard_AuctionUI",
        "Blizzard_BattlefieldMinimap",
        "Blizzard_BindingUI",
        "Blizzard_CombatText",
        "Blizzard_CraftUI",
        "Blizzard_GMSurveyUI",
        "Blizzard_InspectUI",
        "Blizzard_MacroUI",
        "Blizzard_RaidUI",
        "Blizzard_TalentUI",
        "Blizzard_TradeSkillUI",
        "Blizzard_TrainerUI",
    ]
    .iter()
    .map(|name| AddonInfo {
        addon_name: (*name).to_string(),
        addon_crc: VANILLA_MODULUS_CRC,
        addon_extra_crc: 0,
        addon_has_signature: 1,
    })
    .collect()
}

fn read_encrypted_raw(
    stream: &mut TcpStream,
    decrypter: &mut DecrypterHalf,
) -> Result<(u16, Vec<u8>), String> {
    let header = decrypter
        .read_and_decrypt_server_header(&mut *stream)
        .map_err(|e| format!("read encrypted server header failed: {e:?}"))?;
    if header.size < 2 {
        return Err(format!(
            "invalid encrypted server header size={} opcode=0x{:04X}",
            header.size, header.opcode
        ));
    }

    let payload_len = usize::from(header.size - 2);
    let mut payload = vec![0u8; payload_len];
    stream
        .read_exact(&mut payload)
        .map_err(|e| format!("read encrypted server payload failed: {e:?}"))?;
    Ok((header.opcode, payload))
}

fn write_encrypted_raw(
    stream: &mut TcpStream,
    encrypter: &mut EncrypterHalf,
    opcode: u32,
    payload: &[u8],
) -> Result<(), String> {
    let size = u16::try_from(payload.len() + 4)
        .map_err(|_| format!("client payload too large for opcode 0x{opcode:04X}"))?;
    let header = encrypter.encrypt_client_header(size, opcode);
    stream
        .write_all(&header)
        .map_err(|e| format!("write encrypted client header failed: {e:?}"))?;
    stream
        .write_all(payload)
        .map_err(|e| format!("write encrypted client payload failed: {e:?}"))
}

fn parse_raw_server_message(opcode: u16, payload: &[u8]) -> Result<ServerOpcodeMessage, String> {
    let size = u16::try_from(payload.len() + 2)
        .map_err(|_| format!("server payload too large for opcode 0x{opcode:04X}"))?;
    let mut wire = Vec::with_capacity(payload.len() + 4);
    wire.extend_from_slice(&size.to_be_bytes());
    wire.extend_from_slice(&opcode.to_le_bytes());
    wire.extend_from_slice(payload);
    ServerOpcodeMessage::read_unencrypted(&mut Cursor::new(wire))
        .map_err(|e| format!("parse raw server opcode 0x{opcode:04X} failed: {e:?}"))
}

fn update_mask_is_auctioneer(mask: &UpdateMask) -> bool {
    match mask {
        UpdateMask::Unit(unit) => unit
            .unit_npc_flags()
            .map(|flags| (flags as u32 & UNIT_NPC_FLAG_AUCTIONEER) != 0)
            .unwrap_or(false),
        _ => false,
    }
}

fn collect_auctioneer_guids(objects: &[Object], auctioneers: &mut HashSet<u64>) {
    for object in objects {
        let candidate = match object {
            Object::Values { guid1, mask1 } if update_mask_is_auctioneer(mask1) => {
                Some(guid1.guid())
            }
            Object::CreateObject { guid3, mask2, .. }
            | Object::CreateObject2 { guid3, mask2, .. }
                if update_mask_is_auctioneer(mask2) =>
            {
                Some(guid3.guid())
            }
            _ => None,
        };

        if let Some(guid) = candidate {
            if auctioneers.insert(guid) {
                println!("[AH] discovered auctioneer guid=0x{guid:016X}");
            }
        }
    }
}

fn inspect_update_packet(
    opcode: u16,
    payload: &[u8],
    auctioneers: &mut HashSet<u64>,
) -> Result<(), String> {
    if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
        return Ok(());
    }

    match parse_raw_server_message(opcode, payload)? {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message) => {
            collect_auctioneer_guids(&message.objects, auctioneers);
        }
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message) => {
            collect_auctioneer_guids(&message.objects, auctioneers);
        }
        _ => {}
    }
    Ok(())
}

fn parse_guid_override(value: &str) -> Result<u64, String> {
    let trimmed = value.trim();
    if let Some(hex) = trimmed.strip_prefix("0x").or_else(|| trimmed.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16).map_err(|e| format!("invalid WOW112_AH_GUID hex value: {e}"))
    } else {
        trimmed
            .parse::<u64>()
            .map_err(|e| format!("invalid WOW112_AH_GUID decimal value: {e}"))
    }
}

fn discover_auctioneer(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
) -> Result<u64, String> {
    if let Ok(value) = env::var("WOW112_AH_GUID") {
        let guid = parse_guid_override(&value)?;
        println!("[AH] using configured auctioneer guid=0x{guid:016X}");
        return Ok(guid);
    }

    println!("[AH] POC-02 discovering nearby auctioneer from object updates");
    let mut auctioneers = HashSet::new();
    for index in 0..512usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        inspect_update_packet(opcode, &payload, &mut auctioneers)?;

        if let Some(guid) = auctioneers.iter().next().copied() {
            println!("[AH] auctioneer candidate ready after rx[{index}]");
            return Ok(guid);
        }

        if index < 16 {
            println!(
                "[AH-DIAG] world rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    Err("no nearby UNIT_NPC_FLAG_AUCTIONEER found within 512 world packets".to_string())
}

fn send_auction_hello(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
) -> Result<u32, String> {
    println!("[AH] opening auction house guid=0x{auctioneer_guid:016X}");
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        u32::from(MSG_AUCTION_HELLO_OPCODE),
        &auctioneer_guid.to_le_bytes(),
    )?;

    let mut discovered = HashSet::new();
    for index in 0..128usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == MSG_AUCTION_HELLO_OPCODE {
            if payload.len() < 12 {
                return Err(format!(
                    "MSG_AUCTION_HELLO payload too short: {}",
                    payload.len()
                ));
            }
            let response_guid = u64::from_le_bytes(payload[0..8].try_into().unwrap());
            let auction_house = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            println!(
                "[AH] MSG_AUCTION_HELLO PASS guid=0x{response_guid:016X} house={auction_house}"
            );
            return Ok(auction_house);
        }

        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[AH-DIAG] hello wait rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    Err("server did not return MSG_AUCTION_HELLO within 128 packets".to_string())
}

fn build_read_only_auction_query(auctioneer_guid: u64) -> Vec<u8> {
    let mut payload = Vec::with_capacity(32);
    payload.extend_from_slice(&auctioneer_guid.to_le_bytes());
    payload.extend_from_slice(&0u32.to_le_bytes()); // list_start_item / page 0
    payload.push(0); // empty searched_name CString
    payload.push(0); // minimum_level
    payload.push(0); // maximum_level
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // any inventory slot
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // any item class
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // any item subclass
    payload.extend_from_slice(&u32::MAX.to_le_bytes()); // any quality
    payload.push(0); // usable=false
    payload
}

fn read_u32_at(payload: &[u8], offset: usize) -> Result<u32, String> {
    let end = offset + 4;
    let bytes = payload
        .get(offset..end)
        .ok_or_else(|| format!("auction result truncated at offset {offset}"))?;
    Ok(u32::from_le_bytes(bytes.try_into().unwrap()))
}

fn read_u64_at(payload: &[u8], offset: usize) -> Result<u64, String> {
    let end = offset + 8;
    let bytes = payload
        .get(offset..end)
        .ok_or_else(|| format!("auction result truncated at offset {offset}"))?;
    Ok(u64::from_le_bytes(bytes.try_into().unwrap()))
}

fn parse_auction_list_result(payload: &[u8]) -> Result<(), String> {
    if payload.len() < 8 {
        return Err(format!(
            "SMSG_AUCTION_LIST_RESULT payload too short: {}",
            payload.len()
        ));
    }

    let count = read_u32_at(payload, 0)? as usize;
    let records_size = count
        .checked_mul(AUCTION_RECORD_SIZE)
        .ok_or_else(|| "auction result record count overflow".to_string())?;
    let expected = 4usize
        .checked_add(records_size)
        .and_then(|v| v.checked_add(4))
        .ok_or_else(|| "auction result size overflow".to_string())?;

    if payload.len() < expected {
        return Err(format!(
            "SMSG_AUCTION_LIST_RESULT truncated: count={count} expected={expected} actual={}",
            payload.len()
        ));
    }

    let total = read_u32_at(payload, 4 + records_size)?;
    println!(
        "[AH] SMSG_AUCTION_LIST_RESULT PASS page0_records={count} total={total} payload={}",
        payload.len()
    );

    for index in 0..count.min(10) {
        let base = 4 + index * AUCTION_RECORD_SIZE;
        let auction_id = read_u32_at(payload, base)?;
        let item_entry = read_u32_at(payload, base + 4)?;
        let item_count = read_u32_at(payload, base + 20)?;
        let owner_guid = read_u64_at(payload, base + 28)?;
        let start_bid = read_u32_at(payload, base + 36)?;
        let minimum_bid = read_u32_at(payload, base + 40)?;
        let buyout = read_u32_at(payload, base + 44)?;
        let time_left_ms = read_u32_at(payload, base + 48)?;
        let highest_bid = read_u32_at(payload, base + 60)?;
        println!(
            "[AH] auction[{index}] id={auction_id} item={item_entry} count={item_count} start_bid={start_bid} min_bid={minimum_bid} buyout={buyout} highest_bid={highest_bid} time_ms={time_left_ms} owner=0x{owner_guid:016X}"
        );
    }

    if payload.len() > expected {
        println!(
            "[AH-DIAG] list result has {} trailing bytes after vanilla records",
            payload.len() - expected
        );
    }
    Ok(())
}

fn probe_read_only_auction_house(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
) -> Result<(), String> {
    let auctioneer_guid = discover_auctioneer(stream, crypto)?;
    let auction_house = send_auction_hello(stream, crypto, auctioneer_guid)?;

    let query = build_read_only_auction_query(auctioneer_guid);
    println!(
        "[AH] sending READ-ONLY page0 query house={auction_house} payload={} filters=ANY",
        query.len()
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_AUCTION_LIST_ITEMS_OPCODE,
        &query,
    )?;

    let mut discovered = HashSet::new();
    for index in 0..256usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            parse_auction_list_result(&payload)?;
            println!("[AH] POC-02 READ-ONLY PASS");
            return Ok(());
        }

        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[AH-DIAG] list wait rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    Err("SMSG_AUCTION_LIST_RESULT not received within 256 packets".to_string())
}

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
    let safe_prefix_len = auth_wire.len().min(24);
    println!(
        "[WORLD-DIAG] auth-session-out len={} prefix={} world-build={} server-id={} addons=octo-standard-12",
        auth_wire.len(),
        hex_prefix(&auth_wire[..safe_prefix_len]),
        OCTOWOW_WORLD_BUILD,
        server_id
    );
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

    probe_read_only_auction_house(stream, &mut crypto)?;
    Ok(())
}
