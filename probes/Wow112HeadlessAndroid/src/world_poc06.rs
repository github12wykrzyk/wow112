include!("world_poc05_retry.rs");

const POC06_CMSG_AUCTION_PLACE_BID_OPCODE: u32 = 0x025A;
const POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE: u16 = 0x025B;

#[derive(Debug, Clone, Copy)]
struct Poc06AuctionRecord {
    auction_id: u32,
    item_id: u32,
    count: u32,
    owner_guid: u64,
    start_bid: u32,
    min_bid: u32,
    buyout: u32,
    time_left_ms: u32,
    highest_bid: u32,
}

#[derive(Debug, Clone, Copy)]
struct Poc06BuyContract {
    auction_id: u32,
    item_id: u32,
    count: u32,
    expected_buyout: u32,
    max_price: u32,
}

#[derive(Debug, Clone, Copy)]
enum Poc06AhAction {
    ReadOnly,
    GuardedBuy(Poc06BuyContract),
    BuyCheapest { max_price: u32 },
}

fn poc06_env_u32(name: &str) -> Result<u32, String> {
    let raw = env::var(name).map_err(|_| format!("missing {name}"))?;
    raw.trim()
        .parse::<u32>()
        .map_err(|e| format!("invalid {name}={raw:?}: {e}"))
}

fn poc06_action_from_env() -> Result<Poc06AhAction, String> {
    let raw = env::var("WOW112_AH_ACTION").unwrap_or_else(|_| "read-only".to_string());
    let action = raw.trim().to_ascii_lowercase();
    if matches!(action.as_str(), "" | "read-only" | "readonly" | "scan" | "0") {
        return Ok(Poc06AhAction::ReadOnly);
    }

    let confirm = env::var("WOW112_AH_MUTATION_CONFIRM").unwrap_or_default();
    if confirm != "YES" {
        return Err(
            "AH_MUTATION_BLOCKED: set WOW112_AH_MUTATION_CONFIRM=YES explicitly".to_string(),
        );
    }

    match action.as_str() {
        "guarded-buy" | "buy" | "1" => {
            let contract = Poc06BuyContract {
                auction_id: poc06_env_u32("WOW112_AH_AUCTION_ID")?,
                item_id: poc06_env_u32("WOW112_AH_ITEM_ID")?,
                count: poc06_env_u32("WOW112_AH_COUNT")?,
                expected_buyout: poc06_env_u32("WOW112_AH_EXPECTED_BUYOUT")?,
                max_price: poc06_env_u32("WOW112_AH_MAX_PRICE")?,
            };
            if contract.auction_id == 0 || contract.item_id == 0 || contract.count == 0 {
                return Err("AH_MUTATION_BLOCKED: auction_id/item_id/count must be non-zero".to_string());
            }
            if contract.expected_buyout == 0 {
                return Err("AH_MUTATION_BLOCKED: expected_buyout must be > 0".to_string());
            }
            if contract.expected_buyout > contract.max_price {
                return Err(format!(
                    "AH_MUTATION_BLOCKED: expected_buyout={} exceeds max_price={}",
                    contract.expected_buyout, contract.max_price
                ));
            }
            Ok(Poc06AhAction::GuardedBuy(contract))
        }
        "buy-cheapest" | "cheapest" | "2" => {
            let max_price = poc06_env_u32("WOW112_AH_MAX_PRICE")?;
            if max_price == 0 {
                return Err("AH_MUTATION_BLOCKED: max_price must be > 0".to_string());
            }
            Ok(Poc06AhAction::BuyCheapest { max_price })
        }
        _ => Err(format!("unsupported WOW112_AH_ACTION={raw:?}")),
    }
}

fn poc06_parse_auction_list(payload: &[u8]) -> Result<(Vec<Poc06AuctionRecord>, u32), String> {
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
    let mut records = Vec::with_capacity(count);
    for index in 0..count {
        let base = 4 + index * AUCTION_RECORD_SIZE;
        records.push(Poc06AuctionRecord {
            auction_id: read_u32_at(payload, base)?,
            item_id: read_u32_at(payload, base + 4)?,
            count: read_u32_at(payload, base + 20)?,
            owner_guid: read_u64_at(payload, base + 28)?,
            start_bid: read_u32_at(payload, base + 36)?,
            min_bid: read_u32_at(payload, base + 40)?,
            buyout: read_u32_at(payload, base + 44)?,
            time_left_ms: read_u32_at(payload, base + 48)?,
            highest_bid: read_u32_at(payload, base + 60)?,
        });
    }
    Ok((records, total))
}

fn poc06_query_page0(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    label: &str,
) -> Result<Vec<Poc06AuctionRecord>, String> {
    let query = build_read_only_auction_query(auctioneer_guid);
    println!(
        "[AH] {label}: query page0 auctioneer=0x{auctioneer_guid:016X} payload={}",
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
            let (records, total) = poc06_parse_auction_list(&payload)?;
            println!(
                "[AH] {label}: SMSG_AUCTION_LIST_RESULT PASS page0_records={} total={total}",
                records.len()
            );
            return Ok(records);
        }
        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[AH-DIAG] {label} wait rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }
    Err(format!(
        "SMSG_AUCTION_LIST_RESULT not received within 256 packets during {label}"
    ))
}

