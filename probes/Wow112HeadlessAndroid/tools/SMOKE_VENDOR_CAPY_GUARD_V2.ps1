param(
    [string]$ProductionScript = (Join-Path $PSScriptRoot 'RUN_VENDOR_CAPY_GUARD_WINDOWS.ps1')
)

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "SMOKE FAIL: $Name" }
    Write-Host "[SMOKE] PASS $Name" -ForegroundColor Green
}

function New-ScenarioScript([string]$Scenario, [string]$Dir) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $raw = Get-Content $ProductionScript -Raw
    $marker = 'Load-DbCache\r?\nRead-PasswordOnce\r?\nTest-DbSourceHealth'
    $injection = @'
function Read-PasswordOnce { $env:WOW112_PASSWORD = 'smoke-password' }
function Test-DbSourceHealth {
    $script:CapyHealthy = $true
    $script:TurtleApiHealthy = $true
    $script:TurtleLegacyHealthy = $true
    Write-Host '[SMOKE-MOCK] DB health forced healthy'
}
function Get-ExternalVendorPrice([uint32]$ItemId) {
    switch ($env:SMOKE_SCENARIO) {
        'DB_NONE' { return [pscustomobject]@{ Capy=$null; TurtleApi=$null; TurtleLegacy=$null; Cached=$false } }
        'DB_MISMATCH' { return [pscustomobject]@{ Capy=[uint32]600; TurtleApi=[uint32]601; TurtleLegacy=$null; Cached=$false } }
        default { return [pscustomobject]@{ Capy=[uint32]600; TurtleApi=[uint32]600; TurtleLegacy=$null; Cached=$false } }
    }
}
function Invoke-Headless([string]$LogPath) {
    Apply-GuidCache
    New-Item -ItemType Directory -Force (Split-Path $LogPath -Parent), $stateDir | Out-Null
    $action = [string]$env:WOW112_AUTOBUY_ACTION
    Add-Content -Encoding UTF8 (Join-Path $stateDir 'mock_invocations.txt') ("action={0};ah={1};auction={2};item={3};buyout={4};count={5};unit={6}" -f $action,$env:WOW112_AH_GUID,$env:WOW112_BUY_EXPECT_AUCTION_ID,$env:WOW112_BUY_EXPECT_ITEM_ID,$env:WOW112_BUY_EXPECT_BUYOUT,$env:WOW112_BUY_EXPECT_COUNT,$env:WOW112_BUY_EXPECT_VENDOR_UNIT)

    $lines = New-Object System.Collections.Generic.List[string]
    $code = 0
    if ($action -eq 'scan-only') {
        if ($env:SMOKE_SCENARIO -eq 'AH_FAIL') {
            $lines.Add('[WOW112-ANDROID-PROBE] ERROR: server did not return MSG_AUCTION_HELLO within 512 packets; attempted=2 candidates=2')
            $code = 2
        } else {
            $lines.Add('[AH] MSG_AUCTION_HELLO PASS guid=0xF130003D4100023A house=2 attempted=1 candidates=2')
            $lines.Add('[POC05] context ready after rx[9] auctioneer_candidates=2 mailbox=0xF11002A4A5002A0C')
            switch ($env:SMOKE_SCENARIO) {
                'SCAN_FAIL' { $lines.Add('[WOW112-ANDROID-PROBE] ERROR: synthetic scan failure'); $code = 2 }
                'NO_CANDIDATE' { $lines.Add('[POC07] QUALIFIED candidates=0 showing=0') }
                'PROFIT1' { $lines.Add('[POC07-CANDIDATE] rank=0 page=7 strategy=vendor auction_id=12345 item_id=4306 count=2 buyout=999 (9s99c) unit_value=500 gross_value=1000 expected_profit=1 owner=0x0000000000000001') }
                'BUYOUT_OVER' { $lines.Add('[POC07-CANDIDATE] rank=0 page=7 strategy=vendor auction_id=12345 item_id=4306 count=1 buyout=200001 (20g0s1c) unit_value=200003 gross_value=200003 expected_profit=2 owner=0x0000000000000001') }
                default { $lines.Add('[POC07-CANDIDATE] rank=0 page=7 strategy=vendor auction_id=12345 item_id=4306 count=2 buyout=1000 (10s0c) unit_value=600 gross_value=1200 expected_profit=200 owner=0x0000000000000001') }
            }
        }
    } elseif ($action -eq 'buy-one') {
        $exact = ($env:WOW112_BUY_EXPECT_AUCTION_ID -eq '12345' -and
                  $env:WOW112_BUY_EXPECT_ITEM_ID -eq '4306' -and
                  $env:WOW112_BUY_EXPECT_BUYOUT -eq '1000' -and
                  $env:WOW112_BUY_EXPECT_COUNT -eq '2' -and
                  $env:WOW112_BUY_EXPECT_VENDOR_UNIT -eq '600' -and
                  $env:WOW112_AUTOBUY_MAX_BUYOUT -eq '200000' -and
                  $env:WOW112_AUTOBUY_MIN_PROFIT -eq '2' -and
                  $env:WOW112_AUTOBUY_STRATEGY -eq 'vendor' -and
                  $env:WOW112_AUTOBUY_MAX_PURCHASES -eq '1' -and
                  $env:WOW112_AUTOBUY_CONFIRM -eq 'YES')
        if (-not $exact) {
            $lines.Add('MOCK EXACT TARGET FAIL')
            $code = 81
        } else {
            $lines.Add('[CAPY-GUARD] HARD POLICY PASS VENDOR_ONLY=YES MAX_BUYOUT=200000 MIN_PROFIT=2 HARD_MAX_PURCHASES=1')
            $lines.Add('[CAPY-GUARD] EXACT TARGET PASS auction_id=12345 item_id=4306 buyout=1000 count=2 vendor_unit=600 expected_profit=200')
            $lines.Add('[POC07-BUY] SENT auction_id=12345 price=1000 NO_AUTO_RETRY_FROM_THIS_POINT=YES')
            $lines.Add('[POC07-BUY] SERVER PASS auction_id=12345 action=2 result=0')
            $lines.Add('[POC07-BUY] BUY-ONE PASS purchases=1')
        }
    } else {
        $lines.Add("MOCK unexpected action=$action")
        $code = 82
    }

    $lines | Set-Content -Encoding UTF8 $LogPath
    Learn-GuidCache $LogPath
    Register-AhFailure $LogPath
    return $code
}
'@
    $replacement = $injection + "`r`nLoad-DbCache`r`nRead-PasswordOnce`r`nTest-DbSourceHealth"
    $patched = [regex]::Replace($raw, $marker, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)
    if ($patched -eq $raw) { throw 'SMOKE patch insertion marker not found' }
    $path = Join-Path $Dir 'RUN_VENDOR_CAPY_GUARD_WINDOWS.ps1'
    Set-Content -Encoding UTF8 $path $patched
    return $path
}

