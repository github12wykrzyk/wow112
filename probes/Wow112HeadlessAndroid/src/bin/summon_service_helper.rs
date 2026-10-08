include!("../world.rs");

use std::collections::HashMap;
use std::fs;
use std::net::ToSocketAddrs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use wow112_headless_android_probe::summon_group_accept_worker::GroupAcceptWorker;
use wow112_headless_android_probe::summon_portal_worker::PortalWorker;
use wow112_headless_android_probe::summon_service_core::{RequestPhase, ServiceSnapshot};

#[path = "../wire_build.rs"]
mod wire_build;
#[path = "../auth.rs"]
mod auth;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const LOGIN_WATCHDOG_MS: u64 = 3000;
const CMSG_GROUP_ACCEPT_OPCODE: u32 = 0x0072;
const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
const SUMMONING_PORTAL_ENTRY: i32 = 36727;
const GAMEOBJECT_TYPE_RITUAL: i32 = 18;
const DEFAULT_MAX_RANGE: f32 = 5.8;
const DEFAULT_CLICK_SETTLE_MS: u64 = 150;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn service_root() -> PathBuf {
    env::var("WOW112_SUMMON_SERVICE_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("summon_service_v1"))
}

fn configured_inviter() -> Result<String, String> {
    env::var("WOW112_TELE_AUTO_ACCEPT_FROM")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "missing WOW112_TELE_AUTO_ACCEPT_FROM".to_string())
}

fn max_range() -> Result<f32, String> {
    let value = env::var("WOW112_TELE06B_MAX_RANGE").unwrap_or_else(|_| DEFAULT_MAX_RANGE.to_string());
    let parsed = value
        .trim()
        .parse::<f32>()
        .map_err(|e| format!("invalid WOW112_TELE06B_MAX_RANGE={value:?}: {e}"))?;
    if !parsed.is_finite() || parsed <= 0.0 || parsed > 20.0 {
        return Err(format!("invalid WOW112_TELE06B_MAX_RANGE={value:?}; expected 0..20"));
    }
    Ok(parsed)
}

fn click_settle_ms() -> Result<u64, String> {
    let value = env::var("WOW112_TELE06B_CLICK_SETTLE_MS")
        .unwrap_or_else(|_| DEFAULT_CLICK_SETTLE_MS.to_string());
    let parsed = value
        .trim()
        .parse::<u64>()
        .map_err(|e| format!("invalid WOW112_TELE06B_CLICK_SETTLE_MS={value:?}: {e}"))?;
    if parsed > 5000 {
        return Err(format!("invalid WOW112_TELE06B_CLICK_SETTLE_MS={value:?}; expected <=5000"));
    }
    Ok(parsed)
}

fn connect_watchdog(addr: &str, label: &str) -> Result<TcpStream, String> {
    let addrs = addr
        .to_socket_addrs()
        .map_err(|e| format!("{label} resolve {addr} failed: {e}"))?
        .collect::<Vec<_>>();
    let mut last = None;
    for socket in addrs {
        match TcpStream::connect_timeout(&socket, Duration::from_millis(LOGIN_WATCHDOG_MS)) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = Some(error.to_string()),
        }
    }
    Err(format!(
        "{label} connect failed addr={addr} last={}",
        last.unwrap_or_else(|| "no address".to_string())
    ))
}

fn distance3(a: [f32; 3], b: [f32; 3]) -> f32 {
    let dx = a[0] - b[0];
    let dy = a[1] - b[1];
    let dz = a[2] - b[2];
    (dx * dx + dy * dy + dz * dz).sqrt()
}

fn mask_is_summoning_portal(mask: &UpdateMask) -> bool {
    match mask {
        UpdateMask::GameObject(go) => {
            go.object_entry()
                .map(|value| value == SUMMONING_PORTAL_ENTRY)
                .unwrap_or(false)
                || go
                    .gameobject_type_id()
                    .map(|value| value == GAMEOBJECT_TYPE_RITUAL)
                    .unwrap_or(false)
        }
        _ => false,
    }
}

fn portal_position(object: &Object) -> Option<[f32; 3]> {
    let movement = match object {
        Object::CreateObject { movement2, .. } | Object::CreateObject2 { movement2, .. } => movement2,
        _ => return None,
    };
    let living = movement.update_flag.get_living()?;
    match living {
        wow_world_messages::vanilla::MovementBlock_UpdateFlag_Living::HasPosition { position, .. } => {
            Some([position.x, position.y, position.z])
        }
        wow_world_messages::vanilla::MovementBlock_UpdateFlag_Living::Living { living_position, .. } => {
            Some([living_position.x, living_position.y, living_position.z])
        }
    }
}

