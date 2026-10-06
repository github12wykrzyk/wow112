$ErrorActionPreference = 'Stop'

$acceptor = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs'
$a = Get-Content $acceptor -Raw

function Require-Replace([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old,$New)
}

# V1.5 is deliberately a post-patch hardening layer over the already-live-tested
# TELE06B V1.4 path. Do not alter party/cast logic or retry semantics.
$oldStatics = @'
    static PORTAL_USE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static PORTAL_USE_SUCCEEDED: AtomicBool = AtomicBool::new(false);
    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);
'@
$newStatics = @'
    static PORTAL_USE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static PORTAL_USE_SUCCEEDED: AtomicBool = AtomicBool::new(false);
    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);

    const TELE06B_DEFAULT_MAX_RANGE: f32 = 5.8;
    const TELE06B_DEFAULT_CLICK_SETTLE_MS: u64 = 150;
    static TELE06B_LOCAL_POSITION: std::sync::Mutex<Option<[f32; 3]>> = std::sync::Mutex::new(None);
    static TELE06B_LAST_PORTAL_POSITION: std::sync::Mutex<Option<(u64, [f32; 3])>> = std::sync::Mutex::new(None);

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

    fn tele06b_record_portal_position(object: &Object, guid: u64) {
        let Some(position) = tele06b_portal_position_from_object(object) else { return; };
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
            .and_then(|(seen_guid, position)| if seen_guid == guid { Some(position) } else { None })
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
                let parsed = value.trim().parse::<f32>()
                    .map_err(|e| format!("invalid WOW112_TELE06B_MAX_RANGE={value:?}: {e}"))?;
                if !parsed.is_finite() || parsed <= 0.0 || parsed > 20.0 {
                    return Err(format!("invalid WOW112_TELE06B_MAX_RANGE={value:?}; expected 0..20"));
                }
                Ok(parsed)
            }
            Err(_) => Ok(TELE06B_DEFAULT_MAX_RANGE),
        }
    }

    fn tele06b_click_settle_ms() -> Result<u64, String> {
        match std::env::var("WOW112_TELE06B_CLICK_SETTLE_MS") {
            Ok(value) => {
                let parsed = value.trim().parse::<u64>()
                    .map_err(|e| format!("invalid WOW112_TELE06B_CLICK_SETTLE_MS={value:?}: {e}"))?;
                if parsed > 5000 {
                    return Err(format!("invalid WOW112_TELE06B_CLICK_SETTLE_MS={value:?}; expected <=5000"));
                }
                Ok(parsed)
            }
            Err(_) => Ok(TELE06B_DEFAULT_CLICK_SETTLE_MS),
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
'@
$a = Require-Replace $a $oldStatics.Trim() $newStatics.Trim() 'V1.5 range state/helpers'

# Preserve the working portal collector and only record the authoritative CreateObject XYZ.
$oldPortalInsert = @'
                if portals.insert(guid) {
                    println!("[TELE-06B-PORTAL] observed valid summoning portal guid=0x{guid:016X}");
                    println!(
                        "[TELE-06B-PORTAL-OBJECT] {}",
                        tele_trace::truncate_chars(&format!("{object:?}"), 2400)
                    );
                    tele_trace::mark_portal_observed(guid);
                }
'@
$newPortalInsert = @'
                tele06b_record_portal_position(object, guid);
                if portals.insert(guid) {
                    println!("[TELE-06B-PORTAL] observed valid summoning portal guid=0x{guid:016X}");
                    println!(
                        "[TELE-06B-PORTAL-OBJECT] {}",
                        tele_trace::truncate_chars(&format!("{object:?}"), 2400)
                    );
                    tele_trace::mark_portal_observed(guid);
                }
'@
$a = Require-Replace $a $oldPortalInsert.Trim() $newPortalInsert.Trim() 'portal XYZ capture'

# Capture server-authoritative player XYZ from SMSG_LOGIN_VERIFY_WORLD.
$oldVerify = @'
            if matches!(opcode, ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(_)) {
                println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS");
                login_verified = true;
                break;
            }
'@
$newVerify = @'
            if let ServerOpcodeMessage::SMSG_LOGIN_VERIFY_WORLD(verify) = opcode {
                tele06b_set_local_position(verify.position.x, verify.position.y, verify.position.z);
                println!("[WORLD] SMSG_LOGIN_VERIFY_WORLD PASS");
                login_verified = true;
                break;
            }
'@
$a = Require-Replace $a $oldVerify.Trim() $newVerify.Trim() 'local XYZ from login verify'

# Fail closed BEFORE mutation guard commitment if either coordinate is unavailable or
# if the live A/B-derived safe range is exceeded. A short configurable settle delay
# removes the sub-20ms portal/channel race without requiring clicker-local channel RX.
$guardAnchor = @'
                                if PORTAL_USE_ATTEMPTED
                                    .compare_exchange(
'@
$guarded = @'
                                let local_position = match tele06b_local_position() {
                                    Some(value) => value,
                                    None => {
                                        publish_runner_state(
                                            "FAIL_PORTAL_RANGE_UNKNOWN",
                                            "local position unavailable; CMSG_GAMEOBJ_USE not sent and guard not consumed",
                                        );
                                        println!("[TELE-06B-RANGE] FAIL local_position=unknown action=NO_SEND");
                                        return Err("TELE06B_PORTAL_RANGE_UNKNOWN local_position".to_string());
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
                                        return Err("TELE06B_PORTAL_RANGE_UNKNOWN portal_position".to_string());
                                    }
                                };
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
                                println!(
                                    "[TELE-06B-RANGE] PASS guid=0x{guid:016X} distance={distance:.3} max_range={max_range:.3} settle_ms={settle_ms}"
                                );
                                if settle_ms != 0 {
                                    thread::sleep(Duration::from_millis(settle_ms));
                                }
                                if PORTAL_USE_ATTEMPTED
                                    .compare_exchange(
'@
$a = Require-Replace $a $guardAnchor.Trim() $guarded.Trim() 'range gate before mutation guard'

# Correct the control-plane semantics: a successful socket write is SENT, not proof
# that the server accepted the ritual participant.
$a = $a.Replace('PORTAL_USED', 'PORTAL_USE_SENT')
$a = $a.Replace('portal use write succeeded in prior live session; retry disabled', 'portal use socket write succeeded in prior live session; server acceptance not implied; retry disabled')
$a = $a.Replace('result=sent_once retry_allowed=false', 'result=sent_once server_acceptance=unconfirmed retry_allowed=false')

$check = $a
foreach ($needle in @(
    'TELE06B_DEFAULT_MAX_RANGE: f32 = 5.8',
    'WOW112_TELE06B_MAX_RANGE',
    'WOW112_TELE06B_CLICK_SETTLE_MS',
    'tele06b_set_local_position(verify.position.x',
    'tele06b_record_portal_position(object, guid)',
    'FAIL_PORTAL_OUT_OF_RANGE',
    'FAIL_PORTAL_RANGE_UNKNOWN',
    'PORTAL_USE_SENT',
    '[TELE-06B-RANGE] PASS',
    'guard not consumed'
)) {
    if (-not $check.Contains($needle)) { throw "TELE06B V1.5 range-safe marker missing: $needle" }
}
if ($check.Contains('"PORTAL_USED"')) { throw 'legacy PORTAL_USED runtime state survived V1.5 patch' }

Set-Content -Path $acceptor -Value $a -Encoding UTF8
Write-Host 'TELE06B V1.5 RANGE-SAFE PATCH PASS'
