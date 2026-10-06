$ErrorActionPreference = 'Stop'

$acceptor = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs'
$summoner = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs'

function Require-Replace([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}

function Add-StateHelper([string]$Text, [string]$Label) {
    $Text = [regex]::Replace($Text, 'use std::env;\r?\nuse std::net::TcpStream;', "use std::env;`r`nuse std::fs;`r`nuse std::net::TcpStream;", 1)
    if (-not $Text.Contains('use std::fs;')) { throw "$Label imports patch failed" }
    $anchor = 'const DEFAULT_RECONNECT_LIMIT: u32 = 60;'
    $helper = @'
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
    return Require-Replace $Text $anchor $helper.TrimEnd() "$Label state helper"
}

$oldAttempt = '        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");'
$newAttempt = @'
        println!("[RESILIENCE] session attempt={attempt}/{reconnect_limit}");
        env::set_var("WOW112_RUNNER_SESSION_ATTEMPT", attempt.to_string());
        publish_runner_state("CONNECTING", "new session attempt");
'@

# --- acceptor control-plane states -------------------------------------------------
$a = Get-Content $acceptor -Raw
$a = Add-StateHelper $a 'acceptor'
$a = Require-Replace $a $oldAttempt $newAttempt.TrimEnd() 'acceptor session state'

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
Set-Content -Path $acceptor -Value $a -Encoding UTF8

# --- summoner control-plane states -------------------------------------------------
# We intentionally keep this minimal: the runner only needs current session,
# CAST_SENT, terminal PASS, or terminal REJECT. Full stdout remains diagnostic.
$s = Get-Content $summoner -Raw
$s = Add-StateHelper $s 'summoner'
$s = Require-Replace $s $oldAttempt $newAttempt.TrimEnd() 'summoner session state'

$castLogAnchor = @'
        println!(
            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} target_mode=selection target_mask=0x0000 bytes={} result=attempted_once retry_allowed=false",
'@
$castLogNew = @'
        publish_runner_state("CAST_SENT", "spell=698 target_mode=selection target_mask=0x0000");
        println!(
            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} target_mode=selection target_mask=0x0000 bytes={} result=attempted_once retry_allowed=false",
'@
$s = Require-Replace $s $castLogAnchor.Trim() $castLogNew.Trim() 'summoner cast-sent state'

$passStart = '                                println!("[TELE-06A-RITUAL] LIVE_CAST_START_PASS spell=698 retry_allowed=false");'
$passStartNew = @'
                                publish_runner_state("PASS_RITUAL_STARTED", "SMSG_SPELL_START spell=698");
                                println!("[TELE-06A-RITUAL] LIVE_CAST_START_PASS spell=698 retry_allowed=false");
'@
$s = Require-Replace $s $passStart $passStartNew.TrimEnd() 'summoner spell-start pass state'

$passGo = '                                println!("[TELE-06A-RITUAL] LIVE_CAST_GO_PASS spell=698 retry_allowed=false");'
$passGoNew = @'
                                publish_runner_state("PASS_RITUAL_STARTED", "SMSG_SPELL_GO spell=698");
                                println!("[TELE-06A-RITUAL] LIVE_CAST_GO_PASS spell=698 retry_allowed=false");
'@
$s = Require-Replace $s $passGo $passGoNew.TrimEnd() 'summoner spell-go pass state'

$rejectBranch = @'
                            SMSG_CAST_RESULT_OPCODE | SMSG_SPELL_FAILURE_OPCODE => {
                                println!(
'@
$rejectBranchNew = @'
                            SMSG_CAST_RESULT_OPCODE | SMSG_SPELL_FAILURE_OPCODE => {
                                publish_runner_state("FAIL_SERVER_REJECT", "spell=698 see raw cast-result log for reason");
                                println!(
'@
$s = Require-Replace $s $rejectBranch.Trim() $rejectBranchNew.Trim() 'summoner reject state'
Set-Content -Path $summoner -Value $s -Encoding UTF8

# Fail closed if any control-plane marker is missing.
$acheck = Get-Content $acceptor -Raw
$scheck = Get-Content $summoner -Raw
foreach ($needle in @('WOW112_RUNNER_STATE_FILE','publish_runner_state("CONNECTING"','publish_runner_state("ARMED"','publish_runner_state("READY"','publish_runner_state("HANDSHAKE"')) {
    if (-not $acheck.Contains($needle)) { throw "acceptor runner-state patch missing: $needle" }
}
foreach ($needle in @('WOW112_RUNNER_STATE_FILE','publish_runner_state("CONNECTING"','publish_runner_state("CAST_SENT"','publish_runner_state("PASS_RITUAL_STARTED"','publish_runner_state("FAIL_SERVER_REJECT"')) {
    if (-not $scheck.Contains($needle)) { throw "summoner runner-state patch missing: $needle" }
}
Write-Host 'LIVE RUNNER V1.1 RUNTIME STATE PATCH PASS'