function Run-Scenario([string]$Scenario, [bool]$ExpectBuy, [string]$ExpectedDecision) {
    $dir = Join-Path $env:RUNNER_TEMP ("vendor-guard-smoke-" + $Scenario)
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    $script = New-ScenarioScript $Scenario $dir
    $env:SMOKE_SCENARIO = $Scenario
    $env:WOW112_PASSWORD = 'smoke-password'
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script -Once | Tee-Object -FilePath (Join-Path $dir 'console.txt')
    Assert-True ($LASTEXITCODE -eq 0) "$Scenario process exit=0"

    $ledgerPath = Join-Path $dir 'state/vendor_buy_ledger.csv'
    Assert-True (Test-Path $ledgerPath) "$Scenario ledger exists"
    $ledger = @(Import-Csv $ledgerPath)
    Assert-True (($ledger.Decision -contains $ExpectedDecision)) "$Scenario ledger decision=$ExpectedDecision"

    $invPath = Join-Path $dir 'state/mock_invocations.txt'
    Assert-True (Test-Path $invPath) "$Scenario invocation trace exists"
    $inv = @(Get-Content $invPath)
    $buyCount = @($inv | Where-Object { $_ -match '^action=buy-one;' }).Count
    if ($ExpectBuy) {
        Assert-True ($buyCount -eq 1) "$Scenario exactly one BUY invocation"
        Assert-True (($ledger.Decision -contains 'DB_PASS')) "$Scenario DB_PASS before BUY"
        Assert-True (($ledger.Decision -contains 'BUY_CONFIRMED')) "$Scenario BUY_CONFIRMED"
        Assert-True ((Get-Content (Join-Path $dir 'state/ah_guid.txt') -Raw).Trim() -eq '0xF130003D4100023A') "$Scenario learned AH GUID"
        Assert-True ((Get-Content (Join-Path $dir 'state/mailbox_guid.txt') -Raw).Trim() -eq '0xF11002A4A5002A0C') "$Scenario learned mailbox GUID"
    } else {
        Assert-True ($buyCount -eq 0) "$Scenario zero BUY invocations"
    }
}

