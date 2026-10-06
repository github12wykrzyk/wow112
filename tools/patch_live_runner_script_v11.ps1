$ErrorActionPreference = 'Stop'
$runner = 'probes/Wow112HeadlessAndroid/windows/LIVE_TEST_RUNNER.ps1'
$r = Get-Content $runner -Raw

function Require-Replace([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}

# Version/title markers.
$r = $r.Replace("$Host.UI.RawUI.WindowTitle = 'WoW112 LOCAL LIVE TEST RUNNER'", "$Host.UI.RawUI.WindowTitle = 'WoW112 LOCAL LIVE TEST RUNNER V1.1'")
$r = $r.Replace("runner=LIVE_TEST_RUNNER_V1", "runner=LIVE_TEST_RUNNER_V1_1")
$r = $r.Replace(" WoW112 LOCAL LIVE TEST RUNNER V1'", " WoW112 LOCAL LIVE TEST RUNNER V1.1'")

# State-file parser and state-driven helpers. Keep old log parsers as post-mortem fallback.
$anchor = @'
function Get-LastIndex([string]$Text, [string]$Needle) {
    if ([string]::IsNullOrEmpty($Text)) { return -1 }
    return $Text.LastIndexOf($Needle, [StringComparison]::Ordinal)
}
'@
$insert = @'
function Get-LastIndex([string]$Text, [string]$Needle) {
    if ([string]::IsNullOrEmpty($Text)) { return -1 }
    return $Text.LastIndexOf($Needle, [StringComparison]::Ordinal)
}

function Parse-RunnerStateText([string]$Text) {
    $values = @{}
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($line in ($Text -split "`r?`n")) {
            $idx = $line.IndexOf('=')
            if ($idx -gt 0) {
                $key = $line.Substring(0, $idx).Trim()
                $value = $line.Substring($idx + 1).Trim()
                $values[$key] = $value
            }
        }
    }
    $session = 0
    if ($values.ContainsKey('session')) { [void][int]::TryParse($values['session'], [ref]$session) }
    return [pscustomobject]@{
        State = if ($values.ContainsKey('state')) { $values['state'] } else { 'CONNECTING' }
        Session = $session
        Detail = if ($values.ContainsKey('detail')) { $values['detail'] } else { 'waiting for runtime state file' }
    }
}

function Read-RunnerState($Entry) {
    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Entry.StateFile)) {
        return Parse-RunnerStateText ''
    }
    return Parse-RunnerStateText (Read-AllTextSafe $Entry.StateFile)
}

