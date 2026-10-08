use std::env;
use std::fs;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

#[path = "../auth.rs"]
mod auth;
#[path = "../tele_party_observer.rs"]
mod tele_party_observer;
#[path = "../wire_build.rs"]
mod wire_build;

use wire_build::OCTOWOW_WIRE_BUILD;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const DEFAULT_RECONNECT_LIMIT: u32 = 60;
const LOGIN_WATCHDOG_MS: u64 = 3000;

fn connect_with_login_watchdog(addr: &str, label: &str) -> Result<TcpStream, String> {
    let addrs = addr
        .to_socket_addrs()
        .map_err(|e| format!("{label} resolve {addr} failed: {e}"))?
        .collect::<Vec<_>>();
    if addrs.is_empty() {
        return Err(format!("{label} resolve {addr} returned no addresses"));
    }
    let mut last_error = None;
    for socket in addrs {
        match TcpStream::connect_timeout(&socket, Duration::from_millis(LOGIN_WATCHDOG_MS)) {
            Ok(stream) => {
                println!("[LOGIN-WATCHDOG] {label} connected addr={socket} timeout_ms={LOGIN_WATCHDOG_MS}");
                return Ok(stream);
            }
            Err(error) => {
                last_error = Some(format!("{error}"));
            }
        }
    }
    Err(format!(
        "TimedOut login watchdog label={label} addr={addr} timeout_ms={LOGIN_WATCHDOG_MS} last={}",
        last_error.unwrap_or_else(|| "unknown".to_string())
    ))
}

fn arm_login_watchdog(stream: &TcpStream, label: &str) -> Result<(), String> {
    let timeout = Some(Duration::from_millis(LOGIN_WATCHDOG_MS));
    stream
        .set_read_timeout(timeout)
        .map_err(|e| format!("{label} set login read watchdog failed: {e}"))?;
    stream
        .set_write_timeout(timeout)
        .map_err(|e| format!("{label} set login write watchdog failed: {e}"))?;
    println!("[LOGIN-WATCHDOG] {label} io_timeout_ms={LOGIN_WATCHDOG_MS}");
    Ok(())
}

fn publish_runner_state(state: &str, detail: &str) {
    let Ok(path) = env::var("WOW112_RUNNER_STATE_FILE") else {
        return;
    };
    if path.trim().is_empty() {
        return;
    }
    let session = env::var("WOW112_RUNNER_SESSION_ATTEMPT").unwrap_or_else(|_| "0".to_string());
    let safe_detail = detail.replace('\r', " ").replace('\n', " ");
    let body = format!("state={state}\nsession={session}\ndetail={safe_detail}\n");
    let _ = fs::write(path, body);
}

mod agent {
    include!("../world_tele.rs");

    use super::*;
    include!("../tele10_payer_roster_runtime.rs");
    include!("../tele10_payer_driver_runtime.rs");

    const CMSG_GROUP_DISBAND_OPCODE: u32 = 0x007B;
    const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
    const CMSG_GROUP_ACCEPT_OPCODE: u32 = 0x0072;

    static RESET_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static ACCEPT_ATTEMPTED: AtomicBool = AtomicBool::new(false);

    const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
    const SMSG_SUMMON_REQUEST_OPCODE: u16 = 0x02AB;
    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;
    const MSG_MOVE_TELEPORT_ACK_OPCODE: u32 = 0x00C7;
    const SMSG_NEW_WORLD_OPCODE: u16 = 0x003E;
    const MSG_MOVE_WORLDPORT_ACK_OPCODE: u32 = 0x00DC;
    const SUMMONING_PORTAL_ENTRY_TELE06B: i32 = 36727;
    const GAMEOBJECT_TYPE_RITUAL_TELE06B: i32 = 18;

