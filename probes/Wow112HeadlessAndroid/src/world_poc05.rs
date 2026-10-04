include!("world.rs");

const POC05_SMSG_SEND_MAIL_RESULT_OPCODE: u16 = 0x0239;
const POC05_CMSG_MAIL_TAKE_MONEY_OPCODE: u32 = 0x0245;
const POC05_CMSG_MAIL_TAKE_ITEM_OPCODE: u32 = 0x0246;
const POC05_SETTLE_PACKETS: usize = 128;

#[derive(Debug, Clone)]
struct Poc05InventoryEntry {
    entry: i32,
    stack: i32,
    kind: &'static str,
}

#[derive(Debug, Default)]
struct Poc05Snapshot {
    coinage: Option<u32>,
    items: std::collections::HashMap<u64, Poc05InventoryEntry>,
}

#[derive(Debug, Clone)]
struct Poc05MailRecord {
    id: u32,
    item: u32,
    stack: u8,
    money: u32,
    cod: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Poc05MailAction {
    ReadOnly,
    TakeMoney(u32),
    TakeItem(u32),
}

fn poc05_capture_item(
    object_guid: u64,
    owner_guid: Option<u64>,
    entry: Option<i32>,
    stack: Option<i32>,
    kind: &'static str,
    player_guid: u64,
    snapshot: &mut Poc05Snapshot,
) {
    let known = snapshot.items.get(&object_guid).cloned();
    if owner_guid == Some(player_guid) || known.is_some() {
        let previous_entry = known.as_ref().map(|item| item.entry).unwrap_or(0);
        let previous_stack = known.as_ref().map(|item| item.stack).unwrap_or(1);
        snapshot.items.insert(
            object_guid,
            Poc05InventoryEntry {
                entry: entry.unwrap_or(previous_entry),
                stack: stack.unwrap_or(previous_stack).max(1),
                kind,
            },
        );
    }
}

fn poc05_guarded_owner_guid<F>(object_guid: u64, kind: &'static str, getter: F) -> Option<u64>
where
    F: FnOnce() -> Option<u64>,
{
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(getter));
    std::panic::set_hook(previous_hook);

    match result {
        Ok(value) => value,
        Err(_) => {
            println!(
                "[POC05-DIAG] partial {kind} owner GUID skipped object=0x{object_guid:016X}"
            );
            None
        }
    }
}

fn poc05_capture_mask(
    object_guid: u64,
    mask: &UpdateMask,
    player_guid: u64,
    snapshot: &mut Poc05Snapshot,
) {
    match mask {
        UpdateMask::Player(player) if object_guid == player_guid => {
            if let Some(value) = player.player_field_coinage() {
                snapshot.coinage = Some(value as u32);
            }
        }
        UpdateMask::Item(item) => {
            let known = snapshot.items.contains_key(&object_guid);
            let owner_guid = if known {
                None
            } else {
                poc05_guarded_owner_guid(object_guid, "item", || {
                    item.item_owner().map(|guid| guid.guid())
                })
            };
            poc05_capture_item(
                object_guid,
                owner_guid,
                item.object_entry(),
                item.item_stack_count(),
                "item",
                player_guid,
                snapshot,
            );
        }
        UpdateMask::Container(container) => {
            let known = snapshot.items.contains_key(&object_guid);
            let owner_guid = if known {
                None
            } else {
                poc05_guarded_owner_guid(object_guid, "container", || {
                    container.item_owner().map(|guid| guid.guid())
                })
            };
            poc05_capture_item(
                object_guid,
                owner_guid,
                container.object_entry(),
                container.item_stack_count(),
                "container",
                player_guid,
                snapshot,
            );
        }
        _ => {}
    }
}

fn poc05_capture_objects(
    objects: &[Object],
    player_guid: u64,
    snapshot: &mut Poc05Snapshot,
    auctioneers: &mut HashSet<u64>,
    mailboxes: &mut HashSet<u64>,
) {
    collect_auctioneer_guids(objects, auctioneers);
    collect_mailbox_guids(objects, mailboxes);

    for object in objects {
        match object {
            Object::Values { guid1, mask1 } => {
                poc05_capture_mask(guid1.guid(), mask1, player_guid, snapshot);
            }
            Object::CreateObject { guid3, mask2, .. }
            | Object::CreateObject2 { guid3, mask2, .. } => {
                poc05_capture_mask(guid3.guid(), mask2, player_guid, snapshot);
            }
            _ => {}
        }
    }
}

fn poc05_inspect_update_packet(
    opcode: u16,
    payload: &[u8],
    player_guid: u64,
    snapshot: &mut Poc05Snapshot,
    auctioneers: &mut HashSet<u64>,
    mailboxes: &mut HashSet<u64>,
) {
    if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
        return;
    }