fn poc06_print_buyout_candidates(records: &[Poc06AuctionRecord]) {
    let mut candidates = records
        .iter()
        .copied()
        .filter(|record| record.buyout > 0 && record.count > 0)
        .collect::<Vec<_>>();
    candidates.sort_by_key(|record| (record.buyout, record.auction_id));
    println!(
        "[POC06] BUYOUT CANDIDATES page0={} showing={}",
        candidates.len(),
        candidates.len().min(50)
    );
    for (index, record) in candidates.iter().take(50).enumerate() {
        println!(
            "[POC06-CANDIDATE] rank={index} auction_id={} item_id={} count={} buyout={} start_bid={} min_bid={} highest_bid={} time_ms={} owner=0x{:016X}",
            record.auction_id,
            record.item_id,
            record.count,
            record.buyout,
            record.start_bid,
            record.min_bid,
            record.highest_bid,
            record.time_left_ms,
            record.owner_guid
        );
    }
}

fn poc06_exact_match(
    record: &Poc06AuctionRecord,
    contract: Poc06BuyContract,
    player_guid: u64,
) -> Result<(), String> {
    if record.auction_id != contract.auction_id {
        return Err("AH_MUTATION_BLOCKED: internal auction_id mismatch".to_string());
    }
    if record.item_id != contract.item_id
        || record.count != contract.count
        || record.buyout != contract.expected_buyout
    {
        return Err(format!(
            "AH_MUTATION_BLOCKED: contract mismatch auction_id={} expected(item={},count={},buyout={}) live(item={},count={},buyout={})",
            contract.auction_id,
            contract.item_id,
            contract.count,
            contract.expected_buyout,
            record.item_id,
            record.count,
            record.buyout
        ));
    }
    if record.buyout == 0 {
        return Err(format!(
            "AH_MUTATION_BLOCKED: auction_id={} has no buyout",
            contract.auction_id
        ));
    }
    if record.buyout > contract.max_price {
        return Err(format!(
            "AH_MUTATION_BLOCKED: auction_id={} live_buyout={} exceeds max_price={}",
            contract.auction_id, record.buyout, contract.max_price
        ));
    }
    if record.owner_guid == player_guid {
        return Err(format!(
            "AH_MUTATION_BLOCKED: auction_id={} is owned by current character",
            contract.auction_id
        ));
    }
    Ok(())
}

fn poc06_select_contract(
    action: Poc06AhAction,
    records: &[Poc06AuctionRecord],
    player_guid: u64,
) -> Result<Option<Poc06BuyContract>, String> {
    match action {
        Poc06AhAction::ReadOnly => Ok(None),
        Poc06AhAction::GuardedBuy(contract) => {
            let live = records
                .iter()
                .find(|record| record.auction_id == contract.auction_id)
                .ok_or_else(|| {
                    format!(
                        "AH_MUTATION_BLOCKED: auction_id={} not present in initial page0 snapshot",
                        contract.auction_id
                    )
                })?;
            poc06_exact_match(live, contract, player_guid)?;
            Ok(Some(contract))
        }
        Poc06AhAction::BuyCheapest { max_price } => {
            let live = records
                .iter()
                .filter(|record| {
                    record.buyout > 0
                        && record.buyout <= max_price
                        && record.count > 0
                        && record.owner_guid != player_guid
                })
                .min_by_key(|record| (record.buyout, record.auction_id))
                .ok_or_else(|| {
                    format!(
                        "AH_MUTATION_BLOCKED: no page0 buyout candidate <= max_price={max_price}"
                    )
                })?;
            let contract = Poc06BuyContract {
                auction_id: live.auction_id,
                item_id: live.item_id,
                count: live.count,
                expected_buyout: live.buyout,
                max_price,
            };
            println!(
                "[AH-BUY] AUTO CONTRACT auction_id={} item_id={} count={} expected_buyout={} max_price={}",
                contract.auction_id,
                contract.item_id,
                contract.count,
                contract.expected_buyout,
                contract.max_price
            );
            Ok(Some(contract))
        }
    }
}

