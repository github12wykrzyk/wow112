$ErrorActionPreference = 'Stop'
$runner = 'probes/Wow112HeadlessAndroid/windows/LIVE_TEST_RUNNER.ps1'
$r = Get-Content $runner -Raw

function Require-Replace([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old,$New)
}

# Socket write is not semantic portal success. Rename the control-plane state first
# so every existing completion/timeout branch keeps the same shape but correct meaning.
$r = $r.Replace('PORTAL_USED', 'PORTAL_USE_SENT')

# V1.5 runner identity.
$r = $r.Replace('WoW112 LOCAL LIVE TEST RUNNER V1.3 TELE06B LOGINWATCH', 'WoW112 LOCAL LIVE TEST RUNNER V1.5 TELE06B RANGE-SAFE')
$r = $r.Replace('runner=LIVE_TEST_RUNNER_V1_3_TELE06B_LOGINWATCH', 'runner=LIVE_TEST_RUNNER_V1_5_TELE06B_RANGE_SAFE')

# Parse explicit pre-send range failures even if the child exits immediately after
# publishing them. This keeps FAIL_OUT_OF_RANGE distinct from generic EXITED.
$oldState = @'
        'FAIL_PORTAL_MUTATION_UNCERTAIN' { return [pscustomobject]@{ State='FAIL_PORTAL_MUTATION_UNCERTAIN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
'@
$newState = @'
        'FAIL_PORTAL_MUTATION_UNCERTAIN' { return [pscustomobject]@{ State='FAIL_PORTAL_MUTATION_UNCERTAIN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        'FAIL_PORTAL_OUT_OF_RANGE'       { return [pscustomobject]@{ State='FAIL_PORTAL_OUT_OF_RANGE'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        'FAIL_PORTAL_RANGE_UNKNOWN'      { return [pscustomobject]@{ State='FAIL_PORTAL_RANGE_UNKNOWN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
'@
$r = Require-Replace $r $oldState.Trim() $newState.Trim() 'V1.5 range failure state map'

# Give clickers a conservative, configurable 3D range limit. Stagger sends slightly
# after portal creation to remove the observed sub-20ms race while preserving one-shot mutation.
$oldRole = @'
        } elseif ($Role.Label -eq 'SLAVE1' -or $Role.Label -eq 'SLAVE2') {
            $env:WOW112_TELE06B_ROLE = 'clicker'
        } else {
'@
$newRole = @'
        } elseif ($Role.Label -eq 'SLAVE1' -or $Role.Label -eq 'SLAVE2') {
            $env:WOW112_TELE06B_ROLE = 'clicker'
            $env:WOW112_TELE06B_MAX_RANGE = '5.8'
            if ($Role.Label -eq 'SLAVE1') {
                $env:WOW112_TELE06B_CLICK_SETTLE_MS = '150'
            } else {
                $env:WOW112_TELE06B_CLICK_SETTLE_MS = '300'
            }
        } else {
'@
$r = Require-Replace $r $oldRole.Trim() $newRole.Trim() 'V1.5 clicker range env'

$oldClear = "        'WOW112_RUNNER_STATE_FILE','WOW112_RUNNER_SESSION_ATTEMPT','WOW112_TELE06B_ROLE'"
$newClear = "        'WOW112_RUNNER_STATE_FILE','WOW112_RUNNER_SESSION_ATTEMPT','WOW112_TELE06B_ROLE',`r`n        'WOW112_TELE06B_MAX_RANGE','WOW112_TELE06B_CLICK_SETTLE_MS'"
$r = Require-Replace $r $oldClear $newClear 'V1.5 env cleanup'

# Generalize the terminal clicker failure branch to preserve the exact fail reason.
$oldFailure = @'
            if ($pair.State.State -eq 'FAIL_PORTAL_MUTATION_UNCERTAIN') {
                $FinalCode = 'FAIL_PORTAL_MUTATION_UNCERTAIN'
                $FinalDetail = ("{0}: {1}" -f $pair.Label, $pair.State.Detail)
                Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                break
            }
        }
        if ($FinalCode -eq 'FAIL_PORTAL_MUTATION_UNCERTAIN') { break }
'@
$newFailure = @'
            if (@('FAIL_PORTAL_MUTATION_UNCERTAIN','FAIL_PORTAL_OUT_OF_RANGE','FAIL_PORTAL_RANGE_UNKNOWN') -contains $pair.State.State) {
                $FinalCode = $pair.State.State
                $FinalDetail = ("{0}: {1}" -f $pair.Label, $pair.State.Detail)
                Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                break
            }
        }
        if (@('FAIL_PORTAL_MUTATION_UNCERTAIN','FAIL_PORTAL_OUT_OF_RANGE','FAIL_PORTAL_RANGE_UNKNOWN') -contains $FinalCode) { break }
'@
$r = Require-Replace $r $oldFailure.Trim() $newFailure.Trim() 'V1.5 explicit range failures'

# V1.5 self-test exercises the new state parser contract, not network behavior.
$oldSelf = "    Write-Host 'LIVE TEST RUNNER V1.2 TELE06B SELFTEST PASS'"
$newSelf = @'
    $outOfRange = Parse-RunnerStateText "state=FAIL_PORTAL_OUT_OF_RANGE`nsession=7`ndetail=distance=6.697 max_range=5.800`n"
    if ($outOfRange.State -ne 'FAIL_PORTAL_OUT_OF_RANGE' -or $outOfRange.Session -ne 7) { throw 'SELFTEST V1.5 out-of-range state parser failed' }
    $sent = Parse-RunnerStateText "state=PORTAL_USE_SENT`nsession=7`ndetail=socket write succeeded`n"
    if ($sent.State -ne 'PORTAL_USE_SENT') { throw 'SELFTEST V1.5 portal-use-sent state parser failed' }
    Write-Host 'LIVE TEST RUNNER V1.5 TELE06B RANGE-SAFE SELFTEST PASS'
'@
$r = Require-Replace $r $oldSelf $newSelf.Trim() 'V1.5 runner selftest'

foreach ($needle in @(
    'PORTAL_USE_SENT',
    'FAIL_PORTAL_OUT_OF_RANGE',
    'FAIL_PORTAL_RANGE_UNKNOWN',
    "WOW112_TELE06B_MAX_RANGE = '5.8'",
    "WOW112_TELE06B_CLICK_SETTLE_MS = '150'",
    "WOW112_TELE06B_CLICK_SETTLE_MS = '300'",
    'LIVE TEST RUNNER V1.5 TELE06B RANGE-SAFE'
)) {
    if (-not $r.Contains($needle)) { throw "runner V1.5 marker missing: $needle" }
}
if ($r.Contains('PORTAL_USED')) { throw 'legacy PORTAL_USED runner state survived V1.5 patch' }

Set-Content -Path $runner -Value $r -Encoding UTF8
Write-Host 'RUNNER V1.5 TELE06B RANGE-SAFE PATCH PASS'