    let message = match parse_raw_server_message(opcode, payload) {
        Ok(message) => message,
        Err(error) => {
            println!(
                "[POC05-DIAG] object update skipped opcode=0x{opcode:04X} payload={} reason={error}",
                payload.len()
            );
            return;
        }
    };

    match message {
        ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message) => {
            poc05_capture_objects(
                &message.objects,
                player_guid,
                snapshot,
                auctioneers,
                mailboxes,
            );
        }
        ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message) => {
            poc05_capture_objects(
                &message.objects,
                player_guid,
                snapshot,
                auctioneers,
                mailboxes,
            );
        }
        _ => {}
    }
}

fn poc05_print_snapshot(snapshot: &Poc05Snapshot) -> Result<(), String> {
    let copper = snapshot
        .coinage
        .ok_or_else(|| "POC-05 did not observe PLAYER_FIELD_COINAGE".to_string())?;
    let gold = copper / 10_000;
    let silver = (copper / 100) % 100;
    let copper_remainder = copper % 100;
    println!(
        "[POC05] GOLD PASS copper={copper} formatted={gold}g{silver}s{copper_remainder}c"
    );

    let mut items = snapshot.items.iter().collect::<Vec<_>>();
    items.sort_by_key(|(guid, _)| **guid);
    let total_stack: i64 = items
        .iter()
        .map(|(_, item)| i64::from(item.stack.max(0)))
        .sum();
    println!(
        "[POC05] INVENTORY SNAPSHOT PASS objects={} total_stack={total_stack}",
        items.len()
    );
    for (index, (guid, item)) in items.iter().take(80).enumerate() {
        println!(
            "[POC05] inventory[{index}] guid=0x{guid:016X} entry={} stack={} kind={}",
            item.entry, item.stack, item.kind
        );
    }
    if items.len() > 80 {
        println!("[POC05] inventory truncated printed=80 total={}", items.len());
    }
    println!("[POC05] INVENTORY/GOLD PASS");
    Ok(())
}

fn discover_poc05_context(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    player_guid: u64,
) -> Result<(u64, u64), String> {
    let mut auctioneers = HashSet::new();
    let mut mailboxes = HashSet::new();
    let mut snapshot = Poc05Snapshot::default();
    let mut settle_packets = 0usize;

    if let Ok(value) = env::var("WOW112_AH_GUID") {
        let guid = parse_guid_override("WOW112_AH_GUID", &value)?;
        println!("[AH] using configured auctioneer guid=0x{guid:016X}");
        auctioneers.insert(guid);
    }
    if let Ok(value) = env::var("WOW112_MAILBOX_GUID") {
        let guid = parse_guid_override("WOW112_MAILBOX_GUID", &value)?;
        println!("[MAIL] using configured mailbox guid=0x{guid:016X}");
        mailboxes.insert(guid);
    }

    println!("[POC05] collecting player gold + inventory and interaction targets");
    for index in 0..1536usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        poc05_inspect_update_packet(
            opcode,
            &payload,
            player_guid,
            &mut snapshot,
            &mut auctioneers,
            &mut mailboxes,
        );

        if snapshot.coinage.is_some() {
            settle_packets = settle_packets.saturating_add(1);
        }

        if index < 20 {
            println!(
                "[POC05-DIAG] snapshot rx[{index}] opcode=0x{opcode:04X} payload={} coinage={} items={} targets={}/{}",
                payload.len(),
                snapshot.coinage.is_some(),
                snapshot.items.len(),
                auctioneers.len(),
                mailboxes.len()
            );
        }

        if snapshot.coinage.is_some()
            && settle_packets >= POC05_SETTLE_PACKETS
            && !auctioneers.is_empty()
            && !mailboxes.is_empty()
        {
            poc05_print_snapshot(&snapshot)?;
            let auctioneer = *auctioneers.iter().next().unwrap();
            let mailbox = *mailboxes.iter().next().unwrap();
            println!(
                "[POC05] context ready after rx[{index}] auctioneer=0x{auctioneer:016X} mailbox=0x{mailbox:016X}"
            );
            return Ok((auctioneer, mailbox));
        }
    }

    Err(format!(
        "POC-05 context incomplete after 1536 packets: coinage={} inventory={} auctioneers={} mailboxes={}",
        snapshot.coinage.is_some(),
        snapshot.items.len(),
        auctioneers.len(),
        mailboxes.len()
    ))
}