fn collect_portals(
    objects: &[Object],
    portals: &mut HashMap<u64, [f32; 3]>,
    seen: &mut HashSet<u64>,
) {
    for object in objects {
        let guid = match object {
            Object::Values { guid1, mask1 } if mask_is_summoning_portal(mask1) => Some(guid1.guid()),
            Object::CreateObject { guid3, mask2, .. }
            | Object::CreateObject2 { guid3, mask2, .. }
                if mask_is_summoning_portal(mask2) => Some(guid3.guid()),
            _ => None,
        };
        let Some(guid) = guid else { continue; };
        if let Some(position) = portal_position(object) {
            portals.insert(guid, position);
        }
        if seen.insert(guid) {
            println!("[SUMMON-HELPER] portal_observed guid=0x{guid:016X}");
        }
    }
}

fn inspect_portals(
    opcode: u16,
    payload: &[u8],
    portals: &mut HashMap<u64, [f32; 3]>,
    seen: &mut HashSet<u64>,
) {
    if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
        return;
    }
    match parse_raw_server_message(opcode, payload) {
        Ok(ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message)) => {
            collect_portals(&message.objects, portals, seen)
        }
        Ok(ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message)) => {
            collect_portals(&message.objects, portals, seen)
        }
        _ => {}
    }
}

fn active_phase(root: &PathBuf) -> Result<Option<RequestPhase>, String> {
    let path = root.join("summon_service_state.json");
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("read service state {} failed: {e}", path.display()))?;
    let snapshot: ServiceSnapshot = serde_json::from_str(&raw)
        .map_err(|e| format!("parse service state {} failed: {e}", path.display()))?;
    let active = snapshot
        .requests
        .iter()
        .filter(|record| matches!(record.phase, RequestPhase::Inviting | RequestPhase::RitualCommitted | RequestPhase::PortalCommitted | RequestPhase::AwaitingPayment))
        .collect::<Vec<_>>();
    if active.len() > 1 {
        return Err(format!("helper refuses ambiguous active requests count={}", active.len()));
    }
    Ok(active.first().map(|record| record.phase))
}