    static PORTAL_USE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static PORTAL_USE_SUCCEEDED: AtomicBool = AtomicBool::new(false);
    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);
    static SUMMON_RESPONSE_SENT: AtomicBool = AtomicBool::new(false);
    static TELEPORT_ACK_SENT: AtomicBool = AtomicBool::new(false);
    static WORLDPORT_ACK_SENT: AtomicBool = AtomicBool::new(false);
    static TELE06C_MOVE_ATTEMPTED: AtomicBool = AtomicBool::new(false);

    const TELE06B_DEFAULT_MAX_RANGE: f32 = 5.8;
    const TELE06B_DEFAULT_CLICK_SETTLE_MS: u64 = 150;
    static TELE06B_LOCAL_POSITION: std::sync::Mutex<Option<[f32; 3]>> = std::sync::Mutex::new(None);
    static TELE06B_LAST_PORTAL_POSITION: std::sync::Mutex<Option<(u64, [f32; 3])>> =
        std::sync::Mutex::new(None);

    fn tele06b_set_local_position(x: f32, y: f32, z: f32) {
        if let Ok(mut slot) = TELE06B_LOCAL_POSITION.lock() {
            *slot = Some([x, y, z]);
        }
        println!("[TELE-06B-RANGE] local_position x={x:.5} y={y:.5} z={z:.5}");
    }

    fn tele06b_local_position() -> Option<[f32; 3]> {
        TELE06B_LOCAL_POSITION.lock().ok().and_then(|slot| *slot)
    }

    fn tele06b_portal_position_from_object(object: &Object) -> Option<[f32; 3]> {
        let movement = match object {
            Object::CreateObject { movement2, .. } | Object::CreateObject2 { movement2, .. } => {
                movement2
            }
            _ => return None,
        };
        let living = movement.update_flag.get_living()?;
        match living {
            wow_world_messages::vanilla::MovementBlock_UpdateFlag_Living::HasPosition {
                position,
                ..
            } => Some([position.x, position.y, position.z]),
            wow_world_messages::vanilla::MovementBlock_UpdateFlag_Living::Living {
                living_position,
                ..
            } => Some([living_position.x, living_position.y, living_position.z]),
        }
    }

    fn tele06b_record_portal_position(object: &Object, guid: u64) {
        let Some(position) = tele06b_portal_position_from_object(object) else {
            return;
        };
        if let Ok(mut slot) = TELE06B_LAST_PORTAL_POSITION.lock() {
            *slot = Some((guid, position));
        }
        println!(
            "[TELE-06B-RANGE] portal_position guid=0x{guid:016X} x={:.5} y={:.5} z={:.5}",
            position[0], position[1], position[2]
        );
    }

    fn tele06b_portal_position(guid: u64) -> Option<[f32; 3]> {
        TELE06B_LAST_PORTAL_POSITION
            .lock()
            .ok()
            .and_then(|slot| slot.as_ref().copied())
            .and_then(|(seen_guid, position)| {
                if seen_guid == guid {
                    Some(position)
                } else {
                    None
                }
            })
    }

    fn tele06b_distance3(a: [f32; 3], b: [f32; 3]) -> f32 {
        let dx = a[0] - b[0];
        let dy = a[1] - b[1];
        let dz = a[2] - b[2];
        (dx * dx + dy * dy + dz * dz).sqrt()
    }

    fn tele06b_max_range() -> Result<f32, String> {
        match std::env::var("WOW112_TELE06B_MAX_RANGE") {
            Ok(value) => {
                let parsed = value
                    .trim()
                    .parse::<f32>()
                    .map_err(|e| format!("invalid WOW112_TELE06B_MAX_RANGE={value:?}: {e}"))?;
                if !parsed.is_finite() || parsed <= 0.0 || parsed > 20.0 {
                    return Err(format!(
                        "invalid WOW112_TELE06B_MAX_RANGE={value:?}; expected 0..20"
                    ));
                }
                Ok(parsed)
            }
            Err(_) => Ok(TELE06B_DEFAULT_MAX_RANGE),
        }
    }

    fn tele06b_click_settle_ms() -> Result<u64, String> {
        match std::env::var("WOW112_TELE06B_CLICK_SETTLE_MS") {
            Ok(value) => {
                let parsed = value.trim().parse::<u64>().map_err(|e| {
                    format!("invalid WOW112_TELE06B_CLICK_SETTLE_MS={value:?}: {e}")
                })?;
                if parsed > 5000 {
                    return Err(format!(
                        "invalid WOW112_TELE06B_CLICK_SETTLE_MS={value:?}; expected <=5000"
                    ));
                }
                Ok(parsed)
            }
            Err(_) => Ok(TELE06B_DEFAULT_CLICK_SETTLE_MS),
        }
    }

    const TELE06C_HEARTBEAT_OPCODE: u32 = 0x00EE;
    const TELE06C_TARGET_RANGE: f32 = 4.8;
    const TELE06C_MAX_RECOVERY_MOVE: f32 = 3.0;
    const TELE06C_MAX_STEP: f32 = 1.25;
    const TELE06C_STEP_DELAY_MS: u64 = 120;
    const TELE06C_MAX_VERTICAL_DELTA: f32 = 2.0;

    fn tele06c_plan_steps(local: [f32; 3], portal: [f32; 3]) -> Result<Vec<[f32; 3]>, String> {
        let distance = tele06b_distance3(local, portal);
        if distance <= TELE06C_TARGET_RANGE {
            return Ok(Vec::new());
        }
        let move_needed = distance - TELE06C_TARGET_RANGE;
        if move_needed > TELE06C_MAX_RECOVERY_MOVE {
            return Err(format!("AUTO_POSITION_LIMIT move_needed={move_needed:.3} max={TELE06C_MAX_RECOVERY_MOVE:.3}"));
        }
        let vertical_delta = (portal[2] - local[2]).abs();
        if vertical_delta > TELE06C_MAX_VERTICAL_DELTA {
            return Err(format!("AUTO_POSITION_VERTICAL_LIMIT dz={vertical_delta:.3} max={TELE06C_MAX_VERTICAL_DELTA:.3}"));
        }
        let step_count = (move_needed / TELE06C_MAX_STEP).ceil().max(1.0) as usize;
        let mut steps = Vec::with_capacity(step_count);
        for index in 1..=step_count {
            let moved = move_needed * (index as f32 / step_count as f32);
            let ratio = moved / distance;
            steps.push([
                local[0] + (portal[0] - local[0]) * ratio,
                local[1] + (portal[1] - local[1]) * ratio,
                local[2] + (portal[2] - local[2]) * ratio,
            ]);
        }
        Ok(steps)
    }

    fn tele06c_movement_payload(position: [f32; 3], orientation: f32, timestamp: u32) -> Vec<u8> {
        let mut payload = Vec::with_capacity(28);
        payload.extend_from_slice(&0u32.to_le_bytes()); // MovementFlags::NONE
        payload.extend_from_slice(&timestamp.to_le_bytes());
        payload.extend_from_slice(&position[0].to_le_bytes());
        payload.extend_from_slice(&position[1].to_le_bytes());
        payload.extend_from_slice(&position[2].to_le_bytes());
        payload.extend_from_slice(&orientation.to_le_bytes());
        payload.extend_from_slice(&0f32.to_le_bytes()); // fall_time
        payload
    }

    fn tele06c_movement_timestamp() -> u32 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u32
    }

    fn tele06c_auto_position(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        guid: u64,
        local: [f32; 3],
        portal: [f32; 3],
    ) -> Result<[f32; 3], String> {
        let steps = match tele06c_plan_steps(local, portal) {
            Ok(value) => value,
            Err(error) => {
                publish_runner_state(
                    "FAIL_AUTO_POSITION_LIMIT",
                    &format!("guid=0x{guid:016X} {error}; no movement sent"),
                );
                println!("[TELE-06C-MOVE] FAIL guid=0x{guid:016X} reason={error} action=NO_SEND");
                return Err(format!("TELE06C_AUTO_POSITION_LIMIT {error}"));
            }
        };
        if steps.is_empty() {
            return Ok(local);
        }
        if TELE06C_MOVE_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            publish_runner_state(
                "FAIL_AUTO_POSITION_ALREADY_ATTEMPTED",
                "movement guard already committed; retry disabled",
            );
            return Err("TELE06C_AUTO_POSITION_ALREADY_ATTEMPTED retry_allowed=false".to_string());
        }

        let orientation = (portal[1] - local[1]).atan2(portal[0] - local[0]);
        publish_runner_state(
            "AUTO_POSITIONING",
            &format!("guid=0x{guid:016X} steps={} from_distance={:.3} target_range={TELE06C_TARGET_RANGE:.3}", steps.len(), tele06b_distance3(local, portal)),
        );
        println!(
            "[TELE-06C-MOVE] START guid=0x{guid:016X} steps={} from_distance={:.3} target_range={TELE06C_TARGET_RANGE:.3} max_total={TELE06C_MAX_RECOVERY_MOVE:.3} max_step={TELE06C_MAX_STEP:.3}",
            steps.len(), tele06b_distance3(local, portal)
        );

        let mut last = local;
        for (index, position) in steps.iter().copied().enumerate() {
            let payload =
                tele06c_movement_payload(position, orientation, tele06c_movement_timestamp());
            if let Err(error) = write_encrypted_raw(
                stream,
                crypto.encrypter(),
                TELE06C_HEARTBEAT_OPCODE,
                &payload,
            ) {
                publish_runner_state(
                    "FAIL_AUTO_POSITION_UNCERTAIN",
                    &format!(
                        "guid=0x{guid:016X} step={}/{} movement write uncertain; retry disabled",
                        index + 1,
                        steps.len()
                    ),
                );
                return Err(format!(
                    "TELE06C_MOVE_MUTATION_UNCERTAIN guid=0x{guid:016X} step={}/{} retry_allowed=false cause={error}",
                    index + 1,
                    steps.len()
                ));
            }
            let remaining = tele06b_distance3(position, portal);
            println!(
                "[TELE-06C-MOVE-TX] opcode=0x00EE guid=0x{guid:016X} step={}/{} x={:.5} y={:.5} z={:.5} remaining={remaining:.3} result=sent server_acceptance=unconfirmed retry_allowed=false",
                index + 1,
                steps.len(),
                position[0], position[1], position[2]
            );
            last = position;
            if index + 1 < steps.len() {
                thread::sleep(Duration::from_millis(TELE06C_STEP_DELAY_MS));
            }
        }
        tele06b_set_local_position(last[0], last[1], last[2]);
        publish_runner_state(
            "AUTO_POSITION_SENT",
            &format!("guid=0x{guid:016X} steps={} resulting_cached_distance={:.3}; server acceptance unconfirmed", steps.len(), tele06b_distance3(last, portal)),
        );
        println!(
            "[TELE-06C-MOVE] SENT guid=0x{guid:016X} steps={} resulting_cached_distance={:.3} server_acceptance=unconfirmed",
            steps.len(), tele06b_distance3(last, portal)
        );
        Ok(last)
    }

    #[cfg(test)]
    mod tele06c_v16_tests {
        use super::*;

        #[test]
        fn failed_live_geometry_is_recoverable_in_two_short_steps() {
            let local = [6720.52, -4666.82, 721.00574];
            let portal = [6726.2266, -4670.2344, 720.8829];
            let steps = tele06c_plan_steps(local, portal).expect("recoverable geometry");
            assert_eq!(steps.len(), 2);
            let mut previous = local;
            for step in &steps {
                assert!(tele06b_distance3(previous, *step) <= TELE06C_MAX_STEP + 0.001);
                previous = *step;
            }
            assert!(
                (tele06b_distance3(*steps.last().unwrap(), portal) - TELE06C_TARGET_RANGE).abs()
                    < 0.01
            );
        }

        #[test]
        fn already_close_requires_no_movement() {
            let local = [6720.52, -4666.82, 721.00574];
            let portal = [6720.682, -4666.9277, 721.00574];
            assert!(tele06c_plan_steps(local, portal).unwrap().is_empty());
        }

        #[test]
        fn far_or_vertical_recovery_fails_closed() {
            assert!(tele06c_plan_steps([0.0, 0.0, 0.0], [20.0, 0.0, 0.0]).is_err());
            assert!(tele06c_plan_steps([0.0, 0.0, 0.0], [6.0, 0.0, 3.0]).is_err());
        }

        #[test]
        fn heartbeat_payload_matches_vanilla_movementinfo_layout() {
            let p = tele06c_movement_payload([1.25, -2.5, 3.75], 1.5, 0x11223344);
            assert_eq!(p.len(), 28);
            assert_eq!(u32::from_le_bytes(p[0..4].try_into().unwrap()), 0);
            assert_eq!(u32::from_le_bytes(p[4..8].try_into().unwrap()), 0x11223344);
            assert!((f32::from_le_bytes(p[8..12].try_into().unwrap()) - 1.25).abs() < f32::EPSILON);
            assert!((f32::from_le_bytes(p[12..16].try_into().unwrap()) + 2.5).abs() < f32::EPSILON);
            assert!(
                (f32::from_le_bytes(p[16..20].try_into().unwrap()) - 3.75).abs() < f32::EPSILON
            );
            assert!((f32::from_le_bytes(p[20..24].try_into().unwrap()) - 1.5).abs() < f32::EPSILON);
            assert_eq!(f32::from_le_bytes(p[24..28].try_into().unwrap()), 0.0);
        }
    }

    #[cfg(test)]
    mod tele06b_v15_tests {
        use super::*;

        #[test]
        fn distance_matches_failed_and_pass_live_geometry() {
            let fail = tele06b_distance3(
                [6720.52, -4666.82, 721.00574],
                [6726.2266, -4670.2344, 720.8829],
            );
            let pass = tele06b_distance3(
                [6720.52, -4666.82, 721.00574],
                [6720.682, -4666.9277, 721.00574],
            );
            assert!((fail - 6.651).abs() < 0.02, "fail distance={fail}");
            assert!((pass - 0.195).abs() < 0.02, "pass distance={pass}");
            assert!(fail > TELE06B_DEFAULT_MAX_RANGE);
            assert!(pass < TELE06B_DEFAULT_MAX_RANGE);
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Tele06bRole {
        Observer,
        Customer,
        Clicker,
    }

    fn configured_tele06b_role() -> Result<Tele06bRole, String> {
        let value = std::env::var("WOW112_TELE06B_ROLE")
            .unwrap_or_else(|_| "observer".to_string())
            .trim()
            .to_ascii_lowercase();
        match value.as_str() {
            "" | "observer" => Ok(Tele06bRole::Observer),
            "customer" => Ok(Tele06bRole::Customer),
            "clicker" => Ok(Tele06bRole::Clicker),
            other => Err(format!(
                "invalid WOW112_TELE06B_ROLE={other:?}; expected observer/customer/clicker"
            )),
        }
    }

    fn tele06b_mask_is_summoning_portal(mask: &UpdateMask) -> bool {
        match mask {
            UpdateMask::GameObject(go) => {
                let entry = go
                    .object_entry()
                    .map(|value| value == SUMMONING_PORTAL_ENTRY_TELE06B)
                    .unwrap_or(false);
                let ritual = go
                    .gameobject_type_id()
                    .map(|value| value == GAMEOBJECT_TYPE_RITUAL_TELE06B)
                    .unwrap_or(false);
                entry || ritual
            }
            _ => false,
        }
    }

    fn tele06b_collect_portals(objects: &[Object], portals: &mut HashSet<u64>) {
        for object in objects {
            let guid = match object {
                Object::Values { guid1, mask1 } if tele06b_mask_is_summoning_portal(mask1) => {
                    Some(guid1.guid())
                }
                Object::CreateObject { guid3, mask2, .. }
                | Object::CreateObject2 { guid3, mask2, .. }
                    if tele06b_mask_is_summoning_portal(mask2) =>
                {
                    Some(guid3.guid())
                }
                _ => None,
            };
            if let Some(guid) = guid {
                tele06b_record_portal_position(object, guid);
                if portals.insert(guid) {
                    println!(
                        "[TELE-06B-PORTAL] observed valid summoning portal guid=0x{guid:016X}"
                    );
                    println!(
                        "[TELE-06B-PORTAL-OBJECT] {}",
                        tele_trace::truncate_chars(&format!("{object:?}"), 2400)
                    );
                    tele_trace::mark_portal_observed(guid);
                }
            }
        }
    }

    fn tele06b_inspect_portal_update(opcode: u16, payload: &[u8], portals: &mut HashSet<u64>) {
        if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
            return;
        }
        match parse_raw_server_message(opcode, payload) {
            Ok(ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message)) => {
                tele06b_collect_portals(&message.objects, portals)
            }
            Ok(ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message)) => {
                tele06b_collect_portals(&message.objects, portals)
            }
            Ok(_) => {}
            Err(error) => println!("[TELE-06B-PORTAL-DIAG] update parse skipped: {error}"),
        }
    }

    fn tele06b_post_handshake_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        soak_seconds: u64,
    ) -> Result<(), String> {
        let role = configured_tele06b_role()?;
        if role == Tele06bRole::Observer {
            return tele_sniffer_loop(stream, crypto, soak_seconds);
        }

        let previous_timeout = stream.read_timeout().ok().flatten();
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|error| format!("set TELE-06B read timeout failed: {error}"))?;
        let deadline = if soak_seconds == 0 {
            None
        } else {
            Some(Instant::now() + Duration::from_secs(soak_seconds))
        };
        let mut last_ping = Instant::now();
        let mut ping_sequence = 1u32;
        let mut awaiting_pong: Option<(u32, Instant)> = None;
        let mut portals = HashSet::<u64>::new();

        match role {
            Tele06bRole::Customer => {
                if SUMMON_REQUEST_SEEN.load(Ordering::SeqCst) {
                    publish_runner_state(
                        "SUMMON_REQUEST_SEEN",
                        "SMSG_SUMMON_REQUEST observed in prior live session; completion latched",
                    );
                } else {
                    publish_runner_state(
                        "WAIT_SUMMON_REQUEST",
                        "waiting for server SMSG_SUMMON_REQUEST opcode=0x02AB",
                    );
                }
            }
            Tele06bRole::Clicker => {
                if PORTAL_USE_ATTEMPTED.load(Ordering::SeqCst) {
                    if PORTAL_USE_SUCCEEDED.load(Ordering::SeqCst) {
                        publish_runner_state(
                            "PORTAL_USE_SENT",
                            "portal use socket write succeeded in prior live session; server acceptance not implied; retry disabled",
                        );
                    } else {
                        publish_runner_state(
                            "FAIL_PORTAL_MUTATION_UNCERTAIN",
                            "portal use was committed but socket result was uncertain; retry disabled",
                        );
                        return Err(
                            "TELE06B_PORTAL_MUTATION_UNCERTAIN retry_allowed=false".to_string()
                        );
                    }
                } else {
                    publish_runner_state(
                        "PORTAL_WAIT",
                        "waiting for summoning portal entry=36727/type=18",
                    );
                }
            }
            Tele06bRole::Observer => unreachable!(),
        }

        let role_label: &str = match role {
            Tele06bRole::Customer => "Customer",
            Tele06bRole::Clicker => "Clicker",
            Tele06bRole::Observer => "Observer",
        };

        println!(
            "[TELE-06B] post-handshake active role={role:?} portal_use=guarded_once completion=SMSG_SUMMON_REQUEST/0x02AB duration={}",
            if soak_seconds == 0 {
                "infinite".to_string()
            } else {
                format!("{soak_seconds}s")
            }
        );

        loop {
            tele_trace::poll_outcome(role_label);
            if deadline.is_some_and(|value| Instant::now() >= value) {
                let _ = stream.set_read_timeout(previous_timeout);
                return Ok(());
            }

            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("world keepalive pong timeout sequence={sequence}"));
                }
            }
            if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS)
                && awaiting_pong.is_none()
            {
                let mut payload = Vec::with_capacity(8);
                payload.extend_from_slice(&ping_sequence.to_le_bytes());
                payload.extend_from_slice(&0u32.to_le_bytes());
                write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
                println!("[TELE-06B] keepalive ping sequence={ping_sequence}");
                awaiting_pong = Some((ping_sequence, Instant::now()));
                ping_sequence = ping_sequence.wrapping_add(1);
                last_ping = Instant::now();
            }

            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if opcode == SMSG_PONG_OPCODE {
                        if payload.len() >= 4 {
                            let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            println!("[TELE-06B] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                            }
                        }
                        continue;
                    }

                    tele_trace::trace_packet(role_label, opcode, &payload);
                    if role == Tele06bRole::Customer {
                        tele10_payer_observe_packet(opcode, &payload);
                    }

                    if role == Tele06bRole::Customer && opcode == SMSG_SUMMON_REQUEST_OPCODE {
                        if payload.len() == 16 {
                            let summoner_guid =
                                u64::from_le_bytes(payload[0..8].try_into().unwrap());
                            if let Some(pay_target) = tele10_pay_target() {
                                tele10_cache_named_guid(
                                    &pay_target,
                                    summoner_guid,
                                    "summon_request",
                                );
                            }
                            let area = u32::from_le_bytes(payload[8..12].try_into().unwrap());
                            let auto_decline_ms =
                                u32::from_le_bytes(payload[12..16].try_into().unwrap());
                            SUMMON_REQUEST_SEEN.store(true, Ordering::SeqCst);
                            publish_runner_state(
                                "SUMMON_REQUEST_SEEN",
                                &format!(
                                    "SMSG_SUMMON_REQUEST opcode=0x02AB summoner_guid=0x{summoner_guid:016X} area={area} auto_decline_ms={auto_decline_ms}"
                                ),
                            );
                            println!(
                                "[TELE-06B-COMPLETE] PASS opcode=0x02AB summoner_guid=0x{summoner_guid:016X} area={area} auto_decline_ms={auto_decline_ms}"
                            );
                            if SUMMON_RESPONSE_SENT
                                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                                .is_ok()
                            {
                                publish_runner_state(
                                    "SUMMON_ACCEPT_COMMITTED",
                                    &format!("opcode=0x02AC payload=guid8 retry_allowed=false"),
                                );
                                if let Err(error) = write_encrypted_raw(
                                    stream,
                                    crypto.encrypter(),
                                    CMSG_SUMMON_RESPONSE_OPCODE,
                                    &summoner_guid.to_le_bytes(),
                                ) {
                                    publish_runner_state(
                                        "FAIL_SUMMON_ACCEPT_UNCERTAIN",
                                        "opcode=0x02AC guid8 payload socket write uncertain; retry disabled",
                                    );
                                    return Err(format!("TELE10_SUMMON_ACCEPT_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                                }
                                publish_runner_state(
                                    "WAIT_NEW_WORLD",
                                    &format!("accepted summon request summoner_guid=0x{summoner_guid:016X}; waiting SMSG_NEW_WORLD opcode=0x003E"),
                                );
                                println!("[TELE-10-ACCEPT-TX] PASS opcode=0x02AC payload=guid8 retry_allowed=false");
                            }
                        } else {
                            println!(
                                "[TELE-06B-COMPLETE-DIAG] ignored malformed SMSG_SUMMON_REQUEST bytes={} expected=16",
                                payload.len()
                            );
                        }
                        continue;
                    }

                    if role == Tele06bRole::Customer
                        && opcode as u32 == MSG_MOVE_TELEPORT_ACK_OPCODE
                        && SUMMON_RESPONSE_SENT.load(Ordering::SeqCst)
                    {
                        if payload.len() < 6 {
                            println!(
                                "[TELE-10-SAME-MAP-DIAG] malformed 0x00C7 bytes={}",
                                payload.len()
                            );
                            continue;
                        }
                        let mask = payload[0];
                        let guid_len = mask.count_ones() as usize;
                        let counter_off = 1 + guid_len;
                        if payload.len() < counter_off + 4 {
                            println!(
                                "[TELE-10-SAME-MAP-DIAG] short 0x00C7 bytes={} mask=0x{mask:02X}",
                                payload.len()
                            );
                            continue;
                        }
                        let counter = u32::from_le_bytes(
                            payload[counter_off..counter_off + 4].try_into().unwrap(),
                        );
                        if TELEPORT_ACK_SENT
                            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                        {
                            let mut ack = Vec::with_capacity(counter_off + 8);
                            ack.extend_from_slice(&payload[..counter_off]);
                            ack.extend_from_slice(&counter.to_le_bytes());
                            ack.extend_from_slice(&tele06c_movement_timestamp().to_le_bytes());
                            publish_runner_state(
                                "TELEPORT_ACK_COMMITTED",
                                &format!("same-map 0x00C7 received counter={counter}; ack retry_allowed=false"),
                            );
                            if let Err(error) = write_encrypted_raw(
                                stream,
                                crypto.encrypter(),
                                MSG_MOVE_TELEPORT_ACK_OPCODE,
                                &ack,
                            ) {
                                publish_runner_state(
                                    "FAIL_TELEPORT_ACK_UNCERTAIN",
                                    "same-map 0x00C7 ack socket write uncertain; retry disabled",
                                );
                                return Err(format!("TELE10_TELEPORT_ACK_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                            }
                            publish_runner_state(
                                "PASS_TELEPORT_COMPLETE",
                                &format!(
                                    "same-map 0x00C7 server+client counter={counter} ack_bytes={}",
                                    ack.len()
                                ),
                            );
                            println!("[TELE-10-TELEPORT] PASS path=same_map counter={counter} ack_bytes={}", ack.len());
                        }
                        tele10_customer_pay_after_teleport(stream, crypto)?;
                        continue;
                    }

                    if role == Tele06bRole::Customer && opcode == SMSG_NEW_WORLD_OPCODE {
                        if !SUMMON_RESPONSE_SENT.load(Ordering::SeqCst) {
                            println!("[TELE-10-NEW-WORLD-DIAG] ignored 0x003E before summon accept bytes={}", payload.len());
                            continue;
                        }
                        if WORLDPORT_ACK_SENT
                            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                        {
                            publish_runner_state(
                                "WORLDPORT_ACK_COMMITTED",
                                &format!("SMSG_NEW_WORLD bytes={} observed; sending opcode=0x00DC retry_allowed=false", payload.len()),
                            );
                            if let Err(error) = write_encrypted_raw(
                                stream,
                                crypto.encrypter(),
                                MSG_MOVE_WORLDPORT_ACK_OPCODE,
                                &[],
                            ) {
                                publish_runner_state(
                                    "FAIL_WORLDPORT_ACK_UNCERTAIN",
                                    "opcode=0x00DC socket write uncertain after NEW_WORLD; retry disabled",
                                );
                                return Err(format!("TELE10_WORLDPORT_ACK_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                            }
                            publish_runner_state(
                                "PASS_TELEPORT_COMPLETE",
                                &format!("SMSG_NEW_WORLD opcode=0x003E bytes={} + MSG_MOVE_WORLDPORT_ACK opcode=0x00DC write=success", payload.len()),
                            );
                            println!(
                                "[TELE-10-TELEPORT] PASS new_world_bytes={} worldport_ack=sent",
                                payload.len()
                            );
                        }
                        tele10_customer_pay_after_teleport(stream, crypto)?;
                        continue;
                    }

                    if role == Tele06bRole::Clicker {
                        tele06b_inspect_portal_update(opcode, &payload, &mut portals);
                        if !PORTAL_USE_ATTEMPTED.load(Ordering::SeqCst) {
                            if let Some(guid) = portals.iter().copied().next() {
                                let local_position = match tele06b_local_position() {
                                    Some(value) => value,
                                    None => {
                                        publish_runner_state(
                                            "FAIL_PORTAL_RANGE_UNKNOWN",
                                            "local position unavailable; CMSG_GAMEOBJ_USE not sent and guard not consumed",
                                        );
                                        println!("[TELE-06B-RANGE] FAIL local_position=unknown action=NO_SEND");
                                        return Err("TELE06B_PORTAL_RANGE_UNKNOWN local_position"
                                            .to_string());
                                    }
                                };
                                let portal_position = match tele06b_portal_position(guid) {
                                    Some(value) => value,
                                    None => {
                                        publish_runner_state(
                                            "FAIL_PORTAL_RANGE_UNKNOWN",
                                            &format!("guid=0x{guid:016X} portal position unavailable; CMSG_GAMEOBJ_USE not sent and guard not consumed"),
                                        );
                                        println!("[TELE-06B-RANGE] FAIL guid=0x{guid:016X} portal_position=unknown action=NO_SEND");
                                        return Err("TELE06B_PORTAL_RANGE_UNKNOWN portal_position"
                                            .to_string());
                                    }
                                };
                                let max_range = tele06b_max_range()?;
                                let mut effective_local_position = local_position;
                                let mut distance =
                                    tele06b_distance3(effective_local_position, portal_position);
                                if distance > max_range {
                                    println!(
                                        "[TELE-06C-MOVE] REQUIRED guid=0x{guid:016X} distance={distance:.3} max_range={max_range:.3}"
                                    );
                                    effective_local_position = tele06c_auto_position(
                                        stream,
                                        crypto,
                                        guid,
                                        effective_local_position,
                                        portal_position,
                                    )?;
                                    distance = tele06b_distance3(
                                        effective_local_position,
                                        portal_position,
                                    );
                                    if distance > max_range {
                                        publish_runner_state(
                                            "FAIL_PORTAL_OUT_OF_RANGE",
                                            &format!("guid=0x{guid:016X} post_move_distance={distance:.3} max_range={max_range:.3}; CMSG_GAMEOBJ_USE not sent and portal guard not consumed"),
                                        );
                                        println!(
                                            "[TELE-06B-RANGE] FAIL guid=0x{guid:016X} post_move_distance={distance:.3} max_range={max_range:.3} action=NO_CLICK"
                                        );
                                        return Err(format!(
                                            "TELE06B_PORTAL_OUT_OF_RANGE post_move_distance={distance:.3} max_range={max_range:.3}"
                                        ));
                                    }
                                }
                                let settle_ms = tele06b_click_settle_ms()?;
                                println!(
                                    "[TELE-06B-RANGE] PASS guid=0x{guid:016X} distance={distance:.3} max_range={max_range:.3} settle_ms={settle_ms}"
                                );
                                if settle_ms != 0 {
                                    thread::sleep(Duration::from_millis(settle_ms));
                                }
                                if PORTAL_USE_ATTEMPTED
                                    .compare_exchange(
                                        false,
                                        true,
                                        Ordering::SeqCst,
                                        Ordering::SeqCst,
                                    )
                                    .is_ok()
                                {
                                    publish_runner_state(
                                        "PORTAL_USE_COMMITTED",
                                        &format!(
                                            "guid=0x{guid:016X} opcode=0x00B1 guard committed before socket I/O"
                                        ),
                                    );
                                    println!(
                                        "[TELE-06B-PORTAL-TX] state=COMMITTED guid=0x{guid:016X} opcode=0x00B1 retry_allowed=false"
                                    );
                                    tele_trace::mark_click_commit(guid, &guid.to_le_bytes());
                                    if let Err(error) = write_encrypted_raw(
                                        stream,
                                        crypto.encrypter(),
                                        CMSG_GAMEOBJ_USE_OPCODE,
                                        &guid.to_le_bytes(),
                                    ) {
                                        publish_runner_state(
                                            "FAIL_PORTAL_MUTATION_UNCERTAIN",
                                            &format!(
                                                "guid=0x{guid:016X} socket write failed after guard commit; retry disabled"
                                            ),
                                        );
                                        println!(
                                            "[TELE-06B-PORTAL-TX] state=UNCERTAIN guid=0x{guid:016X} cause={error} retry_allowed=false"
                                        );
                                        return Err(
                                            "TELE06B_PORTAL_MUTATION_UNCERTAIN retry_allowed=false"
                                                .to_string(),
                                        );
                                    }
                                    PORTAL_USE_SUCCEEDED.store(true, Ordering::SeqCst);
                                    tele_trace::mark_click_write_done(guid);
                                    publish_runner_state(
                                        "PORTAL_USE_SENT",
                                        &format!(
                                            "guid=0x{guid:016X} opcode=0x00B1 write=success retry_allowed=false"
                                        ),
                                    );
                                    println!(
                                        "[TELE-06B-PORTAL-TX] state=PORTAL_USE_SENT guid=0x{guid:016X} opcode=0x00B1 result=sent_once server_acceptance=unconfirmed retry_allowed=false"
                                    );
                                }
                            }
                        }
                    }

                    let _ = crate::tele_party_observer::inspect_party_packet(opcode, &payload);
                }
                Err(error)
                    if error.contains("TimedOut")
                        || error.contains("timed out")
                        || error.contains("WouldBlock") => {}
                Err(error) => return Err(error),
            }
        }
    }

    fn configured_accept_from() -> Result<String, String> {
        std::env::var("WOW112_TELE_AUTO_ACCEPT_FROM")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "missing WOW112_TELE_AUTO_ACCEPT_FROM".to_string())
    }

    fn reset_group_once(stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<(), String> {
        if RESET_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!("[TELE-06A-ACCEPTOR-RESET] skip_already_attempted retry_allowed=false");
            return Ok(());
        }
        write_encrypted_raw(stream, crypto.encrypter(), CMSG_GROUP_DISBAND_OPCODE, &[])?;
        println!(
            "[TELE-06A-ACCEPTOR-RESET-TX] opcode=0x007B result=attempted_once retry_allowed=false"
        );
        thread::sleep(Duration::from_millis(1200));
        Ok(())
    }

    fn send_accept_once(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        inviter: &str,
    ) -> Result<(), String> {
        if ACCEPT_ATTEMPTED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            println!("[TELE-06A-ACCEPTOR] inviter={inviter:?} result=skip_already_attempted retry_allowed=false");
            return Ok(());
        }
        write_encrypted_raw(stream, crypto.encrypter(), CMSG_GROUP_ACCEPT_OPCODE, &[])
            .map_err(|error| format!("TELE06A_ACCEPT_MUTATION_UNCERTAIN inviter={inviter:?} retry_allowed=false cause={error}"))?;
        println!("[TELE-06A-ACCEPT-TX] inviter={inviter:?} opcode=0x0072 result=attempted_once retry_allowed=false");
        Ok(())
    }

    fn wait_for_invite(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        expected_inviter: &str,
    ) -> Result<(), String> {
        let previous_timeout = stream.read_timeout().ok().flatten();
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|e| format!("set acceptor timeout failed: {e}"))?;
        let mut last_ping = Instant::now();
        let mut ping_sequence = 1u32;
        let mut awaiting_pong: Option<(u32, Instant)> = None;

        println!("[TELE-06A-ACCEPTOR] ARMED ONCE whitelist={expected_inviter:?} wait=infinite");
        publish_runner_state("ARMED", "waiting for fresh keepalive pong");
        loop {
            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("world keepalive pong timeout sequence={sequence}"));
                }
            }
            if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS)
                && awaiting_pong.is_none()
            {
                let mut payload = Vec::with_capacity(8);
                payload.extend_from_slice(&ping_sequence.to_le_bytes());
                payload.extend_from_slice(&0u32.to_le_bytes());
                write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
                println!("[TELE-06A-ACCEPTOR] keepalive ping sequence={ping_sequence}");
                awaiting_pong = Some((ping_sequence, Instant::now()));
                ping_sequence = ping_sequence.wrapping_add(1);
                last_ping = Instant::now();
            }

            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if opcode == SMSG_PONG_OPCODE {
                        if payload.len() >= 4 {
                            let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            println!("[TELE-06A-ACCEPTOR] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                                publish_runner_state(
                                    "READY",
                                    &format!("fresh pong sequence={sequence}"),
                                );
                            }
                        }
                        continue;
                    }
                    if opcode == SMSG_GROUP_INVITE_OPCODE {
                        match parse_raw_server_message(opcode, &payload) {
                            Ok(ServerOpcodeMessage::SMSG_GROUP_INVITE(invite)) => {
                                println!(
                                    "[TELE-06A-ACCEPT-RX] inviter={:?} expected={:?}",
                                    invite.name, expected_inviter
                                );
                                if !invite.name.eq_ignore_ascii_case(expected_inviter) {
                                    println!("[TELE-06A-ACCEPTOR] inviter={:?} result=ignored_not_whitelisted", invite.name);
                                    continue;
                                }
                                send_accept_once(stream, crypto, &invite.name)?;
                                let _ = stream.set_read_timeout(previous_timeout);
                                return Ok(());
                            }
                            Ok(other) => println!(
                                "[TELE-06A-ACCEPTOR-DIAG] unexpected invite parse={other:?}"
                            ),
                            Err(error) => {
                                println!("[TELE-06A-ACCEPTOR-DIAG] invite parse failed: {error}")
                            }
                        }
                        continue;
                    }
                    crate::tele_party_observer::inspect_party_packet(opcode, &payload);
                }
                Err(error)
                    if error.contains("TimedOut")
                        || error.contains("timed out")
                        || error.contains("WouldBlock") => {}
                Err(error) => return Err(error),
            }
        }
    }

    pub fn login_agent(
        stream: &mut TcpStream,
        session_key: [u8; SESSION_KEY_LENGTH as usize],
        server_id: u8,
        username: &str,
        character_name: Option<&str>,
        soak_seconds: u64,
    ) -> Result<(), String> {
        stream
            .set_read_timeout(Some(Duration::from_millis(LOGIN_WATCHDOG_MS)))
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
        let characters =
            expect_server_message_encryption::<SMSG_CHAR_ENUM, _>(&mut *stream, crypto.decrypter())
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
        tele_trace::set_local_guid(selected.guid.guid());
        CMSG_PLAYER_LOGIN {
            guid: selected.guid,
        }
        .write_encrypted_client(&mut *stream, crypto.encrypter())
        .map_err(|e| format!("write player login failed: {e:?}"))?;

        let mut login_verified = false;
        for index in 0..256usize {
            let opcode = ServerOpcodeMessage::read_encrypted(&mut *stream, crypto.decrypter())
                .map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;
            if index < 24 {
                println!("[WORLD] rx[{index}] {opcode:?}");
            }
            if let ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(verify) = opcode {
                tele06b_set_local_position(verify.position.x, verify.position.y, verify.position.z);
                println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS");
                login_verified = true;
                break;
            }
        }
        if !login_verified {
            return Err(
                "world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets"
                    .to_string(),
            );
        }

        reset_group_once(stream, &mut crypto)?;
        let inviter = configured_accept_from()?;
        wait_for_invite(stream, &mut crypto, &inviter)?;
        publish_runner_state("HANDSHAKE", "invite accepted");
        println!("[TELE-06A-ACCEPTOR] handshake complete; observer active");
        tele06b_post_handshake_loop(stream, &mut crypto, soak_seconds)?;
        Ok(())
    }
}