fn poc05_mail_action_from_env() -> Result<Poc05MailAction, String> {
    let raw = env::var("WOW112_MAIL_ACTION").unwrap_or_else(|_| "read-only".to_string());
    let action = raw.trim().to_ascii_lowercase();
    if matches!(action.as_str(), "" | "read-only" | "readonly" | "none" | "0") {
        return Ok(Poc05MailAction::ReadOnly);
    }

    let mail_id = env::var("WOW112_MAIL_ID")
        .map_err(|_| format!("WOW112_MAIL_ID is required for action {action}"))?
        .trim()
        .parse::<u32>()
        .map_err(|e| format!("invalid WOW112_MAIL_ID for action {action}: {e}"))?;

    let confirm = env::var("WOW112_MAIL_MUTATION_CONFIRM").unwrap_or_default();
    if confirm != "YES" {
        return Err(
            "mail mutation blocked: set WOW112_MAIL_MUTATION_CONFIRM=YES explicitly".to_string(),
        );
    }

    match action.as_str() {
        "take-money" | "money" | "1" => Ok(Poc05MailAction::TakeMoney(mail_id)),
        "take-item" | "item" | "2" => Ok(Poc05MailAction::TakeItem(mail_id)),
        _ => Err(format!("unsupported WOW112_MAIL_ACTION={raw:?}")),
    }
}

fn poc05_parse_mail_list(payload: &[u8]) -> Result<Vec<Poc05MailRecord>, String> {
    match parse_raw_server_message(SMSG_MAIL_LIST_RESULT_OPCODE, payload)? {
        ServerOpcodeMessage::SMSG_MAIL_LIST_RESULT(message) => {
            println!(
                "[MAIL] SMSG_MAIL_LIST_RESULT PASS mails={} payload={}",
                message.mails.len(),
                payload.len()
            );
            let mut records = Vec::with_capacity(message.mails.len());
            for (index, mail) in message.mails.iter().enumerate() {
                let money = mail.money.as_int();
                println!(
                    "[MAIL] mail[{index}] id={} type={:?} subject={:?} item={} stack={} money={} cod={} text_id={} checked=0x{:X} expires_days={:.3}",
                    mail.message_id,
                    mail.message_type,
                    mail.subject,
                    mail.item,
                    mail.item_stack_size,
                    money,
                    mail.cash_on_delivery_amount,
                    mail.item_text_id,
                    mail.checked_timestamp,
                    mail.expiration_time
                );
                records.push(Poc05MailRecord {
                    id: mail.message_id,
                    item: mail.item,
                    stack: mail.item_stack_size,
                    money,
                    cod: mail.cash_on_delivery_amount,
                });
            }
            Ok(records)
        }
        other => Err(format!(
            "expected SMSG_MAIL_LIST_RESULT after raw parse, got {other:?}"
        )),
    }
}