fn login_and_run(
    stream: &mut TcpStream,
    session_key: [u8; SESSION_KEY_LENGTH as usize],
    server_id: u8,
    username: &str,
    character_name: Option<&str>,
    root: PathBuf,
    inviter: String,
) -> Result<(), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .map_err(|e| format!("set world read timeout failed: {e}"))?;
    let challenge = expect_server_message::<SMSG_AUTH_CHALLENGE, _>(&mut *stream)
        .map_err(|e| format!("read world auth challenge failed: {e:?}"))?;
    let seed = ProofSeed::new();
    let seed_value = seed.seed();
    let normalized_username = NormalizedString::new(username)
        .map_err(|e| format!("invalid account name: {e:?}"))?;
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
        .map_err(|e| format!("encode world auth failed: {e:?}"))?;
    stream
        .write_all(&auth_wire)
        .map_err(|e| format!("write world auth failed: {e:?}"))?;
    world_diag_peek(stream, "auth-response-raw", Duration::from_millis(1500));
    skip_octowow_addon_info(stream, crypto.decrypter())?;
    let mut auth_ok = false;
    for _ in 0..16usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
            .map_err(|e| format!("read auth response failed: {e:?}"))?;
        if let ServerOpcodeMessage::SMSG_AUTH_RESPONSE(response) = opcode {
            auth_ok = matches!(*response, SMSG_AUTH_RESPONSE::AuthOk { .. });
            break;
        }
    }
    if !auth_ok {
        return Err("world auth did not return AuthOk".to_string());
    }

    CMSG_CHAR_ENUM {}
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write char enum failed: {e:?}"))?;
    let characters = expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter())
        .map_err(|e| format!("read char enum failed: {e:?}"))?;
    let selected = match character_name {
        Some(wanted) => characters
            .characters
            .iter()
            .find(|character| character.name.eq_ignore_ascii_case(wanted))
            .ok_or_else(|| format!("character not found: {wanted}"))?,
        None => characters.characters.first().ok_or_else(|| "character list empty".to_string())?,
    };
    CMSG_PLAYER_LOGIN { guid: selected.guid }
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write player login failed: {e:?}"))?;
    let mut local_position = None::<[f32; 3]>;
    for _ in 0..256usize {
        let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
            .map_err(|e| format!("read before login verify failed: {e:?}"))?;
        if let ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(verify) = opcode {
            local_position = Some([verify.position.x, verify.position.y, verify.position.z]);
            break;
        }
    }
    let local_position = local_position.ok_or_else(|| "SMSG_LOGIN_VERIFY_WORLD not received".to_string())?;

    let accept_worker = GroupAcceptWorker::open(&root)?;
    let portal_worker = PortalWorker::open_for_actor(&root, &selected.name)?;
    let max_range = max_range()?;
    let settle_ms = click_settle_ms()?;
    let mut portals = HashMap::<u64, [f32; 3]>::new();
    let mut seen_portals = HashSet::<u64>::new();
    let mut last_ping = Instant::now();
    let mut ping_sequence = 1u32;
    let mut awaiting_pong: Option<(u32, Instant)> = None;
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|e| format!("set helper read timeout failed: {e}"))?;

    println!(
        "[SUMMON-HELPER] READY character={} inviter={} root={} range={} retry_policy=no_replay",
        selected.name,
        inviter,
        root.display(),
        max_range
    );

    loop {
        if let Some((sequence, sent_at)) = awaiting_pong {
            if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                return Err(format!("world keepalive pong timeout sequence={sequence}"));
            }
        }
        if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS) && awaiting_pong.is_none() {
            let mut payload = Vec::with_capacity(8);
            payload.extend_from_slice(&ping_sequence.to_le_bytes());
            payload.extend_from_slice(&0u32.to_le_bytes());
            write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
            awaiting_pong = Some((ping_sequence, Instant::now()));
            ping_sequence = ping_sequence.wrapping_add(1);
            last_ping = Instant::now();
        }

        match read_encrypted_raw(stream, crypto.decrypter()) {
            Ok((opcode, payload)) => {
                if opcode == SMSG_PONG_OPCODE {
                    if payload.len() >= 4 {
                        let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                        if awaiting_pong.map(|value| value.0) == Some(sequence) {
                            awaiting_pong = None;
                        }
                    }
                    continue;
                }

                if opcode == SMSG_GROUP_INVITE_OPCODE {
                    if let Ok(ServerOpcodeMessage::SMSG_GROUP_INVITE(invite)) = parse_raw_server_message(opcode, &payload) {
                        if invite.name.eq_ignore_ascii_case(&inviter) {
                            match accept_worker.execute_accept_once(&invite.name, now_ms(), || {
                                write_encrypted_raw(
                                    stream,
                                    crypto.encrypter(),
                                    CMSG_GROUP_ACCEPT_OPCODE,
                                    &[],
                                )
                            })? {
                                Some(claim) => println!(
                                    "[SUMMON-HELPER] group_accept request={} inviter={} operation={} result=sent_once",
                                    claim.request_id, claim.inviter, claim.operation_id
                                ),
                                None => println!("[SUMMON-HELPER] group_invite ignored=no_active_inviting_request"),
                            }
                        }
                    }
                    continue;
                }

                inspect_portals(opcode, &payload, &mut portals, &mut seen_portals);
                if matches!(
            active_phase(&root)?,
            Some(RequestPhase::RitualCommitted | RequestPhase::PortalCommitted)
        ) {
                    let candidates = portals.iter().map(|(guid, pos)| (*guid, *pos)).collect::<Vec<_>>();
                    for (guid, position) in candidates {
                        let distance = distance3(local_position, position);
                        if distance > max_range {
                            println!(
                                "[SUMMON-HELPER] portal_out_of_range guid=0x{guid:016X} distance={distance:.3} max={max_range:.3} action=no_send"
                            );
                            continue;
                        }
                        if settle_ms != 0 {
                            std::thread::sleep(Duration::from_millis(settle_ms));
                        }
                        if let Some(claim) = portal_worker.execute_portal_use_once(guid, now_ms(), |portal_guid| {
                            write_encrypted_raw(
                                stream,
                                crypto.encrypter(),
                                CMSG_GAMEOBJ_USE_OPCODE,
                                &portal_guid.to_le_bytes(),
                            )
                        })? {
                            println!(
                                "[SUMMON-HELPER] portal_use request={} guid=0x{:016X} operation={} result=sent_once",
                                claim.request_id, claim.portal_guid, claim.operation_id
                            );
                            break;
                        }
                    }
                }
            }
            Err(error) if error.contains("TimedOut") || error.contains("timed out") || error.contains("WouldBlock") => {}
            Err(error) => return Err(error),
        }
    }
}

