$ErrorActionPreference = 'Stop'
# TELE-06A V1.2: replace the one-shot 3-invite batch with SEQUENTIAL PARTY CONVERGENCE.
# Must run AFTER patch_tele06a_v4.ps1 and patch_live_runner_v11.ps1.
# Line-ending agnostic: works on LF (linux) and CRLF (windows checkout).

$summoner = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs'
$seqModule = 'probes/Wow112HeadlessAndroid/src/tele_party_seq.rs'
if (-not (Test-Path $seqModule)) { throw 'tele_party_seq.rs missing' }

function LF([string]$t) { return $t.Replace("`r`n", "`n") }
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $Old = LF $Old; $New = LF $New
    $first = $Text.IndexOf($Old)
    if ($first -lt 0) { throw "missing patch anchor: $Label" }
    if ($Text.IndexOf($Old, $first + 1) -ge 0) { throw "ambiguous patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}
function Regex-Once([string]$Text, [string]$Pattern, [string]$New, [string]$Label) {
    $m = [regex]::Matches($Text, $Pattern)
    if ($m.Count -ne 1) { throw "regex anchor '$Label' matched $($m.Count) times (expected 1)" }
    return [regex]::Replace($Text, $Pattern, { param($x) $New }, 1)
}

$s = LF (Get-Content $summoner -Raw)
if ($s.Contains('tele_party_seq')) { throw 'sequential party patch already applied' }

# 1. module declaration
$s = Replace-Once $s @'
#[path = "../wire_build.rs"]
mod wire_build;
'@ @'
#[path = "../tele_party_seq.rs"]
mod tele_party_seq;
#[path = "../wire_build.rs"]
mod wire_build;
'@ 'mod decl'

# 2. replace send_invite_batch_once with sequential helpers
$helpers = @'
    static PARTY: std::sync::OnceLock<std::sync::Mutex<crate::tele_party_seq::PartySeq>> =
        std::sync::OnceLock::new();
    static PARTY_EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

    fn party_clock_ms() -> u64 {
        PARTY_EPOCH.get_or_init(Instant::now).elapsed().as_millis() as u64
    }

    fn party_lock() -> Result<std::sync::MutexGuard<'static, crate::tele_party_seq::PartySeq>, String> {
        PARTY
            .get()
            .ok_or_else(|| "party sequence not registered".to_string())?
            .lock()
            .map_err(|_| "party sequence lock poisoned".to_string())
    }

    /// Registers the sequential party engine ONCE per process. The engine lives in a
    /// static so a reconnect can never replay an invite (all guards stay committed).
    fn register_party_sequence(targets: &[String]) -> Result<(), String> {
        if targets.is_empty() {
            return Err("WOW112_TELE_INVITE_LIST is empty".to_string());
        }
        let timeout_seconds = std::env::var("WOW112_TELE_INVITE_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.trim().parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(45);
        let engine = crate::tele_party_seq::PartySeq::new(targets, timeout_seconds * 1000);
        if PARTY.set(std::sync::Mutex::new(engine)).is_err() {
            println!("[TELE-06A-PARTY] sequence=skip_already_registered retry_allowed=false");
            return Ok(());
        }
        PARTY_EPOCH.get_or_init(Instant::now);
        println!(
            "[TELE-06A-PARTY] mode=sequential members={:?} per_member_timeout={}s retry_allowed=false",
            targets, timeout_seconds
        );
        Ok(())
    }

    /// One engine step. Ok(true) = full roster confirmed sequentially.
    /// The member is marked INVITE_SENT inside next_action BEFORE the socket write.
    fn party_step(stream: &mut TcpStream, crypto: &mut HeaderCrypto) -> Result<bool, String> {
        use crate::tele_party_seq::{Action, FailReason};
        let mut party = party_lock()?;
        let action = party.next_action(party_clock_ms());
        match action {
            Action::Wait => Ok(false),
            Action::Done => {
                for line in party.report() {
                    println!("{line}");
                }
                Ok(true)
            }
            Action::SendInvite { index, name } => {
                let payload = encode_group_invite_target(&name)?;
                println!(
                    "[TELE-06A-PARTY] member={:?} state=INVITE_SENT guard_committed_before_write=true",
                    name
                );
                if let Err(error) = write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    CMSG_GROUP_INVITE_OPCODE,
                    &payload,
                ) {
                    party.on_write_uncertain(index);
                    return Err(format!(
                        "TELE06A_INVITE_MUTATION_UNCERTAIN index={index} target={name:?} retry_allowed=false cause={error}"
                    ));
                }
                println!(
                    "[TELE-06A-INVITE-TX] index={} target={:?} opcode=0x006E mode=sequential result=attempted_once retry_allowed=false",
                    index + 1,
                    name
                );
                Ok(false)
            }
            Action::Fail(reason) => {
                for line in party.report() {
                    println!("{line}");
                }
                if matches!(reason, FailReason::WriteUncertain { .. }) {
                    Err(format!("TELE06A_INVITE_MUTATION_UNCERTAIN {}", reason.describe()))
                } else {
                    Err(format!("TELE06A_ROSTER_TIMEOUT {}", reason.describe()))
                }
            }
        }
    }

    fn party_on_group_list(names: &[String]) {
        if let Ok(mut party) = party_lock() {
            party.on_group_list(names);
        }
    }

    fn party_on_packet(opcode: u16, payload: &[u8]) {
        let Ok(mut party) = party_lock() else { return; };
        if opcode == crate::tele_party_seq::SMSG_PARTY_COMMAND_RESULT_OPCODE {
            match party.on_party_command_result(payload) {
                Ok(parsed) => println!(
                    "[TELE-06A-PARTY] command_result op={} member={:?} result=0x{:02X} {}",
                    parsed.operation,
                    parsed.member,
                    parsed.result,
                    crate::tele_party_seq::party_result_name(parsed.result)
                ),
                Err(error) => println!("[TELE-06A-PARTY-DIAG] command_result parse failed: {error}"),
            }
        } else if opcode == crate::tele_party_seq::SMSG_GROUP_DECLINE_OPCODE {
            match party.on_group_decline(payload) {
                Ok(name) => println!("[TELE-06A-PARTY] group_decline member={name:?}"),
                Err(error) => println!("[TELE-06A-PARTY-DIAG] group_decline parse failed: {error}"),
            }
        }
    }


