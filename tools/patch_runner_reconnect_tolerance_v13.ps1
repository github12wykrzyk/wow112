$ErrorActionPreference = 'Stop'
$runner = 'probes/Wow112HeadlessAndroid/windows/LIVE_TEST_RUNNER.ps1'
$r = Get-Content $runner -Raw

function Require-Replace([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old,$New)
}

# Retry cadence: the 3s socket/login watchdog is the pacing mechanism. Do not add another 1s sleep.
$oldDelay = @'
$env:WOW112_RECONNECT_DELAY_MS = '1000'
'@
$newDelay = @'
$env:WOW112_RECONNECT_DELAY_MS = '0'
'@
$r = Require-Replace $r $oldDelay.Trim() $newDelay.Trim() 'zero reconnect delay'

$old = @'
        $sumRosterPass = @('ROSTER_PASS','SELECTION_SENT','CAST_SENT','PASS_RITUAL_STARTED','FAIL_SERVER_REJECT') -contains $sumState.State
        if (!$sumRosterPass) {
            foreach ($role in $Roles) {
                $entry = $Managed[$role.Label]
                $state = Get-AcceptorRuntimeState $entry
                if (!$state.Ready) {
                    $FinalCode = 'FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE'
                    $FinalDetail = ("{0} lost current-session readiness before summoner reached ROSTER PASS" -f $role.Label)
                    Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                    break
                }
            }
            if ($FinalCode -eq 'FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE') { break }
        }
'@
$new = @'
        $sumRosterPass = @('ROSTER_PASS','SELECTION_SENT','CAST_SENT','PASS_RITUAL_STARTED','FAIL_SERVER_REJECT') -contains $sumState.State
        if (!$sumRosterPass) {
            foreach ($role in $Roles) {
                $entry = $Managed[$role.Label]
                $state = Get-AcceptorRuntimeState $entry
                if ($entry.LastState -ne $state.State) {
                    Log ("STATE {0}: {1} session={2} detail={3}" -f $role.Label, $state.State, $state.Session, $state.Detail)
                    $entry.LastState = $state.State
                }
                if ($state.State -eq 'EXITED') {
                    $FinalCode = 'FAIL_ACCEPTOR_EXITED'
                    $FinalDetail = ("{0} process exited before summoner reached ROSTER PASS" -f $role.Label)
                    Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                    break
                }
            }
            if ($FinalCode -eq 'FAIL_ACCEPTOR_EXITED') { break }
        }
'@
$r = Require-Replace $r $old.Trim() $new.Trim() 'pre-roster reconnect tolerance'

$r = $r.Replace('WoW112 LOCAL LIVE TEST RUNNER V1.2 TELE06B','WoW112 LOCAL LIVE TEST RUNNER V1.3 TELE06B LOGINWATCH')
$r = $r.Replace('runner=LIVE_TEST_RUNNER_V1_2_TELE06B','runner=LIVE_TEST_RUNNER_V1_3_TELE06B_LOGINWATCH')

if ($r.Contains('FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE')) {
    throw 'obsolete FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE survived V1.3 patch'
}
foreach ($needle in @("WOW112_RECONNECT_DELAY_MS = '0'",'FAIL_ACCEPTOR_EXITED','LIVE TEST RUNNER V1.3 TELE06B LOGINWATCH')) {
    if (-not $r.Contains($needle)) { throw "runner V1.3 marker missing: $needle" }
}

Set-Content -Path $runner -Value $r -Encoding UTF8
Write-Host 'RUNNER V1.3 RECONNECT TOLERANCE PATCH PASS'
