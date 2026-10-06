$ErrorActionPreference = 'Stop'

$acceptor = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs'
$summoner = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs'

function Require-Replace([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}

# -----------------------------------------------------------------------------
# Acceptor: publish a tiny state file that the runner can read while stdout is
# redirected/locked by Start-Process on Windows PowerShell 5.1.
# -----------------------------------------------------------------------------
$a = Get-Content $acceptor -Raw

$oldImports = "use std::env;`nuse std::net::TcpStream;"
$newImports = "use std::env;`nuse std::fs;`nuse std::net::TcpStream;"
$a = Require-Replace $a $oldImports $newImports 'acceptor imports'

$anchor = 'const DEFAULT_RECONNECT_LIMIT: u32 = 60;'
$stateHelper = @'
const DEFAULT_RECONNECT_LIMIT: u32 = 60;

fn publish_runner_state(state: &str, detail: &str) {
    let Ok(path) = env::var("WOW112_RUNNER_STATE_FILE") else { return; };
    if path.trim().is_empty() { return; }
    let session = env::var("WOW112_RUNNER_SESSION_ATTEMPT").unwrap_or_else(|_| "0".to_string());
    let safe_detail = detail.replace('\r', " ").replace('\n', " ");
    let body = format!("state={state}\nsession={session}\ndetail={safe_detail}\n");
    let _ = fs::write(path, body);
}
'@
$a = Require-Replace $a $anchor $stateHelper.TrimEnd() 'acceptor state helper'

$oldArmed = '        println!("[TELE-06A-ACCEPTOR] ARMED ONCE whitelist={expected_inviter:?} wait=infinite");'
$newArmed = @'
        println!("[TELE-06A-ACCEPTOR] ARMED ONCE whitelist={expected_inviter:?} wait=infinite");
        publish_runner_state("ARMED", "waiting for fresh keepalive pong");
'@
$a = Require-Replace $a $oldArmed $newArmed.TrimEnd() 'acceptor armed state'

$oldPong = @'
                            println!("[TELE-06A-ACCEPTOR] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                            }
'@
$newPong = @'
                            println!("[TELE-06A-ACCEPTOR] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                                publish_runner_state("READY", &format!("fresh pong sequence={sequence}"));
                            }
'@
$a = Require-Replace $a $oldPong.Trim() $newPong.Trim() 'acceptor ready state'

$oldHandshake = '        println!("[TELE-06A-ACCEPTOR] handshake complete; observer active");'
$newHandshake = @'
        publish_runner_state("HANDSHAKE", "invite accepted");
        println!("[TELE-06A-ACCEPTOR] handshake complete; observer active");
'@
$a = Require-Replace $a $oldHandshake $newHandshake.TrimEnd() 'acceptor handshake state'

$oldAttempt = '        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");'
$newAttempt = @'
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        env::set_var("WOW112_RUNNER_SESSION_ATTEMPT", attempt.to_string());
        publish_runner_state("CONNECTING", "new session attempt");
'@
$a = Require-Replace $a $oldAttempt $newAttempt.TrimEnd() 'acceptor session state'

Set-Content -Path $acceptor -Value $a -Encoding UTF8

# -----------------------------------------------------------------------------
# Summoner: publish verdict/checkpoint state directly as well, so the runner
# never has to tail an active redirected stdout file.
# -----------------------------------------------------------------------------
$s = Get-Content $summoner -Raw

$oldImportsS = "use std::env;`nuse std::net::TcpStream;"
$newImportsS = "use std::env;`nuse std::fs;`nuse std::net::TcpStream;"
$s = Require-Replace $s $oldImportsS $newImportsS 'summoner imports'

$anchorS = 'const DEFAULT_RECONNECT_LIMIT: u32 = 60;'
$stateHelperS = @'
const DEFAULT_RECONNECT_LIMIT: u32 = 60;

fn publish_runner_state(state: &str, detail: &str) {
    let Ok(path) = env::var("WOW112_RUNNER_STATE_FILE") else { return; };
    if path.trim().is_empty() { return; }
    let session = env::var("WOW112_RUNNER_SESSION_ATTEMPT").unwrap_or_else(|_| "0".to_string());
    let safe_detail = detail.replace('\r', " ").replace('\n', " ");
    let body = format!("state={state}\nsession={session}\ndetail={safe_detail}\n");
    let _ = fs::write(path, body);
}
'@
$s = Require-Replace $s $anchorS $stateHelperS.TrimEnd() 'summoner state helper'

$s = Require-Replace $s $oldAttempt $newAttempt.TrimEnd() 'summoner session state'

$oldRosterPass = '                        println!("[TELE-06A-ROSTER] PASS target={:?} target_guid=0x{:016X}", ritual_target_name, target_guid);'
$newRosterPass = @'
                        println!("[TELE-06A-ROSTER] PASS target={:?} target_guid=0x{:016X}", ritual_target_name, target_guid);
                        publish_runner_state("ROSTER_PASS", &format!("target={} guid=0x{:016X}", ritual_target_name, target_guid));
'@
$s = Require-Replace $s $oldRosterPass $newRosterPass.TrimEnd() 'summoner roster pass state'

$oldSelection = @'
        println!(
            "[TELE-06A-SELECTION-TX] opcode=0x013D target={:?} target_guid=0x{:016X} bytes=8 result=attempted_once retry_allowed=false",
            target_name,
            target_guid
        );
'@
$newSelection = @'
        println!(
            "[TELE-06A-SELECTION-TX] opcode=0x013D target={:?} target_guid=0x{:016X} bytes=8 result=attempted_once retry_allowed=false",
            target_name,
            target_guid
        );
        publish_runner_state("SELECTION_SENT", &format!("target={} guid=0x{:016X}", target_name, target_guid));
'@
$s = Require-Replace $s $oldSelection.Trim() $newSelection.Trim() 'summoner selection state'

$oldCast = @'
        println!(
            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} target_mode=selection target_mask=0x0000 bytes={} result=attempted_once retry_allowed=false",
'@
$newCast = @'
        publish_runner_state("CAST_SENT", "spell=698 target_mode=selection target_mask=0x0000");
        println!(
            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} target_mode=selection target_mask=0x0000 bytes={} result=attempted_once retry_allowed=false",
'@
$s = Require-Replace $s $oldCast.Trim() $newCast.Trim() 'summoner cast state'

$passStart = '                                println!("[TELE-06A-RITUAL] LIVE_CAST_START_PASS spell=698");'
$passStartNew = @'
                                publish_runner_state("PASS_RITUAL_STARTED", "SMSG_SPELL_START spell=698");
                                println!("[TELE-06A-RITUAL] LIVE_CAST_START_PASS spell=698");
'@
$s = Require-Replace $s $passStart $passStartNew.TrimEnd() 'summoner spell start pass state'

$passGo = '                                println!("[TELE-06A-RITUAL] LIVE_CAST_GO_PASS spell=698");'
$passGoNew = @'
                                publish_runner_state("PASS_RITUAL_STARTED", "SMSG_SPELL_GO spell=698");
                                println!("[TELE-06A-RITUAL] LIVE_CAST_GO_PASS spell=698");
'@
$s = Require-Replace $s $passGo $passGoNew.TrimEnd() 'summoner spell go pass state'

$reject = '                                println!("[TELE-06A-RITUAL] SERVER_REJECT spell=698 retry_allowed=false");'
$rejectNew = @'
                                publish_runner_state("FAIL_SERVER_REJECT", "spell=698 see raw cast-result log for reason");
                                println!("[TELE-06A-RITUAL] SERVER_REJECT spell=698 retry_allowed=false");
'@
$s = Require-Replace $s $reject $rejectNew.TrimEnd() 'summoner reject state'

Set-Content -Path $summoner -Value $s -Encoding UTF8

$acheck = Get-Content $acceptor -Raw
$scheck = Get-Content $summoner -Raw
foreach ($needle in @('WOW112_RUNNER_STATE_FILE','publish_runner_state("ARMED"','publish_runner_state("READY"','publish_runner_state("HANDSHAKE"')) {
    if (-not $acheck.Contains($needle)) { throw "acceptor runner-state patch missing: $needle" }
}
foreach ($needle in @('WOW112_RUNNER_STATE_FILE','publish_runner_state("ROSTER_PASS"','publish_runner_state("SELECTION_SENT"','publish_runner_state("CAST_SENT"','publish_runner_state("PASS_RITUAL_STARTED"','publish_runner_state("FAIL_SERVER_REJECT"')) {
    if (-not $scheck.Contains($needle)) { throw "summoner runner-state patch missing: $needle" }
}
Write-Host 'LIVE RUNNER V1.1 RUNTIME STATE PATCH PASS'