fn parse_env_u64(name: &str, default_value: u64) -> Result<u64, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u64>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn parse_env_u32(name: &str, default_value: u32) -> Result<u32, String> {
    match env::var(name) {
        Ok(value) => value
            .parse::<u32>()
            .map_err(|e| format!("invalid {name}={value:?}: {e}")),
        Err(_) => Ok(default_value),
    }
}

fn is_transient_network_error(error: &str) -> bool {
    if error.contains("TELE06C_MOVE_MUTATION_UNCERTAIN") {
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
        "world socket closed",
        "world keepalive pong timeout",
        "10060",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn main() {
    if let Err(error) = run() {
        eprintln!("[TELE-06A-ACCEPTOR] ERROR: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let username = env::var("WOW112_ACCOUNT")
        .map_err(|_| "missing WOW112_ACCOUNT".to_string())?
        .to_ascii_uppercase();
    let password =
        env::var("WOW112_PASSWORD").map_err(|_| "missing WOW112_PASSWORD".to_string())?;
    let auth_addr = env::var("WOW112_AUTH_ADDR").unwrap_or_else(|_| DEFAULT_AUTH_ADDR.to_string());
    let character_name = env::var("WOW112_CHARACTER").ok();
    let realm_index = env::var("WOW112_REALM_INDEX")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_REALM_INDEX);
    let soak_seconds = parse_env_u64("WOW112_SOAK_SECONDS", 0)?;
    let reconnect_limit = parse_env_u32("WOW112_RECONNECT_LIMIT", DEFAULT_RECONNECT_LIMIT)?.max(1);
    let reconnect_delay_ms = parse_env_u64("WOW112_RECONNECT_DELAY_MS", 0)?;
    let accept_from = env::var("WOW112_TELE_AUTO_ACCEPT_FROM").unwrap_or_default();

    println!("[WOW112-HEADLESS] binary-build=5875 wire-build={} protocol=vanilla target=windows-headless mode=tele06a-acceptor", OCTOWOW_WIRE_BUILD);
    println!("[TELE-06A-ACCEPTOR] account={} character={} accept_from={:?} reset_group=enabled reconnect_limit={} accept_retry=disabled", username, character_name.as_deref().unwrap_or("first"), accept_from, reconnect_limit);

    for attempt in 1..=reconnect_limit {
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        env::set_var("WOW112_RUNNER_SESSION_ATTEMPT", attempt.to_string());
        publish_runner_state("CONNECTING", "new session attempt");
        match run_session(
            &auth_addr,
            realm_index,
            &username,
            &password,
            character_name.as_deref(),
            soak_seconds,
        ) {
            Ok(()) => return Ok(()),
            Err(error) if is_transient_network_error(&error) && attempt < reconnect_limit => {
                let display_error = if error.contains("10060") {
                    "network timeout (WinSock 10060: remote host did not respond)".to_string()
                } else {
                    error.clone()
                };
                println!("[RESILIENCE] transient network failure: {display_error}");
                println!("[RESILIENCE] reconnecting; reset/accept guards remain committed");
                if reconnect_delay_ms != 0 {
                    thread::sleep(Duration::from_millis(reconnect_delay_ms));
                }
            }
            Err(error) => return Err(error),
        }
    }
    Err(format!(
        "acceptor reconnect limit exhausted after {reconnect_limit} attempts"
    ))
}

fn run_session(
    auth_addr: &str,
    realm_index: usize,
    username: &str,
    password: &str,
    character_name: Option<&str>,
    soak_seconds: u64,
) -> Result<(), String> {
    println!("[AUTH] connecting to {auth_addr}");
    let mut auth_stream = connect_with_login_watchdog(auth_addr, "AUTH")?;
    arm_login_watchdog(&auth_stream, "AUTH")?;
    let (session_key, realms) = auth::authenticate(&mut auth_stream, username, password)?;
    if realms.realms.is_empty() {
        return Err("auth succeeded but realm list is empty".to_string());
    }
    println!("[AUTH] realms={}", realms.realms.len());
    for (index, realm) in realms.realms.iter().enumerate() {
        println!(
            "[AUTH] realm[{index}] name={} address={} id={}",
            realm.name, realm.address, realm.realm_id
        );
    }
    let realm = realms
        .realms
        .get(realm_index)
        .ok_or_else(|| format!("WOW112_REALM_INDEX={realm_index} is out of range"))?;
    let world_addr = env::var("WOW112_WORLD_ADDR").unwrap_or_else(|_| realm.address.clone());
    println!(
        "[WORLD] connecting realm={} id={} address={}",
        realm.name, realm.realm_id, world_addr
    );
    let mut world_stream = connect_with_login_watchdog(&world_addr, "WORLD")?;
    arm_login_watchdog(&world_stream, "WORLD")?;
    agent::login_agent(
        &mut world_stream,
        session_key,
        realm.realm_id,
        username,
        character_name,
        soak_seconds,
    )
}