fn env_u32(name: &str, default_value: u32) -> Result<u32, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u32>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn env_u64(name: &str, default_value: u64) -> Result<u64, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u64>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn helper_retry_allowed(error: &str) -> bool {
    if error.contains("retry_allowed=false")
        || error.contains("blocked by unresolved mutation")
        || error.contains("MUTATION_UNCERTAIN")
        || error.contains("uncertain mutation")
    {
        return false;
    }
    [
        "ConnectionReset",
        "Connection reset by peer",
        "BrokenPipe",
        "UnexpectedEof",
        "TimedOut",
        "timed out",
        "WouldBlock",
        "ConnectionRefused",
        "connection refused",
        "connect failed",
        "world socket closed",
        "world keepalive pong timeout",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn run_once(
    auth_addr: &str,
    realm_index: usize,
    username: &str,
    password: &str,
    character_name: Option<&str>,
    root: &PathBuf,
    inviter: &str,
) -> Result<(), String> {
    let mut auth_stream = connect_watchdog(auth_addr, "AUTH")?;
    let timeout = Some(Duration::from_millis(LOGIN_WATCHDOG_MS));
    auth_stream.set_read_timeout(timeout).map_err(|e| e.to_string())?;
    auth_stream.set_write_timeout(timeout).map_err(|e| e.to_string())?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, username, password)?;
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    let mut world_stream = connect_watchdog(&world_addr, "WORLD")?;
    world_stream.set_read_timeout(timeout).map_err(|e| e.to_string())?;
    world_stream.set_write_timeout(timeout).map_err(|e| e.to_string())?;
    login_and_run(
        &mut world_stream,
        session_key,
        realm.realm_id,
        username,
        character_name,
        root.clone(),
        inviter.to_string(),
    )
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password = env::var("WOW112_PASSWORD")
        .map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR")
        .unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);
    let character_name = env::var("WOW112_CHARACTER").ok();
    let root = service_root();
    fs::create_dir_all(&root)
        .map_err(|e| format!("create service root {} failed: {e}", root.display()))?;
    let inviter = configured_inviter()?;
    let reconnect_limit = env_u32("WOW112_RECONNECT_LIMIT", 60)?.max(1);
    let reconnect_delay_ms = env_u64("WOW112_RECONNECT_DELAY_MS", 1000)?;

    for attempt in 1..=reconnect_limit {
        println!("[SUMMON-HELPER][RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        match run_once(
            &auth_addr,
            realm_index,
            &username,
            &password,
            character_name.as_deref(),
            &root,
            &inviter,
        ) {
            Ok(()) => return Ok(()),
            Err(error) if helper_retry_allowed(&error) && attempt < reconnect_limit => {
                println!("[SUMMON-HELPER][RESILIENCE] transient failure={error}; reconnecting=true");
                if reconnect_delay_ms != 0 {
                    std::thread::sleep(Duration::from_millis(reconnect_delay_ms));
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(format!("summon helper reconnect limit exhausted after {reconnect_limit} attempts"))
}

fn main() {
    if let Err(error) = run() {
        eprintln!("SUMMON_SERVICE_HELPER_FAIL {error}");
        std::process::exit(2);
    }
}

#[cfg(test)]
mod reconnect_tests {
    use super::helper_retry_allowed;

    #[test]
    fn transient_network_errors_retry() {
        assert!(helper_retry_allowed("ConnectionReset while reading world"));
        assert!(helper_retry_allowed("WORLD connect failed addr=x"));
        assert!(helper_retry_allowed("world keepalive pong timeout sequence=3"));
    }

    #[test]
    fn uncertain_mutations_never_retry() {
        assert!(!helper_retry_allowed("portal use transport uncertain; retry_allowed=false"));
        assert!(!helper_retry_allowed("portal worker blocked by unresolved mutation"));
        assert!(!helper_retry_allowed("SUMMON_MUTATION_UNCERTAIN"));
    }
}