Write-Host '[SMOKE] production self-test' -ForegroundColor Cyan
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ProductionScript -SelfTest
Assert-True ($LASTEXITCODE -eq 0) 'production -SelfTest exit=0'

Run-Scenario 'SCAN_FAIL' $false 'SCAN_FAIL'
Run-Scenario 'NO_CANDIDATE' $false 'NO_CANDIDATE'
Run-Scenario 'PROFIT1' $false 'NO_DB_VERIFIED_CANDIDATE'
Run-Scenario 'BUYOUT_OVER' $false 'NO_DB_VERIFIED_CANDIDATE'
Run-Scenario 'DB_NONE' $false 'NO_DB_VERIFIED_CANDIDATE'
Run-Scenario 'DB_MISMATCH' $false 'NO_DB_VERIFIED_CANDIDATE'
Run-Scenario 'BUY_PASS' $true 'BUY_CONFIRMED'

# Repeated AH failure must invalidate a previously learned/seeded GUID after 3 failures.
$dir = Join-Path $env:RUNNER_TEMP 'vendor-guard-smoke-ahfail'
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
$script = New-ScenarioScript 'AH_FAIL' $dir
New-Item -ItemType Directory -Force (Join-Path $dir 'state') | Out-Null
'0xF130003D4100023A' | Set-Content -Encoding ascii (Join-Path $dir 'state/ah_guid.txt')
'0' | Set-Content -Encoding ascii (Join-Path $dir 'state/ah_guid_failures.txt')
$env:SMOKE_SCENARIO = 'AH_FAIL'
$env:WOW112_PASSWORD = 'smoke-password'
1..3 | ForEach-Object {
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script -Once | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) "AH_FAIL iteration $_ process exit=0"
    if ($_ -lt 3) { Assert-True (Test-Path (Join-Path $dir 'state/ah_guid.txt')) "AH_FAIL iteration $_ keeps GUID before threshold" }
}
Assert-True (-not (Test-Path (Join-Path $dir 'state/ah_guid.txt'))) 'AH_FAIL third failure clears stale AH GUID'
Assert-True (((Get-Content (Join-Path $dir 'state/ah_guid_failures.txt') -Raw).Trim()) -eq '0') 'AH_FAIL counter resets after invalidation'

# Real external endpoints: Turtle JSON is mandatory for this probe; Capy is best-effort
# because production intentionally tolerates one source being unavailable.
Write-Host '[SMOKE] live external DB probe item=4306' -ForegroundColor Cyan
$prod = Get-Content $ProductionScript -Raw
$mainMarker = [regex]::Match($prod, '(?m)^Load-DbCache\r?\nRead-PasswordOnce\r?\nTest-DbSourceHealth\r?$')
Assert-True $mainMarker.Success 'library extraction marker exists'
$lib = $prod.Substring(0, $mainMarker.Index)
$libPath = Join-Path $env:RUNNER_TEMP 'vendor-guard-functions-only.ps1'
Set-Content -Encoding UTF8 $libPath $lib
. $libPath
$headers = @{ 'User-Agent' = 'Mozilla/5.0 WoW112VendorGuard/2.0' }
$turtleText = [string](Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Headers $headers -Uri 'https://api.tortoiseclothing.org/i/4306').Content
$turtlePrice = Convert-TurtleJsonToCopper $turtleText
Assert-True ($null -ne $turtlePrice -and [uint32]$turtlePrice -gt 0) "Turtle JSON live price parsed ($turtlePrice c)"
try {
    $capyText = [string](Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Headers $headers -Uri 'https://db.capycraft.org/item/4306').Content
    $capyPrice = Convert-HtmlMoneyToCopper $capyText 'Sells for'
    Assert-True ($null -ne $capyPrice -and [uint32]$capyPrice -gt 0) "Capy live price parsed ($capyPrice c)"
    Assert-True ([uint32]$capyPrice -eq [uint32]$turtlePrice) "Capy/Turtle live agreement item=4306 ($capyPrice c)"
} catch {
    Write-Host "[SMOKE] WARN Capy live endpoint unavailable/unparseable: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host '[SMOKE] ALL DETERMINISTIC TESTS PASS' -ForegroundColor Green