fn poc06_send_guarded_buy(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    player_guid: u64,
    contract: Poc06BuyContract,
    mutation_committed: &mut bool,
) -> Result<(), String> {
    if *mutation_committed {
        return Err(format!(
            "AH_MUTATION_ALREADY_COMMITTED auction_id={} - refusing any automatic repeat",
            contract.auction_id
        ));
    }

    println!(
        "[AH-BUY] REVALIDATE auction_id={} expected(item={},count={},buyout={}) max_price={}",
        contract.auction_id,
        contract.item_id,
        contract.count,
        contract.expected_buyout,
        contract.max_price
    );
    let fresh = poc06_query_page0(stream, crypto, auctioneer_guid, "revalidate")
        .map_err(|error| format!("AH_MUTATION_BLOCKED: revalidation failed before send: {error}"))?;
    let live = fresh
        .iter()
        .find(|record| record.auction_id == contract.auction_id)
        .ok_or_else(|| {
            format!(
                "AH_MUTATION_BLOCKED: auction_id={} disappeared before send",
                contract.auction_id
            )
        })?;
    poc06_exact_match(live, contract, player_guid)?;

    let mut request = Vec::with_capacity(16);
    request.extend_from_slice(&auctioneer_guid.to_le_bytes());
    request.extend_from_slice(&contract.auction_id.to_le_bytes());
    request.extend_from_slice(&contract.expected_buyout.to_le_bytes());
    println!(
        "[AH-BUY] ARMED auction_id={} item_id={} count={} price={} max_price={} auctioneer=0x{auctioneer_guid:016X}",
        contract.auction_id,
        contract.item_id,
        contract.count,
        contract.expected_buyout,
        contract.max_price
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        POC06_CMSG_AUCTION_PLACE_BID_OPCODE,
        &request,
    )
    .map_err(|error| {
        format!(
            "AH_MUTATION_UNCERTAIN auction_id={} during-send: {error}",
            contract.auction_id
        )
    })?;
    println!(
        "[AH-BUY] SENT auction_id={} price={}",
        contract.auction_id, contract.expected_buyout
    );

    let mut confirmed = false;
    for index in 0..256usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter()).map_err(|error| {
            format!(
                "AH_MUTATION_UNCERTAIN auction_id={} after-send: {error}",
                contract.auction_id
            )
        })?;
        if opcode == POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE {
            if payload.len() < 12 {
                return Err(format!(
                    "AH_MUTATION_UNCERTAIN auction_id={}: SMSG_AUCTION_COMMAND_RESULT payload too short {}",
                    contract.auction_id,
                    payload.len()
                ));
            }
            let response_auction_id = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            let response_action = u32::from_le_bytes(payload[4..8].try_into().unwrap());
            let response_result = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            let outbid = if payload.len() >= 16 {
                Some(u32::from_le_bytes(payload[12..16].try_into().unwrap()))
            } else {
                None
            };
            println!(
                "[AH-BUY] result auction_id={response_auction_id} action={response_action} result={response_result} outbid={outbid:?} payload={}",
                payload.len()
            );
            if response_auction_id != contract.auction_id {
                println!(
                    "[AH-BUY-DIAG] unrelated command result while waiting expected_auction_id={}",
                    contract.auction_id
                );
                continue;
            }
            if response_action != 2 {
                return Err(format!(
                    "AH_MUTATION_UNCERTAIN auction_id={}: unexpected command action={response_action}",
                    contract.auction_id
                ));
            }
            if response_result != 0 {
                return Err(format!(
                    "AH_MUTATION_CONFIRMED_FAILURE auction_id={} server_result={response_result}",
                    contract.auction_id
                ));
            }
            *mutation_committed = true;
            confirmed = true;
            println!(
                "[AH-BUY] SERVER PASS auction_id={} action=BID_PLACED result=OK",
                contract.auction_id
            );
            break;
        }
        if index < 12 {
            println!(
                "[AH-BUY-DIAG] wait rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    if !confirmed {
        return Err(format!(
            "AH_MUTATION_UNCERTAIN auction_id={}: no SMSG_AUCTION_COMMAND_RESULT within 256 packets",
            contract.auction_id
        ));
    }

    let after = poc06_query_page0(stream, crypto, auctioneer_guid, "reconcile").map_err(|error| {
        format!(
            "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: {error}",
            contract.auction_id
        )
    })?;
    if after
        .iter()
        .any(|record| record.auction_id == contract.auction_id)
    {
        return Err(format!(
            "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={} still present in page0 after server success",
            contract.auction_id
        ));
    }

    println!(
        "[AH-BUY] RECONCILE PASS auction_id={} absent_from_fresh_page0=true",
        contract.auction_id
    );
    println!("[POC06] GUARDED AH BUY PASS");
    Ok(())
}

pub fn login_poc06(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    mutation_committed: &mut bool,
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
        return Err(
            "world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string(),
        );
    }

    let action = poc06_action_from_env()?;
    println!(
        "[POC06] requested AH action={action:?} committed_before_session={mutation_committed}"
    );

    let (auctioneer_candidates, mailbox_guid) =
        discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
    let (auctioneer_guid, auction_house) =
        poc05_send_auction_hello_candidates(stream, &mut crypto, auctioneer_candidates)?;
    println!(
        "[POC06] active AH guid=0x{auctioneer_guid:016X} house={auction_house} mailbox=0x{mailbox_guid:016X}"
    );

    let initial = poc06_query_page0(stream, &mut crypto, auctioneer_guid, "initial")?;
    poc06_print_buyout_candidates(&initial);
    let contract = poc06_select_contract(action, &initial, player_guid)?;
    if let Some(contract) = contract {
        poc06_send_guarded_buy(
            stream,
            &mut crypto,
            auctioneer_guid,
            player_guid,
            contract,
            mutation_committed,
        )?;
    } else {
        println!("[POC06] READ-ONLY SCAN PASS");
    }

    maintain_world_session(stream, &mut crypto, soak_seconds)?;
    println!("[POC06] POC-06 AH CONTROL PASS");
    Ok(())
}
