include!("world_poc06.rs");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Poc07Mode {
    ScanOnly,
    BuyOne,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Poc07Strategy {
    Vendor,
    Disenchant,
}

impl Poc07Strategy {
    fn as_str(self) -> &'static str {
        match self {
            Self::Vendor => "vendor",
            Self::Disenchant => "de",
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Poc07Candidate {
    page: u32,
    record: Poc06AuctionRecord,
    strategy: Poc07Strategy,
    unit_value: u32,
    gross_value: u64,
    expected_profit: i64,
}

fn poc07_env_u32_default(name: &str, default_value: u32) -> Result<u32, String> {
    match env::var(name) {
        Ok(raw) => raw
            .trim()
            .parse::<u32>()
            .map_err(|e| format!("invalid {name}={raw:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn poc07_parse_mode() -> Result<Poc07Mode, String> {
    let raw = env::var("WOW112_AUTOBUY_ACTION").unwrap_or_else(|_| "scan-only".to_string());
    match raw.trim().to_ascii_lowercase().as_str() {
        "" | "scan" | "scan-only" | "readonly" | "read-only" | "0" => Ok(Poc07Mode::ScanOnly),
        "buy" | "buy-one" | "1" => {
            if env::var("WOW112_AUTOBUY_CONFIRM").unwrap_or_default() != "YES" {
                return Err("POC07 buy-one blocked: set WOW112_AUTOBUY_CONFIRM=YES explicitly".to_string());
            }
            let max_purchases = poc07_env_u32_default("WOW112_AUTOBUY_MAX_PURCHASES", 1)?;
            if max_purchases != 1 {
                return Err(format!(
                    "POC07 fast-track hard guard requires WOW112_AUTOBUY_MAX_PURCHASES=1, got {max_purchases}"
                ));
            }
            Ok(Poc07Mode::BuyOne)
        }
        _ => Err(format!("unsupported WOW112_AUTOBUY_ACTION={raw:?}")),
    }
}

fn poc07_strategy_flags() -> Result<(bool, bool), String> {
    let raw = env::var("WOW112_AUTOBUY_STRATEGY").unwrap_or_else(|_| "both".to_string());
    match raw.trim().to_ascii_lowercase().as_str() {
        "vendor" => Ok((true, false)),
        "de" | "disenchant" => Ok((false, true)),
        "both" | "all" | "" => Ok((true, true)),
        _ => Err(format!("unsupported WOW112_AUTOBUY_STRATEGY={raw:?}")),
    }
}

fn poc07_parse_value_map(name: &str) -> Result<std::collections::HashMap<u32, u32>, String> {
    let raw = env::var(name).unwrap_or_default();
    let mut map = std::collections::HashMap::new();
    for token in raw.split(|c| c == ',' || c == ';') {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        let (item_raw, value_raw) = token
            .split_once(':')
            .or_else(|| token.split_once('='))
            .ok_or_else(|| format!("invalid {name} token={token:?}; expected item_id:value"))?;
        let item_id = item_raw
            .trim()
            .parse::<u32>()
            .map_err(|e| format!("invalid {name} item id in {token:?}: {e}"))?;
        let unit_value = value_raw
            .trim()
            .parse::<u32>()
            .map_err(|e| format!("invalid {name} value in {token:?}: {e}"))?;
        if item_id == 0 || unit_value == 0 {
            return Err(format!("{name} refuses zero item/value in token={token:?}"));
        }
        map.insert(item_id, unit_value);
    }
    Ok(map)
}

fn poc07_parse_blacklist() -> Result<HashSet<u32>, String> {
    let raw = env::var("WOW112_AUTOBUY_BLACKLIST").unwrap_or_default();
    let mut set = HashSet::new();
    for token in raw.split(|c| c == ',' || c == ';' || c == ' ') {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        let item_id = token
            .parse::<u32>()
            .map_err(|e| format!("invalid WOW112_AUTOBUY_BLACKLIST item={token:?}: {e}"))?;
        if item_id != 0 {
            set.insert(item_id);
        }
    }
    Ok(set)
}

fn poc07_request_auction_page(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    page: u32,
    label: &str,
) -> Result<Vec<Poc06AuctionRecord>, String> {
    let list_from = page
        .checked_mul(50)
        .ok_or_else(|| format!("AH page overflow page={page}"))?;
    let mut query = build_read_only_auction_query(auctioneer_guid);
    if query.len() < 12 {
        return Err(format!("auction query unexpectedly short: {}", query.len()));
    }
    query[8..12].copy_from_slice(&list_from.to_le_bytes());
    println!(
        "[POC07-AH] query label={label} page={page} listfrom={list_from} house={auction_house} payload={}",
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
            println!(
                "[POC07-AH] snapshot PASS label={label} page={page} records={}",
                records.len()
            );
            return Ok(records);
        }
        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 8 {
            println!(
                "[POC07-AH-DIAG] wait label={label} page={page} rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    Err(format!(
        "SMSG_AUCTION_LIST_RESULT not received within 256 packets label={label} page={page}"
    ))
}

fn poc07_consider_candidate(
    page: u32,
    record: Poc06AuctionRecord,
    vendor_values: &std::collections::HashMap<u32, u32>,
    de_values: &std::collections::HashMap<u32, u32>,
    use_vendor: bool,
    use_de: bool,
    max_buyout: u32,
    min_profit: i64,
    blacklist: &HashSet<u32>,
) -> Option<Poc07Candidate> {
    if record.buyout == 0 || record.buyout > max_buyout || record.count == 0 || blacklist.contains(&record.item_id) {
        return None;
    }

    let mut best: Option<Poc07Candidate> = None;
    let mut consider = |strategy: Poc07Strategy, unit_value: u32| {
        let gross_value = u64::from(unit_value).saturating_mul(u64::from(record.count));
        let expected_profit_i128 = i128::from(gross_value) - i128::from(record.buyout);
        let expected_profit = expected_profit_i128
            .clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64;
        if expected_profit < min_profit {
            return;
        }
        let candidate = Poc07Candidate {
            page,
            record,
            strategy,
            unit_value,
            gross_value,
            expected_profit,
        };
        let replace = best
            .as_ref()
            .map(|current| {
                candidate.expected_profit > current.expected_profit
                    || (candidate.expected_profit == current.expected_profit
                        && candidate.gross_value > current.gross_value)
            })
            .unwrap_or(true);
        if replace {
            best = Some(candidate);
        }
    };

    if use_vendor {
        if let Some(value) = vendor_values.get(&record.item_id).copied() {
            consider(Poc07Strategy::Vendor, value);
        }
    }
    if use_de {
        if let Some(value) = de_values.get(&record.item_id).copied() {
            consider(Poc07Strategy::Disenchant, value);
        }
    }
    best
}

fn poc07_print_candidates(candidates: &[Poc07Candidate]) {
    println!(
        "[POC07] QUALIFIED candidates={} showing={}",
        candidates.len(),
        candidates.len().min(20)
    );
    for (rank, candidate) in candidates.iter().take(20).enumerate() {
        println!(
            "[POC07-CANDIDATE] rank={rank} page={} strategy={} auction_id={} item_id={} count={} buyout={} ({}) unit_value={} gross_value={} expected_profit={} owner=0x{:016X}",
            candidate.page,
            candidate.strategy.as_str(),
            candidate.record.auction_id,
            candidate.record.item_id,
            candidate.record.count,
            candidate.record.buyout,
            poc06_format_money(candidate.record.buyout),
            candidate.unit_value,
            candidate.gross_value,
            candidate.expected_profit,
            candidate.record.owner_guid
        );
    }
}

fn poc07_buy_exact_one(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    mailbox_guid: u64,
    candidate: Poc07Candidate,
    mutation_committed: &mut bool,
) -> Result<(), String> {
    if *mutation_committed {
        return Err("AH_MUTATION_BLOCKED POC07 buy-one already committed in this process".to_string());
    }

    let fresh_records = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-fresh-precheck",
    )?;
    let action = Poc06AhAction::GuardedBuy {
        auction_id: candidate.record.auction_id,
        item_id: candidate.record.item_id,
        count: candidate.record.count,
        expected_buyout: candidate.record.buyout,
        max_price: candidate.record.buyout,
    };
    let target = poc06_validate_target(action, &fresh_records)?;
    let before_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;

    println!(
        "[POC07-BUY] SELECTED page={} strategy={} auction_id={} item_id={} count={} buyout={} expected_profit={} HARD_MAX_PURCHASES=1",
        candidate.page,
        candidate.strategy.as_str(),
        target.auction_id,
        target.item_id,
        target.count,
        target.buyout,
        candidate.expected_profit
    );

    let mut request = Vec::with_capacity(16);
    request.extend_from_slice(&auctioneer_guid.to_le_bytes());
    request.extend_from_slice(&target.auction_id.to_le_bytes());
    request.extend_from_slice(&target.buyout.to_le_bytes());
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
        "[POC07-BUY] SENT auction_id={} price={} NO_AUTO_RETRY_FROM_THIS_POINT=YES",
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
                "[POC07-BUY] result auction_id={response_auction_id} action={response_action} error={response_error} payload={}",
                payload.len()
            );
            if response_auction_id != target.auction_id {
                continue;
            }
            if response_action != POC06_AUCTION_ACTION_BID {
                return Err(format!(
                    "AH_MUTATION_UNCERTAIN auction_id={}: unexpected action={} expected={}",
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
                "[POC07-BUY] SERVER PASS auction_id={} action={} result=0",
                target.auction_id, response_action
            );
            break;
        }
        if index < 16 {
            println!(
                "[POC07-BUY-DIAG] wait rx[{index}] opcode=0x{server_opcode:04X} payload={}",
                payload.len()
            );
        }
    }
    if !server_confirmed {
        return Err(format!(
            "AH_MUTATION_UNCERTAIN auction_id={}: no command result within 256 packets",
            target.auction_id
        ));
    }

    let after_auctions = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-post-buy-reconcile",
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
    poc06_reconcile_buy(target, &after_auctions, &before_mail, &after_mail)?;
    println!("[POC07-BUY] BUY-ONE PASS purchases=1");
    Ok(())
}

pub fn login_poc07(
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

    let mode = poc07_parse_mode()?;
    let (use_vendor, use_de) = poc07_strategy_flags()?;
    let vendor_values = poc07_parse_value_map("WOW112_VENDOR_VALUES")?;
    let de_values = poc07_parse_value_map("WOW112_DE_VALUES")?;
    let blacklist = poc07_parse_blacklist()?;
    let page_start = poc07_env_u32_default("WOW112_AH_SCAN_PAGE_START", 12)?;
    let page_count = poc07_env_u32_default("WOW112_AH_SCAN_PAGES", 1)?;
    if page_count == 0 || page_count > 32 {
        return Err(format!("WOW112_AH_SCAN_PAGES must be 1..32, got {page_count}"));
    }
    let max_buyout = match mode {
        Poc07Mode::ScanOnly => poc07_env_u32_default("WOW112_AUTOBUY_MAX_BUYOUT", u32::MAX)?,
        Poc07Mode::BuyOne => poc06_env_u32("WOW112_AUTOBUY_MAX_BUYOUT")?,
    };
    let min_profit = i64::from(poc07_env_u32_default("WOW112_AUTOBUY_MIN_PROFIT", 1)?);

    if use_vendor && vendor_values.is_empty() && !use_de {
        return Err("vendor strategy selected but WOW112_VENDOR_VALUES is empty".to_string());
    }
    if use_de && de_values.is_empty() && !use_vendor {
        return Err("DE strategy selected but WOW112_DE_VALUES is empty".to_string());
    }
    if vendor_values.is_empty() && de_values.is_empty() {
        return Err("POC07 requires at least one valuation map: WOW112_VENDOR_VALUES or WOW112_DE_VALUES".to_string());
    }

    println!(
        "[POC07] mode={mode:?} page_start={page_start} pages={page_count} max_buyout={max_buyout} min_profit={min_profit} vendor_values={} de_values={} blacklist={} hard_max_purchases=1",
        vendor_values.len(),
        de_values.len(),
        blacklist.len()
    );

    let (auctioneer_candidates, mailbox_guid) = discover_poc05_context_retry(stream, &mut crypto, player_guid)?;
    let (auctioneer_guid, auction_house) = poc05_send_auction_hello_candidates(stream, &mut crypto, auctioneer_candidates)?;

    let mut candidates = Vec::new();
    for offset in 0..page_count {
        let page = page_start
            .checked_add(offset)
            .ok_or_else(|| "AH scan page overflow".to_string())?;
        let records = poc07_request_auction_page(
            stream,
            &mut crypto,
            auctioneer_guid,
            auction_house,
            page,
            "poc07-scan",
        )?;
        for record in records {
            if let Some(candidate) = poc07_consider_candidate(
                page,
                record,
                &vendor_values,
                &de_values,
                use_vendor,
                use_de,
                max_buyout,
                min_profit,
                &blacklist,
            ) {
                candidates.push(candidate);
            }
        }
    }
    candidates.sort_by(|a, b| {
        b.expected_profit
            .cmp(&a.expected_profit)
            .then_with(|| a.record.buyout.cmp(&b.record.buyout))
            .then_with(|| a.record.auction_id.cmp(&b.record.auction_id))
    });
    poc07_print_candidates(&candidates);

    match mode {
        Poc07Mode::ScanOnly => {
            println!("[POC07] SCAN-ONLY PASS no_mutation=YES");
        }
        Poc07Mode::BuyOne => {
            let candidate = candidates
                .first()
                .copied()
                .ok_or_else(|| "POC07_NO_QUALIFIED_CANDIDATE no purchase sent".to_string())?;
            poc07_buy_exact_one(
                stream,
                &mut crypto,
                auctioneer_guid,
                auction_house,
                mailbox_guid,
                candidate,
                ah_mutation_committed,
            )?;
        }
    }

    if soak_seconds > 0 {
        maintain_world_session(stream, &mut crypto, soak_seconds)?;
    }
    println!("[POC07] POC-07 AUTOBUY ENGINE PASS mode={mode:?}");
    Ok(())
}
