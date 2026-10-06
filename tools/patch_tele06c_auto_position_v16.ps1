$ErrorActionPreference = 'Stop'

$acceptor = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs'
$a = Get-Content $acceptor -Raw

function Require-Replace([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old,$New)
}

# V1.6 is a bounded recovery layer over the frozen V1.5 range-safe core.
# It may move only a short distance toward the already-observed ritual portal.
$oldStatics = @'
    static PORTAL_USE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static PORTAL_USE_SUCCEEDED: AtomicBool = AtomicBool::new(false);
    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);
'@
$newStatics = @'
    static PORTAL_USE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static PORTAL_USE_SUCCEEDED: AtomicBool = AtomicBool::new(false);
    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);
    static TELE06C_MOVE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
'@
$a = Require-Replace $a $oldStatics.Trim() $newStatics.Trim() 'V1.6 movement guard'

$testAnchor = @'
    #[cfg(test)]
    mod tele06b_v15_tests {
'@
$helpers = @'
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
                publish_runner_state("FAIL_AUTO_POSITION_LIMIT", &format!("guid=0x{guid:016X} {error}; no movement sent"));
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
            publish_runner_state("FAIL_AUTO_POSITION_ALREADY_ATTEMPTED", "movement guard already committed; retry disabled");
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
            let payload = tele06c_movement_payload(position, orientation, tele06c_movement_timestamp());
            if let Err(error) = write_encrypted_raw(stream, crypto.encrypter(), TELE06C_HEARTBEAT_OPCODE, &payload) {
                publish_runner_state(
                    "FAIL_AUTO_POSITION_UNCERTAIN",
                    &format!("guid=0x{guid:016X} step={}/{} movement write uncertain; retry disabled", index + 1, steps.len()),
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
            assert!((tele06b_distance3(*steps.last().unwrap(), portal) - TELE06C_TARGET_RANGE).abs() < 0.01);
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
            assert!((f32::from_le_bytes(p[16..20].try_into().unwrap()) - 3.75).abs() < f32::EPSILON);
            assert!((f32::from_le_bytes(p[20..24].try_into().unwrap()) - 1.5).abs() < f32::EPSILON);
            assert_eq!(f32::from_le_bytes(p[24..28].try_into().unwrap()), 0.0);
        }
    }

    #[cfg(test)]
    mod tele06b_v15_tests {
'@
$a = Require-Replace $a $testAnchor.Trim() $helpers.Trim() 'V1.6 movement helpers/tests'

$oldRange = @'
                                let distance = tele06b_distance3(local_position, portal_position);
                                let max_range = tele06b_max_range()?;
                                if distance > max_range {
                                    publish_runner_state(
                                        "FAIL_PORTAL_OUT_OF_RANGE",
                                        &format!("guid=0x{guid:016X} distance={distance:.3} max_range={max_range:.3}; CMSG_GAMEOBJ_USE not sent and guard not consumed"),
                                    );
                                    println!(
                                        "[TELE-06B-RANGE] FAIL guid=0x{guid:016X} distance={distance:.3} max_range={max_range:.3} action=NO_SEND"
                                    );
                                    return Err(format!(
                                        "TELE06B_PORTAL_OUT_OF_RANGE distance={distance:.3} max_range={max_range:.3}"
                                    ));
                                }
                                let settle_ms = tele06b_click_settle_ms()?;
'@
$newRange = @'
                                let max_range = tele06b_max_range()?;
                                let mut effective_local_position = local_position;
                                let mut distance = tele06b_distance3(effective_local_position, portal_position);
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
                                    distance = tele06b_distance3(effective_local_position, portal_position);
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
'@
$a = Require-Replace $a $oldRange.Trim() $newRange.Trim() 'V1.6 recover before range failure'

# Movement mutation uncertainty must never enter the generic transient reconnect path.
$transientSignature = 'fn is_transient_network_error(error: &str) -> bool {'
$transientWithGuard = @'
fn is_transient_network_error(error: &str) -> bool {
    if error.contains("TELE06C_MOVE_MUTATION_UNCERTAIN") {
        return false;
    }
'@
$a = Require-Replace $a $transientSignature $transientWithGuard.TrimEnd() 'V1.6 no reconnect after uncertain movement'

foreach ($needle in @(
    'TELE06C_MOVE_ATTEMPTED',
    'TELE06C_HEARTBEAT_OPCODE: u32 = 0x00EE',
    'TELE06C_TARGET_RANGE: f32 = 4.8',
    'TELE06C_MAX_RECOVERY_MOVE: f32 = 3.0',
    'TELE06C_MAX_STEP: f32 = 1.25',
    'TELE06C_STEP_DELAY_MS: u64 = 120',
    'FAIL_AUTO_POSITION_LIMIT',
    'FAIL_AUTO_POSITION_UNCERTAIN',
    'AUTO_POSITION_SENT',
    '[TELE-06C-MOVE-TX]',
    'TELE06C_MOVE_MUTATION_UNCERTAIN'
)) {
    if (-not $a.Contains($needle)) { throw "TELE06C V1.6 marker missing: $needle" }
}

Set-Content -Path $acceptor -Value $a -Encoding UTF8
Write-Host 'TELE06C V1.6 BOUNDED AUTO-POSITION PATCH PASS'