'@
$s = Regex-Once $s '(?s)    fn send_invite_batch_once\(.*?(?=    fn send_ritual_cast_once\()' (LF $helpers) 'invite batch fn'

# 2b. drop the now-unused one-shot batch guard
$s = Replace-Once $s '    static INVITE_BATCH_ATTEMPTED: AtomicBool = AtomicBool::new(false);
' '' 'batch guard static'

# 3. call site
$s = Replace-Once $s 'send_invite_batch_once(stream, &mut crypto, &invite_targets)?;' 'register_party_sequence(&invite_targets)?;' 'invite call'

# 4. drive loop: roster guid map instead of HashSet gate
$s = Regex-Once $s '(?s)        let expected = expected_members\s*\.iter\(\)\s*\.map\(\|name\| name\.to_ascii_lowercase\(\)\)\s*\.collect::<HashSet<_>>\(\);\n' "        let mut last_roster: HashMap<String, u64> = HashMap::new();`n" 'expected set'
$s = Replace-Once $s 'let roster_deadline = Instant::now() + Duration::from_secs(120);' 'let roster_deadline = Instant::now() + Duration::from_secs(300);' 'roster deadline'
$s = Replace-Once $s 'ritual_target={:?} deadline=120s' 'ritual_target={:?} mode=sequential overall_deadline=300s' 'roster log'

# 5. engine step at loop top (before keepalive bookkeeping)
$s = Replace-Once $s @'
            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("world keepalive pong timeout sequence={sequence}"));
'@ @'
            if cast_deadline.is_none() && party_step(stream, crypto)? {
                let target_guid = *last_roster.get(&target_lower).ok_or_else(|| {
                    format!("target {target_name:?} missing despite roster gate")
                })?;
                println!(
                    "[TELE-06A-ROSTER] PASS target={:?} target_guid=0x{:016X}",
                    target_name, target_guid
                );
                publish_runner_state("ROSTER_PASS", "full roster confirmed sequentially");
                send_ritual_cast_once(stream, crypto, target_name, target_guid)?;
                cast_deadline = Some(Instant::now() + Duration::from_secs(25));
            }

            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("world keepalive pong timeout sequence={sequence}"));
'@ 'engine step'

# 6. GROUP_LIST feeds the engine
$newGroupList = @'
if cast_deadline.is_none() {
                            match roster_from_group_list(&payload) {
                                Ok(roster) => {
                                    let names = roster.keys().cloned().collect::<Vec<_>>();
                                    party_on_group_list(&names);
                                    println!(
                                        "[TELE-06A-ROSTER] observed={} members={:?}",
                                        roster.len(), names
                                    );
                                    last_roster = roster;
                                }
                                Err(error) => println!("[TELE-06A-ROSTER-DIAG] {error}"),
                            }
                        }
'@
$s = Regex-Once $s '(?s)if cast_deadline\.is_none\(\) \{\s*match roster_from_group_list\(&payload\) \{.*?Err\(error\) => println!\("\[TELE-06A-ROSTER-DIAG\] \{error\}"\),\s*\}\s*\}\n' (LF $newGroupList) 'group list branch'

# 7. PARTY_COMMAND_RESULT / GROUP_DECLINE feed the engine (observer still logs them)
$s = Replace-Once $s '                    if crate::tele_party_observer::inspect_party_packet(opcode, &payload) {' @'
                    if cast_deadline.is_none() {
                        party_on_packet(opcode, &payload);
                    }
                    if crate::tele_party_observer::inspect_party_packet(opcode, &payload) {
'@.TrimEnd("`r","`n") 'party packet feed'

foreach ($needle in @('register_party_sequence(&invite_targets)?;','party_step(stream, crypto)?','party_on_group_list(&names);','party_on_packet(opcode, &payload);','publish_runner_state("ROSTER_PASS"','mod tele_party_seq;')) {
    if (-not $s.Contains($needle)) { throw "sequential party patch missing: $needle" }
}
if ($s.Contains('send_invite_batch_once') -or $s.Contains('INVITE_BATCH_ATTEMPTED')) { throw 'old invite batch still present' }
Set-Content -Path $summoner -Value ($s.Replace("`n", "`r`n")) -Encoding UTF8 -NoNewline
Write-Host 'TELE06A SEQUENTIAL PARTY V1.2 PATCH PASS'
