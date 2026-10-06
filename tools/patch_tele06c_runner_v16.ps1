$ErrorActionPreference = 'Stop'
$runner = 'probes/Wow112HeadlessAndroid/windows/LIVE_TEST_RUNNER.ps1'
$r = Get-Content $runner -Raw

function Require-Replace([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old,$New)
}

$r = $r.Replace('WoW112 LOCAL LIVE TEST RUNNER V1.5 TELE06B RANGE-SAFE', 'WoW112 LOCAL LIVE TEST RUNNER V1.6 TELE06C AUTO-POSITION')
$r = $r.Replace('runner=LIVE_TEST_RUNNER_V1_5_TELE06B_RANGE_SAFE', 'runner=LIVE_TEST_RUNNER_V1_6_TELE06C_AUTO_POSITION')

$oldState = @'
        'FAIL_PORTAL_RANGE_UNKNOWN'      { return [pscustomobject]@{ State='FAIL_PORTAL_RANGE_UNKNOWN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
'@
$newState = @'
        'FAIL_PORTAL_RANGE_UNKNOWN'      { return [pscustomobject]@{ State='FAIL_PORTAL_RANGE_UNKNOWN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        'AUTO_POSITIONING'               { return [pscustomobject]@{ State='AUTO_POSITIONING'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'AUTO_POSITION_SENT'             { return [pscustomobject]@{ State='AUTO_POSITION_SENT'; Ready=$true; Session=$raw.Session; Detail=$raw.Detail } }
        'FAIL_AUTO_POSITION_LIMIT'       { return [pscustomobject]@{ State='FAIL_AUTO_POSITION_LIMIT'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        'FAIL_AUTO_POSITION_UNCERTAIN'   { return [pscustomobject]@{ State='FAIL_AUTO_POSITION_UNCERTAIN'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
        'FAIL_AUTO_POSITION_ALREADY_ATTEMPTED' { return [pscustomobject]@{ State='FAIL_AUTO_POSITION_ALREADY_ATTEMPTED'; Ready=$false; Session=$raw.Session; Detail=$raw.Detail } }
'@
$r = Require-Replace $r $oldState.Trim() $newState.Trim() 'V1.6 movement states'

$oldFailureList = "@('FAIL_PORTAL_MUTATION_UNCERTAIN','FAIL_PORTAL_OUT_OF_RANGE','FAIL_PORTAL_RANGE_UNKNOWN')"
$newFailureList = "@('FAIL_PORTAL_MUTATION_UNCERTAIN','FAIL_PORTAL_OUT_OF_RANGE','FAIL_PORTAL_RANGE_UNKNOWN','FAIL_AUTO_POSITION_LIMIT','FAIL_AUTO_POSITION_UNCERTAIN','FAIL_AUTO_POSITION_ALREADY_ATTEMPTED')"
if (-not $r.Contains($oldFailureList)) { throw 'missing V1.5 failure list anchor' }
$r = $r.Replace($oldFailureList, $newFailureList)

$oldSelf = "    Write-Host 'LIVE TEST RUNNER V1.5 TELE06B RANGE-SAFE SELFTEST PASS'"
$newSelf = @'
    $moving = Parse-RunnerStateText "state=AUTO_POSITIONING`nsession=8`ndetail=steps=2`n"
    if ($moving.State -ne 'AUTO_POSITIONING' -or -not $moving.Ready) { throw 'SELFTEST V1.6 auto-positioning parser failed' }
    $moveSent = Parse-RunnerStateText "state=AUTO_POSITION_SENT`nsession=8`ndetail=server acceptance unconfirmed`n"
    if ($moveSent.State -ne 'AUTO_POSITION_SENT' -or -not $moveSent.Ready) { throw 'SELFTEST V1.6 auto-position-sent parser failed' }
    $moveFail = Parse-RunnerStateText "state=FAIL_AUTO_POSITION_LIMIT`nsession=8`ndetail=move_needed=4.200`n"
    if ($moveFail.State -ne 'FAIL_AUTO_POSITION_LIMIT' -or $moveFail.Ready) { throw 'SELFTEST V1.6 auto-position-limit parser failed' }
    Write-Host 'LIVE TEST RUNNER V1.6 TELE06C AUTO-POSITION SELFTEST PASS'
'@
$r = Require-Replace $r $oldSelf $newSelf.Trim() 'V1.6 runner selftest'

foreach ($needle in @(
    'AUTO_POSITIONING',
    'AUTO_POSITION_SENT',
    'FAIL_AUTO_POSITION_LIMIT',
    'FAIL_AUTO_POSITION_UNCERTAIN',
    'FAIL_AUTO_POSITION_ALREADY_ATTEMPTED',
    'LIVE TEST RUNNER V1.6 TELE06C AUTO-POSITION'
)) {
    if (-not $r.Contains($needle)) { throw "runner V1.6 marker missing: $needle" }
}

Set-Content -Path $runner -Value $r -Encoding UTF8
Write-Host 'RUNNER V1.6 TELE06C AUTO-POSITION PATCH PASS'