function Get-AcceptorRuntimeState($Entry) {
    if (Is-Exited $Entry) {
        return [pscustomobject]@{ State='EXITED'; Ready=$false; Session=0; Detail='process exited' }
    }
    $raw = Read-RunnerState $Entry
    switch ($raw.State) {
        'READY'     { return [pscustomobject]@{ State='READY'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'HANDSHAKE' { return [pscustomobject]@{ State='HANDSHAKE'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'ARMED'     { return [pscustomobject]@{ State='ARMED'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        default     { return [pscustomobject]@{ State='CONNECTING'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
    }
}

function Get-SummonerRuntimeVerdict($Entry) {
    $raw = Read-RunnerState $Entry
    switch ($raw.State) {
        'PASS_RITUAL_STARTED' { return [pscustomobject]@{ Done=$true; Code='PASS_RITUAL_STARTED'; Detail=$raw.Detail } }
        'FAIL_SERVER_REJECT'  { return [pscustomobject]@{ Done=$true; Code='FAIL_SERVER_REJECT'; Detail=$raw.Detail } }
        default {
            if (Is-Exited $Entry) {
                # Process is no longer holding redirected logs; use the detailed legacy parser post-mortem.
                return Get-SummonerVerdict (Read-RoleText $Entry) $true
            }
            return [pscustomobject]@{ Done=$false; Code='RUNNING'; Detail=("runtime_state={0} {1}" -f $raw.State, $raw.Detail) }
        }
    }
}
'@
$r = Require-Replace $r $anchor.Trim() $insert.Trim() 'runner state parser insertion'

# Self-test new state parser/gate.
$oldSelf = "    Write-Host 'LIVE TEST RUNNER SELFTEST PASS'"
$newSelf = @'
    $stateReady = Parse-RunnerStateText "state=READY`nsession=3`ndetail=fresh pong sequence=2`n"
    if ($stateReady.State -ne 'READY' -or $stateReady.Session -ne 3) { throw 'SELFTEST runtime state parser failed' }
    $stateConnecting = Parse-RunnerStateText "state=CONNECTING`nsession=4`ndetail=new session attempt`n"
    if ($stateConnecting.State -ne 'CONNECTING' -or $stateConnecting.Session -ne 4) { throw 'SELFTEST reconnect state parser failed' }
    Write-Host 'LIVE TEST RUNNER V1.1 SELFTEST PASS'
'@
$r = Require-Replace $r $oldSelf $newSelf.Trim() 'runner v11 selftest'

# Clear state env too.
$oldClear = "        'WOW112_TELE_AUTO_ACCEPT_FROM','WOW112_TELE_RESET_GROUP','WOW112_TELE_INVITE_LIST','WOW112_RITUAL_TARGET_NAME'"
$newClear = "        'WOW112_TELE_AUTO_ACCEPT_FROM','WOW112_TELE_RESET_GROUP','WOW112_TELE_INVITE_LIST','WOW112_RITUAL_TARGET_NAME',`r`n        'WOW112_RUNNER_STATE_FILE','WOW112_RUNNER_SESSION_ATTEMPT'"
$r = Require-Replace $r $oldClear $newClear 'runner env clear'

# Start-Role: assign dedicated state file before spawning child.
$oldStartPaths = @'
    $stdout = Join-Path $RunDir ("TELE06A_{0}_{1}.log" -f $Role.Label, $Stamp)
    $stderr = Join-Path $RunDir ("TELE06A_{0}_{1}.stderr.log" -f $Role.Label, $Stamp)
    $process = Start-Process -FilePath $exe -WorkingDirectory $Root -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
'@
$newStartPaths = @'
    $stdout = Join-Path $RunDir ("TELE06A_{0}_{1}.log" -f $Role.Label, $Stamp)
    $stderr = Join-Path $RunDir ("TELE06A_{0}_{1}.stderr.log" -f $Role.Label, $Stamp)
    $stateFile = Join-Path $RunDir ("STATE_{0}.txt" -f $Role.Label)
    if (Test-Path $stateFile) { Remove-Item -Force $stateFile }
    $env:WOW112_RUNNER_STATE_FILE = $stateFile
    $process = Start-Process -FilePath $exe -WorkingDirectory $Root -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
'@
$r = Require-Replace $r $oldStartPaths.Trim() $newStartPaths.Trim() 'runner role state path'

$oldEntry = '        Process=$process; Stdout=$stdout; Stderr=$stderr; LastState=''STARTING'''
$newEntry = '        Process=$process; Stdout=$stdout; Stderr=$stderr; StateFile=$stateFile; LastState=''STARTING'''
$r = Require-Replace $r $oldEntry $newEntry 'runner entry state file'

# Verdict state summary should come from state channel while process is alive.
$oldVerdictState = '$state = if ($entry.Type -eq ''acceptor'') { (Get-AcceptorState $text (Is-Exited $entry)).State } else { (Get-SummonerVerdict $text (Is-Exited $entry)).Code }'
$newVerdictState = '$state = if ($entry.Type -eq ''acceptor'') { (Get-AcceptorRuntimeState $entry).State } else { (Get-SummonerRuntimeVerdict $entry).Code }'
$r = Require-Replace $r $oldVerdictState $newVerdictState 'runner verdict state source'

# READY loop: state file only.
$oldReady = '$state = Get-AcceptorState (Read-RoleText $entry) (Is-Exited $entry)'
$newReady = '$state = Get-AcceptorRuntimeState $entry'
$r = $r.Replace($oldReady, $newReady)

# Summoner verdict loop: state file only; use raw state for ROSTER_PASS checkpoint.
$oldSumLoop = @'
        $sumText = Read-RoleText $sumEntry
        $verdict = Get-SummonerVerdict $sumText (Is-Exited $sumEntry)
'@
$newSumLoop = @'
        $sumState = Read-RunnerState $sumEntry
        $verdict = Get-SummonerRuntimeVerdict $sumEntry
'@
$r = Require-Replace $r $oldSumLoop.Trim() $newSumLoop.Trim() 'runner summoner state verdict'

$oldRoster = '$sumRosterPass = $sumText.Contains(''[TELE-06A-ROSTER] PASS'')'
$newRoster = '$sumRosterPass = @(''ROSTER_PASS'',''SELECTION_SENT'',''CAST_SENT'',''PASS_RITUAL_STARTED'',''FAIL_SERVER_REJECT'') -contains $sumState.State'
$r = Require-Replace $r $oldRoster $newRoster 'runner roster checkpoint state'

# Assertions fail closed if active-log control accidentally remains.
if ($r -notmatch 'Get-AcceptorRuntimeState') { throw 'runner runtime acceptor state helper missing' }
if ($r -notmatch 'Get-SummonerRuntimeVerdict') { throw 'runner runtime summoner state helper missing' }
if ($r -notmatch 'WOW112_RUNNER_STATE_FILE') { throw 'runner state env missing' }
if ($r -match '\$sumText = Read-RoleText \$sumEntry') { throw 'runner still tails summoner log for live verdict' }
if ($r -match '\$state = Get-AcceptorState \(Read-RoleText') { throw 'runner still tails acceptor log for live readiness' }

Set-Content -Path $runner -Value $r -Encoding UTF8
Write-Host 'LIVE TEST RUNNER V1.1 SCRIPT PATCH PASS'