fn poc05_request_mail_list(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    mailbox_guid: u64,
) -> Result<Vec<Poc05MailRecord>, String> {
    println!("[MAIL] opening mailbox guid=0x{mailbox_guid:016X}");
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        CMSG_GET_MAIL_LIST_OPCODE,
        &mailbox_guid.to_le_bytes(),
    )?;

    let mut discovered = HashSet::new();
    for index in 0..256usize {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        if opcode == SMSG_MAIL_LIST_RESULT_OPCODE {
            let records = poc05_parse_mail_list(&payload)?;
            println!("[MAIL] POC-05 LIST PASS");
            return Ok(records);
        }
        inspect_update_packet(opcode, &payload, &mut discovered)?;
        if index < 12 {
            println!(
                "[MAIL-DIAG] list wait rx[{index}] opcode=0x{opcode:04X} payload={}",
                payload.len()
            );
        }
    }
    Err("SMSG_MAIL_LIST_RESULT not received within 256 packets".to_string())
}

fn poc05_reconcile_action(
    action: Poc05MailAction,
    records: &[Poc05MailRecord],
) -> Result<(), String> {
    match action {
        Poc05MailAction::ReadOnly => Ok(()),
        Poc05MailAction::TakeMoney(mail_id) => {
            let ok = records
                .iter()
                .find(|mail| mail.id == mail_id)
                .map(|mail| mail.money == 0)
                .unwrap_or(true);
            if ok {
                println!("[MAIL-ACTION] RECONCILE PASS action=take-money mail_id={mail_id}");
                Ok(())
            } else {
                Err(format!(
                    "MAIL_MUTATION_RECONCILE_FAILED action=take-money mail_id={mail_id}: money still present"
                ))
            }
        }
        Poc05MailAction::TakeItem(mail_id) => {
            let ok = records
                .iter()
                .find(|mail| mail.id == mail_id)
                .map(|mail| mail.item == 0 || mail.stack == 0)
                .unwrap_or(true);
            if ok {
                println!("[MAIL-ACTION] RECONCILE PASS action=take-item mail_id={mail_id}");
                Ok(())
            } else {
                Err(format!(
                    "MAIL_MUTATION_RECONCILE_FAILED action=take-item mail_id={mail_id}: item still present"
                ))
            }
        }
    }
}

