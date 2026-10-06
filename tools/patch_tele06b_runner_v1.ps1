$ErrorActionPreference = 'Stop'
$runner = 'probes/Wow112HeadlessAndroid/windows/LIVE_TEST_RUNNER.ps1'
$r = Get-Content $runner -Raw

function Require-Replace([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}

# Version markers only; do not rename runtime protocol states.
$r = $r.Replace("WoW112 LOCAL LIVE TEST RUNNER V1.1", "WoW112 LOCAL LIVE TEST RUNNER V1.2 TELE06B")
$r = $r.Replace("runner=LIVE_TEST_RUNNER_V1_1", "runner=LIVE_TEST_RUNNER_V1_2_TELE06B")

$oldAcceptorState = @'
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
'@
$newAcceptorState = @'
function Get-AcceptorRuntimeState($Entry) {
    $raw = Read-RunnerState $Entry
    switch ($raw.State) {
        'READY'                          { return [pscustomobject]@{ State='READY'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'HANDSHAKE'                      { return [pscustomobject]@{ State='HANDSHAKE'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'PORTAL_WAIT'                    { return [pscustomobject]@{ State='PORTAL_WAIT'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'WAIT_SUMMON_REQUEST'            { return [pscustomobject]@{ State='WAIT_SUMMON_REQUEST'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'PORTAL_USE_COMMITTED'           { return [pscustomobject]@{ State='PORTAL_USE_COMMITTED'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'PORTAL_USED'                    { return [pscustomobject]@{ State='PORTAL_USED'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'PASS_RITUAL_COMPLETE'           { return [pscustomobject]@{ State='PASS_RITUAL_COMPLETE'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'FAIL_PORTAL_MUTATION_UNCERTAIN' { return [pscustomobject]@{ State='FAIL_PORTAL_MUTATION_UNCERTAIN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        'ARMED'                          { return [pscustomobject]@{ State='ARMED'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        default {
            if (Is-Exited $Entry) {
                return [pscustomobject]@{ State='EXITED'; Ready=$false; Session=$raw.Session; Detail='process exited' }
            }
            return [pscustomobject]@{ State='CONNECTING'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail }
        }
    }
}
'@
$r = Require-Replace $r $oldAcceptorState.Trim() $newAcceptorState.Trim() 'TELE06B acceptor state map'

# Role assignment: customer observes completion; exactly two slaves click the portal.
$oldAcceptorEnv = @'
    if ($Role.Type -eq 'acceptor') {
        $env:WOW112_TELE_AUTO_ACCEPT_FROM = $Summoner.Character
    } else {
'@
$newAcceptorEnv = @'
    if ($Role.Type -eq 'acceptor') {
        $env:WOW112_TELE_AUTO_ACCEPT_FROM = $Summoner.Character
        if ($Role.Label -eq 'CUSTOMER') {
            $env:WOW112_TELE06B_ROLE = 'customer'
        } elseif ($Role.Label -eq 'SLAVE1' -or $Role.Label -eq 'SLAVE2') {
            $env:WOW112_TELE06B_ROLE = 'clicker'
        } else {
            $env:WOW112_TELE06B_ROLE = 'observer'
        }
    } else {
'@
$r = Require-Replace $r $oldAcceptorEnv.Trim() $newAcceptorEnv.Trim() 'TELE06B role env'

$oldClear = "        'WOW112_RUNNER_STATE_FILE','WOW112_RUNNER_SESSION_ATTEMPT'"
$newClear = "        'WOW112_RUNNER_STATE_FILE','WOW112_RUNNER_SESSION_ATTEMPT','WOW112_TELE06B_ROLE'"
$r = Require-Replace $r $oldClear $newClear 'TELE06B env cleanup'

# V1.2 completion state machine. PASS_RITUAL_STARTED is now only a checkpoint.
$oldLoop = @'
    while ((Get-Date) -lt $deadline) {
        $sumState = Read-RunnerState $sumEntry
        $verdict = Get-SummonerRuntimeVerdict $sumEntry
        if ($verdict.Done) {
            $FinalCode = $verdict.Code
            $FinalDetail = $verdict.Detail
            Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
            break
        }

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
        Start-Sleep -Milliseconds 500
    }
'@
$newLoop = @'
    $ritualStarted = $false
    $portalDeadline = $null
    while ((Get-Date) -lt $deadline) {
        $sumState = Read-RunnerState $sumEntry
        $verdict = Get-SummonerRuntimeVerdict $sumEntry
        if ($verdict.Done) {
            if ($verdict.Code -eq 'PASS_RITUAL_STARTED') {
                if (!$ritualStarted) {
                    $ritualStarted = $true
                    $portalDeadline = (Get-Date).AddSeconds(45)
                    Log ("CHECKPOINT PASS_RITUAL_STARTED: {0}; waiting for two portal uses + SMSG_SUMMON_REQUEST" -f $verdict.Detail)
                }
            } else {
                $FinalCode = $verdict.Code
                $FinalDetail = $verdict.Detail
                Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                break
            }
        }

        $customerState = Get-AcceptorRuntimeState $Managed['CUSTOMER']
        $slave1State = Get-AcceptorRuntimeState $Managed['SLAVE1']
        $slave2State = Get-AcceptorRuntimeState $Managed['SLAVE2']

        foreach ($pair in @(
            [pscustomobject]@{ Label='SLAVE1'; State=$slave1State },
            [pscustomobject]@{ Label='SLAVE2'; State=$slave2State }
        )) {
            if ($pair.State.State -eq 'FAIL_PORTAL_MUTATION_UNCERTAIN') {
                $FinalCode = 'FAIL_PORTAL_MUTATION_UNCERTAIN'
                $FinalDetail = ("{0}: {1}" -f $pair.Label, $pair.State.Detail)
                Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                break
            }
        }
        if ($FinalCode -eq 'FAIL_PORTAL_MUTATION_UNCERTAIN') { break }

        if ($customerState.State -eq 'PASS_RITUAL_COMPLETE') {
            if ($slave1State.State -eq 'PORTAL_USED' -and $slave2State.State -eq 'PORTAL_USED') {
                $FinalCode = 'PASS_RITUAL_COMPLETE'
                $FinalDetail = ("server SMSG_SUMMON_REQUEST confirmed after SLAVE1+SLAVE2 portal use; {0}" -f $customerState.Detail)
                Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                break
            }
            Log ("COMPLETION observed before runner saw both PORTAL_USED states; waiting for state-file convergence")
        }

        if ($ritualStarted -and $null -ne $portalDeadline -and (Get-Date) -ge $portalDeadline) {
            if ($slave1State.State -ne 'PORTAL_USED' -or $slave2State.State -ne 'PORTAL_USED') {
                $FinalCode = 'FAIL_PORTAL_TIMEOUT'
                $FinalDetail = ("45s after ritual start: SLAVE1={0} SLAVE2={1}" -f $slave1State.State, $slave2State.State)
            } else {
                $FinalCode = 'FAIL_COMPLETION_TIMEOUT'
                $FinalDetail = ("both portal uses were sent but CUSTOMER did not receive SMSG_SUMMON_REQUEST/0x02AB within 45s; CUSTOMER={0}" -f $customerState.State)
            }
            Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
            break
        }

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

        foreach ($entry in @($Managed['CUSTOMER'],$Managed['SLAVE1'],$Managed['SLAVE2'])) {
            $state = Get-AcceptorRuntimeState $entry
            if ($state.State -eq 'EXITED') {
                $FinalCode = 'FAIL_ACCEPTOR_EXITED'
                $FinalDetail = ("{0} exited during TELE06B completion phase" -f $entry.Label)
                Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                break
            }
        }
        if ($FinalCode -eq 'FAIL_ACCEPTOR_EXITED') { break }

        Start-Sleep -Milliseconds 250
    }
'@
$r = Require-Replace $r $oldLoop.Trim() $newLoop.Trim() 'TELE06B completion loop'

# Overall timeout text now reflects completion, not merely ritual start.
$r = $r.Replace('no terminal ritual verdict within $TimeoutMinutes minutes', 'no terminal TELE06B completion verdict within $TimeoutMinutes minutes')

# Extend self-test with TELE06B state parser contract.
$oldSelfPass = "    Write-Host 'LIVE TEST RUNNER V1.1 SELFTEST PASS'"
$newSelfPass = @'
    $portalUsed = Parse-RunnerStateText "state=PORTAL_USED`nsession=5`ndetail=guid=0x1234`n"
    if ($portalUsed.State -ne 'PORTAL_USED' -or $portalUsed.Session -ne 5) { throw 'SELFTEST TELE06B portal state parser failed' }
    $complete = Parse-RunnerStateText "state=PASS_RITUAL_COMPLETE`nsession=5`ndetail=SMSG_SUMMON_REQUEST opcode=0x02AB`n"
    if ($complete.State -ne 'PASS_RITUAL_COMPLETE') { throw 'SELFTEST TELE06B completion state parser failed' }
    Write-Host 'LIVE TEST RUNNER V1.2 TELE06B SELFTEST PASS'
'@
$r = Require-Replace $r $oldSelfPass $newSelfPass.Trim() 'TELE06B selftest'

$oldColor = "Write-Host ('VERDICT: ' + $FinalCode) -ForegroundColor $(if ($FinalCode -eq 'PASS_RITUAL_STARTED') { 'Green' } else { 'Yellow' })"
$newColor = "Write-Host ('VERDICT: ' + $FinalCode) -ForegroundColor $(if ($FinalCode -eq 'PASS_RITUAL_COMPLETE') { 'Green' } else { 'Yellow' })"
$r = Require-Replace $r $oldColor $newColor 'TELE06B verdict color'

$oldExit = "if ($FinalCode -eq 'PASS_RITUAL_STARTED') { exit 0 }"
$newExit = "if ($FinalCode -eq 'PASS_RITUAL_COMPLETE') { exit 0 }"
$r = Require-Replace $r $oldExit $newExit 'TELE06B success exit'

# Fail closed if V1.2 control-plane markers drift.
foreach ($needle in @(
    'WOW112_TELE06B_ROLE',
    'PORTAL_USED',
    'PASS_RITUAL_COMPLETE',
    'FAIL_PORTAL_TIMEOUT',
    'FAIL_COMPLETION_TIMEOUT',
    'SMSG_SUMMON_REQUEST',
    'waiting for two portal uses'
)) {
    if (-not $r.Contains($needle)) { throw "TELE06B runner patch missing: $needle" }
}

Set-Content -Path $runner -Value $r -Encoding UTF8
Write-Host 'LIVE RUNNER V1.2 TELE06B PATCH PASS'
