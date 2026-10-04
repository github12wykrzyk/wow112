include!("world_poc05_retry.rs");

const POC06_CMSG_AUCTION_PLACE_BID_OPCODE: u32 = 0x025A;
const POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE: u16 = 0x025B;
const POC06_AUCTION_ACTION_BID: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Poc06AuctionRecord {
    auction_id: u32,
    item_id: u32,
    count: u32,
    owner_guid: u64,
    start_bid: u32,
    minimum_bid: u32,
    buyout: u32,
    time_left_ms: u32,
    highest_bid: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Poc06AhAction {
    ScanOnly,
    GuardedBuy {
        auction_id: u32,
        item_id: u32,
        count: u32,
        expected_buyout: u32,
        max_price: u32,
    },
}

fn poc06_env_u32(name: &str) -> Result<u32, String> {
    let raw = env::var(name).map_err(|_| format!("{name} is required for guarded-buy"))?;
    raw.trim()
        .parse::<u32>()
        .map_err(|e| format!("invalid {name}={raw:?}: {e}"))
}

fn poc06_ah_action_from_env() -> Result<Poc06AhAction, String> {
    let raw = env::var("WOW112_AH_ACTION").unwrap_or_else(|_| "scan-only".to_string());
    let action = raw.trim().to_ascii_lowercase();
    if matches!(action.as_str(), "" | "scan" | "scan-only" | "readonly" | "read-only" | "0") {
        return Ok(Poc06AhAction::ScanOnly);
    }

    if !matches!(action.as_str(), "buy" | "guarded-buy" | "1") {
        return Err(format!("unsupported WOW112_AH_ACTION={raw:?}"));
    }

    let confirm = env::var("WOW112_AH_MUTATION_CONFIRM").unwrap_or_default();
    if confirm != "YES" {
        return Err(
            "AH mutation blocked: set WOW112_AH_MUTATION_CONFIRM=YES explicitly".to_string(),
        );
    }

    let auction_id = poc06_env_u32("WOW112_AH_AUCTION_ID")?;
    let item_id = poc06_env_u32("WOW112_AH_ITEM_ID")?;
    let count = poc06_env_u32("WOW112_AH_COUNT")?;
    let expected_buyout = poc06_env_u32("WOW112_AH_EXPECTED_BUYOUT")?;
    let max_price = poc06_env_u32("WOW112_AH_MAX_PRICE")?;

    if auction_id == 0 {
        return Err("guarded-buy refuses auction_id=0".to_string());
    }
    if item_id == 0 {
        return Err("guarded-buy refuses item_id=0".to_string());
    }
    if count == 0 {
        return Err("guarded-buy refuses count=0".to_string());
    }
    if expected_buyout == 0 {
        return Err("guarded-buy refuses expected_buyout=0".to_string());
    }
    if max_price == 0 {
        return Err("guarded-buy refuses max_price=0".to_string());
    }
    if expected_buyout > max_price {
        return Err(format!(
            "guarded-buy refuses expected_buyout={expected_buyout} above max_price={max_price}"
        ));
    }

    Ok(Poc06AhAction::GuardedBuy {
        auction_id,
        item_id,
        count,
        expected_buyout,
        max_price,
    })
}

fn poc06_format_money(copper: u32) -> String {
    let gold = copper / 10_000;
    let silver = (copper / 100) % 100;
    let copper_remainder = copper % 100;
    format!("{gold}g{silver:02}s{copper_remainder:02}c")
}

fn poc06_parse_auction_list_result(payload: &[u8]) -> Result<Vec<Poc06AuctionRecord>, String> {
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

    let mut records = Vec::with_capacity(count);
    for index in 0..count {
        let base = 4 + index * AUCTION_RECORD_SIZE;
        records.push(Poc06AuctionRecord {
            auction_id: read_u32_at(payload, base)?,
            item_id: read_u32_at(payload, base + 4)?,
            count: read_u32_at(payload, base + 20)?,
            owner_guid: read_u64_at(payload, base + 28)?,
            start_bid: read_u32_at(payload, base + 36)?,
            minimum_bid: read_u32_at(payload, base + 40)?,
            buyout: read_u32_at(payload, base + 44)?,
            time_left_ms: read_u32_at(payload, base + 48)?,
            highest_bid: read_u32_at(payload, base + 60)?,
        });
    }

    if payload.len() > expected {
        println!(
            "[AH-DIAG] list result has {} trailing bytes after vanilla records",
            payload.len() - expected
        );
    }

    Ok(records)
}

fn poc06_print_buy_candidates(records: &[Poc06AuctionRecord]) {
    let mut candidates = records
        .iter()
        .copied()
        .filter(|record| record.buyout > 0)
        .collect::<Vec<_>>();
    candidates.sort_by_key(|record| (record.buyout, record.auction_id));

    println!(
        "[POC06] BUY CANDIDATES page0 buyout_gt_zero={} showing={}",
        candidates.len(),
        candidates.len().min(20)
    );
    for (index, record) in candidates.iter().take(20).enumerate() {
        println!(
            "[POC06-CANDIDATE] rank={index} auction_id={} item_id={} count={} buyout={} ({}) start_bid={} min_bid={} highest_bid={} time_ms={} owner=0x{:016X}",
            record.auction_id,
            record.item_id,
            record.count,
            record.buyout,
            poc06_format_money(record.buyout),
            record.start_bid,
            record.minimum_bid,
            record.highest_bid,
            record.time_left_ms,
            record.owner_guid
        );
    }
}

fn poc06_request_auction_page0(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    label: &str,
) -> Result<Vec<Poc06AuctionRecord>, String> {
    let query = build_read_only_auction_query(auctioneer_guid);
    println!(
        "[AH] sending page0 query label={label} house={auction_house} payload={} filters=ANY",
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
            let records = poc06_parse_auction_list_result(&payload)?;
            println!("[AH] page0 snapshot PASS label={label} records={}", records.len());
            return Ok(records);
        }

        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[AH-DIAG] list wait label={label} rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    Err(format!(
        "SMSG_AUCTION_LIST_RESULT not received within 256 packets label={label}"
    ))
}

fn poc06_validate_target(
    action: Poc06AhAction,
    records: &[Poc06AuctionRecord],
) -> Result<Poc06AuctionRecord, String> {
    let Poc06AhAction::GuardedBuy {
        auction_id,
        item_id,
        count,
        expected_buyout,
        max_price,
    } = action
    else {
        return Err("internal error: target validation requested outside guarded-buy".to_string());
    };

    let target = records
        .iter()
        .copied()
        .find(|record| record.auction_id == auction_id)
        .ok_or_else(|| {
            format!(
                "AH_MUTATION_PRECHECK_BLOCKED auction_id={auction_id}: auction not present in fresh page0 snapshot"
            )
        })?;

    if target.item_id != item_id {
        return Err(format!(
            "AH_MUTATION_PRECHECK_BLOCKED auction_id={auction_id}: item mismatch live={} expected={item_id}",
            target.item_id
        ));
    }
    if target.count != count {
        return Err(format!(
            "AH_MUTATION_PRECHECK_BLOCKED auction_id={auction_id}: count mismatch live={} expected={count}",
            target.count
        ));
    }
    if target.buyout == 0 {
        return Err(format!(
            "AH_MUTATION_PRECHECK_BLOCKED auction_id={auction_id}: live buyout is zero"
        ));
    }
    if target.buyout != expected_buyout {
        return Err(format!(
            "AH_MUTATION_PRECHECK_BLOCKED auction_id={auction_id}: buyout mismatch live={} expected={expected_buyout}",
            target.buyout
        ));
    }
    if target.buyout > max_price {
        return Err(format!(
            "AH_MUTATION_PRECHECK_BLOCKED auction_id={auction_id}: live buyout={} exceeds max_price={max_price}",
            target.buyout
        ));
    }

    println!(
        "[AH-BUY] PRECHECK PASS auction_id={} item_id={} count={} exact_buyout={} ({}) max_price={} ({})",
        target.auction_id,
        target.item_id,
        target.count,
        target.buyout,
        poc06_format_money(target.buyout),
        max_price,
        poc06_format_money(max_price)
    );
    Ok(target)
}

fn poc06_reconcile_buy(
    target: Poc06AuctionRecord,
    after_auctions: &[Poc06AuctionRecord],
    before_mail: &[Poc05MailRecord],
    after_mail: &[Poc05MailRecord],
) -> Result<(), String> {
    let auction_absent = !after_auctions
        .iter()
        .any(|record| record.auction_id == target.auction_id);

    let before_mail_ids = before_mail
        .iter()
        .map(|mail| mail.id)
        .collect::<HashSet<_>>();
    let matching_new_mail = after_mail.iter().find(|mail| {
        !before_mail_ids.contains(&mail.id) && mail.item == target.item_id && mail.stack != 0
    });

    println!(
        "[AH-BUY] RECONCILE auction_id={} auction_absent={} new_matching_mail={}",
        target.auction_id,
        auction_absent,
        matching_new_mail.is_some()
    );

    if let Some(mail) = matching_new_mail {
        println!(
            "[AH-BUY] RECONCILE MAIL PASS mail_id={} item_id={} stack={} cod={} money={}",
            mail.id, mail.item, mail.stack, mail.cod, mail.money
        );
    }

    if auction_absent || matching_new_mail.is_some() {
        println!(
            "[AH-BUY] RECONCILE PASS auction_id={} item_id={} count={} buyout={}",
            target.auction_id, target.item_id, target.count, target.buyout
        );
        return Ok(());
    }

    Err(format!(
        "AH_MUTATION_RECONCILE_FAILED auction_id={}: auction still present and no new matching purchase mail observed",
        target.auction_id
    ))
}

fn poc06_perform_auction_action(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    mailbox_guid: u64,
    action: Poc06AhAction,
    before_auctions: &[Poc06AuctionRecord],
    before_mail: &[Poc05MailRecord],
    mutation_committed: &mut bool,
) -> Result<(), String> {
    if action == Poc06AhAction::ScanOnly {
        poc06_print_buy_candidates(before_auctions);
        println!("[AH-BUY] scan-only mode; no AH mutation sent");
        println!("[POC06] GUARDED AH BUY CONTROL PASS mode=scan-only");
        return Ok(());
    }

    let target = if *mutation_committed {
        let Poc06AhAction::GuardedBuy {
            auction_id,
            item_id,
            count,
            expected_buyout,
            ..
        } = action
        else {
            unreachable!();
        };
        Poc06AuctionRecord {
            auction_id,
            item_id,
            count,
            owner_guid: 0,
            start_bid: 0,
            minimum_bid: 0,
            buyout: expected_buyout,
            time_left_ms: 0,
            highest_bid: 0,
        }
    } else {
        poc06_validate_target(action, before_auctions)?
    };

    if *mutation_committed {
        println!(
            "[AH-BUY] mutation already server-confirmed before reconnect; reconcile only auction_id={}",
            target.auction_id
        );
        let after_auctions = poc06_request_auction_page0(
            stream,
            crypto,
            auctioneer_guid,
            auction_house,
            "reconnect-reconcile",
        )?;
        let after_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;
        poc06_reconcile_buy(target, &after_auctions, before_mail, &after_mail)?;
        println!("[POC06] GUARDED AH BUY CONTROL PASS mode=reconcile-only");
        return Ok(());
    }

    let mut request = Vec::with_capacity(16);
    request.extend_from_slice(&auctioneer_guid.to_le_bytes());
    request.extend_from_slice(&target.auction_id.to_le_bytes());
    request.extend_from_slice(&target.buyout.to_le_bytes());

    println!(
        "[AH-BUY] ARMED auction_id={} item_id={} count={} buyout={} ({}) max_price_guard=PASS auctioneer=0x{auctioneer_guid:016X}",
        target.auction_id,
        target.item_id,
        target.count,
        target.buyout,
        poc06_format_money(target.buyout)
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
            target.auction_id
        )
    })?;
    println!(
        "[AH-BUY] SENT auction_id={} price={} NO_AUTO_RETRY_FROM_THIS_POINT=YES",
        target.auction_id, target.buyout
    );

    let mut server_confirmed = false;
    for index in 0..256usize {
        let (server_opcode, payload) = read_encrypted_raw(stream, crypto.decrypter()).map_err(|error| {
            format!(
                "AH_MUTATION_UNCERTAIN auction_id={} after-send: {error}",
                target.auction_id
            )
        })?;

        if server_opcode == POC06_SMSG_AUCTION_COMMAND_RESULT_OPCODE {
            if payload.len() < 12 {
                return Err(format!(
                    "AH_MUTATION_UNCERTAIN auction_id={}: SMSG_AUCTION_COMMAND_RESULT payload too short {}",
                    target.auction_id,
                    payload.len()
                ));
            }

            let response_auction_id = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            let response_action = u32::from_le_bytes(payload[4..8].try_into().unwrap());
            let response_error = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            println!(
                "[AH-BUY] result auction_id={response_auction_id} action={response_action} error={response_error} payload={}",
                payload.len()
            );

            if response_auction_id != target.auction_id {
                println!(
                    "[AH-BUY-DIAG] unrelated command result while waiting expected_auction={}",
                    target.auction_id
                );
                continue;
            }
            if response_action != POC06_AUCTION_ACTION_BID {
                return Err(format!(
                    "AH_MUTATION_UNCERTAIN auction_id={}: unexpected command action={} expected={}",
                    target.auction_id, response_action, POC06_AUCTION_ACTION_BID
                ));
            }
            if response_error != 0 {
                return Err(format!(
                    "AH_MUTATION_CONFIRMED_FAILURE auction_id={} server_action={} server_error={}",
                    target.auction_id, response_action, response_error
                ));
            }

            *mutation_committed = true;
            server_confirmed = true;
            println!(
                "[AH-BUY] SERVER PASS auction_id={} action={} result=0",
                target.auction_id, response_action
            );
            break;
        }

        if index < 16 {
            println!(
                "[AH-BUY-DIAG] wait rx[{index}] opcode=0x{server_opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    if !server_confirmed {
        return Err(format!(
            "AH_MUTATION_UNCERTAIN auction_id={}: no SMSG_AUCTION_COMMAND_RESULT within 256 packets",
            target.auction_id
        ));
    }

    let after_auctions = poc06_request_auction_page0(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        "post-buy-reconcile",
    )
    .map_err(|error| {
        format!(
            "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: AH snapshot failed: {error}",
            target.auction_id
        )
    })?;
    let after_mail = poc05_request_mail_list(stream, crypto, mailbox_guid).map_err(|error| {
        format!(
            "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: mailbox snapshot failed: {error}",
            target.auction_id
        )
    })?;
    poc06_reconcile_buy(target, &after_auctions, before_mail, &after_mail)?;
    println!("[POC06] GUARDED AH BUY CONTROL PASS mode=guarded-buy");
    Ok(())
}

pub fn login_poc06(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
    ah_mutation_committed: &mut bool,
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

    let action = poc06_ah_action_from_env()?;
    println!(
        "[POC06] requested AH action={action:?} committed_before_session={ah_mutation_committed}"
    );

    let (auctioneer_candidates, mailbox_guid) =
        discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
    let (auctioneer_guid, auction_house) =
        poc05_send_auction_hello_candidates(stream, &mut crypto, auctioneer_candidates)?;

    let before_auctions = poc06_request_auction_page0(
        stream,
        &mut crypto,
        auctioneer_guid,
        auction_house,
        "pre-mutation-revalidate",
    )?;
    let before_mail = poc05_request_mail_list(stream, &mut crypto, mailbox_guid)?;

    poc06_perform_auction_action(
        stream,
        &mut crypto,
        auctioneer_guid,
        auction_house,
        mailbox_guid,
        action,
        &before_auctions,
        &before_mail,
        ah_mutation_committed,
    )?;

    maintain_world_session(stream, &mut crypto, soak_seconds)?;
    println!("[POC06] POC-06 GUARDED AH BUY PASS");
    Ok(())
}
