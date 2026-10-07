#![allow(dead_code)]
// Reuse the canonical read-only login/discovery chain. BUY code is not included.
include!("../../probes/Wow112HeadlessAndroid/src/world_poc05_retry.rs");
use crate::capture::Capture;
use serde_json::{json, Value};

fn parse_history_page(payload: &[u8], capture: &Capture) -> Result<(u32, Vec<Value>), String> {
    if payload.len() < 8 { return Err("auction payload shorter than 8 bytes".into()); }
    let count = read_u32_at(payload, 0)? as usize;
    if count > 50 { return Err(format!("page count exceeds 50: {count}")); }
    let expected = 8 + count * 64;
    if payload.len() != expected { return Err(format!("auction payload length mismatch expected={expected} actual={}", payload.len())); }
    let total = read_u32_at(payload, 4+count*64)?;
    let mut rows = Vec::with_capacity(count);
    for i in 0..count {
        let b = 4+i*64;
        let id = read_u32_at(payload,b)?;
        let item = read_u32_at(payload,b+4)?;
        let n = read_u32_at(payload,b+20)?;
        if id == 0 || item == 0 || n == 0 { return Err(format!("invalid auction tuple index={i}")); }
        let owner = read_u64_at(payload,b+28)?;
        rows.push(json!({"auction_id":id,"item_id":item,"count":n,
            "owner_token": if owner == 0 { None } else { Some(capture.owner_token(owner)) },
            "buyout_total_copper":read_u32_at(payload,b+44)?,
            "start_bid_copper":read_u32_at(payload,b+36)?,
            "min_increment_copper":read_u32_at(payload,b+40)?,
            "current_bid_copper":read_u32_at(payload,b+60)?,
            "time_left_raw":read_u32_at(payload,b+48)?, "time_left_unit":"ms",
            "variant_key":null,"variant_fields_verified":false,"record_index":i}));
    }
    Ok((total, rows))
}

fn request_history_page(stream: &mut TcpStream, crypto: &mut HeaderCrypto,
    auctioneer_guid: u64, page: u32, capture: &mut Capture) -> Result<usize,String> {
    let mut query = build_read_only_auction_query(auctioneer_guid);
    if query.len()<12 { return Err("invalid auction query".into()); }
    query[8..12].copy_from_slice(&(page*50).to_le_bytes());
    write_encrypted_raw(stream,crypto.encrypter(),CMSG_AUCTION_LIST_ITEMS_OPCODE,&query)?;
    let mut discovered = HashSet::new();
    for _ in 0..256 {
        let (opcode,payload)=read_encrypted_raw(stream,crypto.decrypter())?;
        if opcode == SMSG_AUCTION_LIST_RESULT_OPCODE {
            let (total,records)=parse_history_page(&payload,capture)?;
            let n=records.len(); capture.page(page,total,&payload,records)?;
            return Ok(n);
        }
        inspect_update_packet(opcode,&payload,&mut discovered)?;
    }
    Err("auction response not received; no request retry permitted".into())
}

// A localhost fixture transport supplies real 64-byte auction payloads to the
// same parser/capture used by live mode. Its framing is a test-only envelope.
pub fn fixture_scan(stream: &mut TcpStream,capture: &mut Capture,max_pages:u32)->Result<(),String>{
    if max_pages==0 || max_pages>4096 { return Err("max pages must be 1..4096".into()); }
    for page in 0..max_pages {
        let mut request = [0u8; 8];
        request[..4].copy_from_slice(&0x0258u32.to_le_bytes());
        request[4..].copy_from_slice(&page.to_le_bytes());
        stream.write_all(&request).map_err(|e|e.to_string())?;
        let mut size=[0u8;4]; stream.read_exact(&mut size).map_err(|e|e.to_string())?;
        let n=u32::from_le_bytes(size) as usize;
        if n>3208 { return Err("fixture frame too large".into()); }
        let mut payload=vec![0;n]; stream.read_exact(&mut payload).map_err(|e|e.to_string())?;
        let (total,records)=parse_history_page(&payload,capture)?;
        let count=records.len(); capture.page(page,total,&payload,records)?;
        if count<50 {capture.finish("completed","end_of_listing")?;return Ok(());}
    }
    capture.finish("truncated","page_limit")?;
    Err("full scan truncated at page limit".into())
}

pub fn login_history(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    capture: &mut crate::capture::Capture,
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
    let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter())
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
    let player_guid = selected.guid.guid();
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

    // A history scan needs an auctioneer, not gold, bags or a mailbox snapshot.
    // Reuse the proven explicit AH target when supplied; retain discovery fallback.
    let candidates = if let Ok(raw_guid) = env::var("WOW112_AH_GUID") {
        let mut targets = HashSet::new();
        targets.insert(parse_guid_override("WOW112_AH_GUID", &raw_guid)?);
        targets
    } else {
        discover_poc05_context_retry(stream, &mut crypto, player_guid)?.0
    };
    let (auctioneer_guid, auction_house_id) = poc05_send_auction_hello_candidates(stream, &mut crypto, candidates)?;
    capture.identify_market(server_id as u32, auction_house_id as u32);
    let max_pages: u32 = env::var("WOW112_AH_FULL_SCAN_MAX_PAGES").unwrap_or_else(|_| "2048".into()).parse().map_err(|_| "invalid max pages")?;
    if max_pages == 0 || max_pages > 4096 { return Err("max pages must be 1..4096".into()); }
    for page in 0..max_pages {
        let n = request_history_page(stream, &mut crypto, auctioneer_guid, page, capture)?;
        if n < 50 { capture.finish("completed", "end_of_listing")?; return Ok(()); }
    }
    capture.finish("truncated", "page_limit")?;
    Err("full scan truncated at page limit".into())
}