fn poc05_perform_mail_action(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    mailbox_guid: u64,
    action: Poc05MailAction,
    before: &[Poc05MailRecord],
    mutation_committed: &mut bool,
) -> Result<(), String> {
    if action == Poc05MailAction::ReadOnly {
        println!("[MAIL-ACTION] read-only mode; no mailbox mutation sent");
        println!("[POC05] MAILBOX CONTROL PASS mode=read-only");
        return Ok(());
    }

    if *mutation_committed {
        println!("[MAIL-ACTION] mutation already confirmed before reconnect; reconcile only");
        poc05_reconcile_action(action, before)?;
        println!("[POC05] MAILBOX CONTROL PASS mode=reconcile-only");
        return Ok(());
    }

    let mail_id = match action {
        Poc05MailAction::TakeMoney(id) | Poc05MailAction::TakeItem(id) => id,
        Poc05MailAction::ReadOnly => unreachable!(),
    };
    let target = before
        .iter()
        .find(|mail| mail.id == mail_id)
        .ok_or_else(|| format!("requested mail_id={mail_id} not present in current mailbox list"))?;

    let (opcode, action_name, expected_server_action) = match action {
        Poc05MailAction::TakeMoney(_) => {
            if target.money == 0 {
                return Err(format!("mail_id={mail_id} has no money to take"));
            }
            (POC05_CMSG_MAIL_TAKE_MONEY_OPCODE, "take-money", 1u32)
        }
        Poc05MailAction::TakeItem(_) => {
            if target.item == 0 || target.stack == 0 {
                return Err(format!("mail_id={mail_id} has no item to take"));
            }
            if target.cod != 0 {
                return Err(format!(
                    "mail_id={mail_id} is COD={} and POC-05 refuses COD item collection",
                    target.cod
                ));
            }
            (POC05_CMSG_MAIL_TAKE_ITEM_OPCODE, "take-item", 2u32)
        }
        Poc05MailAction::ReadOnly => unreachable!(),
    };

    let mut request = Vec::with_capacity(12);
    request.extend_from_slice(&mailbox_guid.to_le_bytes());
    request.extend_from_slice(&mail_id.to_le_bytes());
    println!(
        "[MAIL-ACTION] ARMED action={action_name} mail_id={mail_id} mailbox=0x{mailbox_guid:016X}"
    );
    write_encrypted_raw(stream, crypto.encrypter(), opcode, &request).map_err(|error| {
        format!(
            "MAIL_MUTATION_UNCERTAIN action={action_name} mail_id={mail_id} during-send: {error}"
        )
    })?;
    println!("[MAIL-ACTION] SENT action={action_name} mail_id={mail_id}");

    let mut confirmed = false;
    for index in 0..256usize {
        let (server_opcode, payload) = read_encrypted_raw(stream, crypto.decrypter()).map_err(|error| {
            format!(
                "MAIL_MUTATION_UNCERTAIN action={action_name} mail_id={mail_id} after-send: {error}"
            )
        })?;

        if server_opcode == POC05_SMSG_SEND_MAIL_RESULT_OPCODE {
            if payload.len() < 12 {
                return Err(format!(
                    "MAIL_MUTATION_UNCERTAIN action={action_name} mail_id={mail_id}: SMSG_SEND_MAIL_RESULT payload too short {}",
                    payload.len()
                ));
            }
            let response_mail_id = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            let response_action = u32::from_le_bytes(payload[4..8].try_into().unwrap());
            let response_result = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            println!(
                "[MAIL-ACTION] result mail_id={response_mail_id} action={response_action} result={response_result} payload={}",
                payload.len()
            );
            if response_mail_id != mail_id || response_action != expected_server_action {
                println!(
                    "[MAIL-ACTION-DIAG] unrelated result while waiting expected_mail={mail_id} expected_action={expected_server_action}"
                );
                continue;
            }
            if response_result != 0 {
                return Err(format!(
                    "MAIL_MUTATION_CONFIRMED_FAILURE action={action_name} mail_id={mail_id} server_result={response_result}"
                ));
            }
            println!("[MAIL-ACTION] SERVER PASS action={action_name} mail_id={mail_id}");
            *mutation_committed = true;
            confirmed = true;
            break;
        }

        if index < 12 {
            println!(
                "[MAIL-ACTION-DIAG] wait rx[{index}] opcode=0x{server_opcode:04X} payload={}",
                payload.len()
            );
        }
    }

    if !confirmed {
        return Err(format!(
            "MAIL_MUTATION_UNCERTAIN action={action_name} mail_id={mail_id}: no SMSG_SEND_MAIL_RESULT within 256 packets"
        ));
    }

    let after = poc05_request_mail_list(stream, crypto, mailbox_guid).map_err(|error| {
        format!(
            "MAIL_MUTATION_CONFIRMED_POSTCHECK_FAILED action={action_name} mail_id={mail_id}: {error}"
        )
    })?;
    poc05_reconcile_action(action, &after)?;
    println!("[POC05] MAILBOX CONTROL PASS mode={action_name}");
    Ok(())
}

pub fn login_poc05(
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
        return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string());
    }

    let action = poc05_mail_action_from_env()?;
    println!("[POC05] requested mailbox action={action:?} committed_before_session={mutation_committed}");

    let (auctioneer_guid, mailbox_guid) =
        discover_poc05_context(stream, &mut crypto, player_guid)?;
    probe_read_only_auction_house(stream, &mut crypto, auctioneer_guid)?;
    let mails = poc05_request_mail_list(stream, &mut crypto, mailbox_guid)?;
    poc05_perform_mail_action(
        stream,
        &mut crypto,
        mailbox_guid,
        action,
        &mails,
        mutation_committed,
    )?;
    maintain_world_session(stream, &mut crypto, soak_seconds)?;
    println!("[POC05] POC-05 INVENTORY/GOLD/MAIL CONTROL PASS");
    Ok(())
}
