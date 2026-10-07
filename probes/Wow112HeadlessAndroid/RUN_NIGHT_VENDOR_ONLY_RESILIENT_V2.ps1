param(
    [string]$Account = '',
    [string]$Character = '',
    [int]$RealmIndex = 1,
    [string]$StopAt = '08:00',
    [int]$VendorMinProfitCopper = 100,
    [int]$MaxSingleBuyoutCopper = 150000,
    [int]$PostBuySleepSeconds = 20,
    [int]$NoopSleepSeconds = 45,
    [int]$RecoveryBaseSeconds = 10,
    [int]$RecoveryMaxSeconds = 180
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'wow112-ah-windows.exe'
if (-not (Test-Path $exe)) { Write-Host 'ERROR: wow112-ah-windows.exe not found.' -ForegroundColor Red; exit 2 }
if ($VendorMinProfitCopper -lt 1) { Write-Host 'ERROR: VendorMinProfitCopper must be >= 1.' -ForegroundColor Red; exit 2 }
if ($MaxSingleBuyoutCopper -lt 1) { Write-Host 'ERROR: MaxSingleBuyoutCopper must be >= 1.' -ForegroundColor Red; exit 2 }
if ($PostBuySleepSeconds -lt 0 -or $NoopSleepSeconds -lt 0) { Write-Host 'ERROR: sleep values must be >= 0.' -ForegroundColor Red; exit 2 }
if ($RecoveryBaseSeconds -lt 1 -or $RecoveryMaxSeconds -lt $RecoveryBaseSeconds) { Write-Host 'ERROR: invalid recovery backoff values.' -ForegroundColor Red; exit 2 }

if ([string]::IsNullOrWhiteSpace($Account)) {
    $Account = Read-Host 'Login WoW [Enter=octowar1]'
    if ([string]::IsNullOrWhiteSpace($Account)) { $Account = 'octowar1' }
}
if ([string]::IsNullOrWhiteSpace($Character)) {
    $Character = Read-Host 'Postac [Enter=Smokinpole]'
    if ([string]::IsNullOrWhiteSpace($Character)) { $Character = 'Smokinpole' }
}

try {
    $parts = $StopAt.Split(':')
    if ($parts.Count -ne 2) { throw 'bad format' }
    $stopHour = [int]$parts[0]
    $stopMinute = [int]$parts[1]
    if ($stopHour -lt 0 -or $stopHour -gt 23 -or $stopMinute -lt 0 -or $stopMinute -gt 59) { throw 'bad time' }
} catch {
    Write-Host 'ERROR: StopAt must be HH:mm, e.g. 08:00' -ForegroundColor Red
    exit 2
}
$now = Get-Date
$stopTime = Get-Date -Hour $stopHour -Minute $stopMinute -Second 0
if ($stopTime -le $now) { $stopTime = $stopTime.AddDays(1) }

$sessionStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$status = Join-Path $PSScriptRoot ('STATUS_VENDOR_NIGHT_V2_' + $sessionStamp + '.log')

function Status([string]$Text) {
    ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) | Tee-Object -FilePath $status -Append | Write-Host
}

function Clear-Arm {
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
}

function Get-AuctionIds([string]$Path, [string]$Marker) {
    $ids = @()
    $rows = @(Select-String -Path $Path -Pattern $Marker -SimpleMatch -ErrorAction SilentlyContinue)
    foreach ($row in $rows) {
        if ($row.Line -match 'auction_id=(\d+)') { $ids += [string]$Matches[1] }
    }
    return @($ids)
}

function Test-SameAuctionIds($A, $B) {
    $aa = @($A)
    $bb = @($B)
    if ($aa.Count -ne $bb.Count) { return $false }
    if ($aa.Count -eq 0) { return $true }
    $diff = @(Compare-Object -ReferenceObject @($aa | Sort-Object) -DifferenceObject @($bb | Sort-Object))
    return ($diff.Count -eq 0)
}

function Get-LastErrorSummary([string]$Path) {
    $line = (Select-String -Path $Path -Pattern '[WOW112-ANDROID-PROBE] ERROR:' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -Last 1).Line
    if ([string]::IsNullOrWhiteSpace($line)) {
        $line = (Select-String -Path $Path -Pattern 'ERROR:' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -Last 1).Line
    }
    if ([string]::IsNullOrWhiteSpace($line)) { return 'no explicit ERROR marker' }
    if ($line.Length -gt 220) { return $line.Substring(0,220) }
    return $line
}

function Get-RecoveryDelay([int]$Consecutive) {
    $exp = [Math]::Min([Math]::Max(0, $Consecutive - 1), 8)
    $raw = [double]$RecoveryBaseSeconds * [Math]::Pow(2, $exp)
    $base = [int][Math]::Min([double]$RecoveryMaxSeconds, $raw)
    $jitter = Get-Random -Minimum 0 -Maximum 6
    return [int][Math]::Min([double]$RecoveryMaxSeconds, [double]($base + $jitter))
}

$env:WOW112_ACCOUNT=$Account
$env:WOW112_CHARACTER=$Character
$env:WOW112_REALM_INDEX=[string]$RealmIndex
$env:WOW112_SOAK_SECONDS='0'

# No opaque retry inside Rust. Outer supervisor may retry only at a proven safe boundary.
$env:WOW112_RECONNECT_LIMIT='1'
$env:WOW112_RECONNECT_DELAY_MS='0'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_AH_FULL_SCAN_MAX_PAGES='2048'

# Legacy primitive sentinel remains exactly one.
$env:WOW112_AUTOBUY_MAX_PURCHASES='1'
$env:WOW112_AUTOBUY_MAX_BUYOUT=[string]$MaxSingleBuyoutCopper
$env:WOW112_AUTOBUY_MIN_PROFIT=[string]$VendorMinProfitCopper
$env:WOW112_F0_HARD_MAX_SINGLE_BUYOUT=[string]$MaxSingleBuyoutCopper
$env:WOW112_F1_HARD_MAX_SINGLE_BUYOUT=[string]$MaxSingleBuyoutCopper
$env:WOW112_F1_MIN_VENDOR_PROFIT=[string]$VendorMinProfitCopper

# HARD Vendor-only route lock + redundant DE=0 guard.
$env:WOW112_F1_ACTION='vendor-best'
$env:WOW112_UNIFIED_DE_MAX_PURCHASES='0'

# DE remains audit-only inside this binary; it can never enter the live queue here.
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_ITEM_QUERY_WINDOW='64'
$env:WOW112_MATERIAL_HISTORY_PATH=(Join-Path $PSScriptRoot 'POC08_MATERIAL_HISTORY.csv')
$env:WOW112_DE_MIN_SAFE_PROFIT='500'
$env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'
$env:WOW112_DE_MAX_PLOSS_BPS='4000'
$env:WOW112_F0_MIN_SAFE_PROFIT='500'
$env:WOW112_F0_MIN_SAFE_ROI_BPS='2000'
$env:WOW112_F0_MAX_PLOSS_BPS='4000'
$env:WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS='0'
$env:WOW112_F0_MIN_EDGE_VS_VENDOR='0'
$env:WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS='0'

$env:WOW112_ECONOMY_CANDIDATE_EXPORT=(Join-Path $PSScriptRoot 'VENDOR_NIGHT_CANDIDATES.csv')
$env:WOW112_ECONOMY_REJECTED_EXPORT=(Join-Path $PSScriptRoot 'VENDOR_NIGHT_REJECTED.csv')
$env:WOW112_MATERIAL_BOOK_EXPORT=(Join-Path $PSScriptRoot 'VENDOR_NIGHT_MATERIAL_BOOK.csv')
$env:WOW112_F0_ELIGIBLE_EXPORT=(Join-Path $PSScriptRoot 'VENDOR_NIGHT_DE_AUDIT_ONLY.csv')
$env:WOW112_DE_PROVENANCE_EXPORT=(Join-Path $PSScriptRoot 'VENDOR_NIGHT_DE_PROVENANCE_AUDIT_ONLY.csv')

Write-Host '=================================================================='
Write-Host 'WoW112 AH - NIGHT VENDOR ONLY / RESILIENT SUPERVISOR V2'
Write-Host ('STOP: {0}' -f $stopTime.ToString('yyyy-MM-dd HH:mm'))
Write-Host ('Vendor min guaranteed profit: {0}c' -f $VendorMinProfitCopper)
Write-Host ('Max single buyout: {0}c' -f $MaxSingleBuyoutCopper)
Write-Host 'DE BUY: HARD DISABLED (action=vendor-best + de_limit=0).'
Write-Host 'BUY safety: SENT -> SERVER PASS -> CONFIRMED exact auction_id set must match.'
Write-Host 'Every BUY: exact tuple revalidation +/-5 pages.'
Write-Host 'STALE: skip. Uncertain post-SEND state: HARD STOP, no retry.'
Write-Host ('Recovery backoff: exponential {0}s -> max {1}s (+ small jitter).' -f $RecoveryBaseSeconds,$RecoveryMaxSeconds)
Write-Host ('Healthy sleeps: post-buy={0}s, NOOP={1}s.' -f $PostBuySleepSeconds,$NoopSleepSeconds)
Write-Host '=================================================================='
Write-Host ''

Write-Host 'UWAGA: realne zakupy Vendor beda wykonywane do czasu StopAt.' -ForegroundColor Yellow
$arm = Read-Host 'Type VENDOR to arm overnight Vendor-only loop'
if ($arm -cne 'VENDOR') { Status 'USER DECLINED; zero mutation'; exit 0 }

$env:WOW112_F1_LIVE_CONFIRM='BUY_ONE_NOW'
$env:WOW112_AUTOBUY_CONFIRM='YES'

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    $cycle = 0
    $consecutiveRecoveries = 0
    $totalRecoveries = 0
    $totalPasses = 0
    $totalNoops = 0
    $totalConfirmedBuys = 0

    Status ('V2 START stop_at={0} vendor_min={1}c max_single={2}c de_buy=DISABLED exact_id_chain=ENABLED backoff={3}-{4}s' -f $stopTime.ToString('yyyy-MM-dd HH:mm'),$VendorMinProfitCopper,$MaxSingleBuyoutCopper,$RecoveryBaseSeconds,$RecoveryMaxSeconds)

    while ((Get-Date) -lt $stopTime) {
        $cycle++
        $cycleStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $log = Join-Path $PSScriptRoot ('VENDOR_NIGHT_V2_CYCLE_{0:D3}_{1}.log' -f $cycle,$cycleStamp)
        Status ('CYCLE {0} START fresh login/full scan' -f $cycle)

        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $exe 2>&1 | Tee-Object -FilePath $log
        $code=$LASTEXITCODE
        $ErrorActionPreference = $oldEap

        if (Select-String -Path $log -Pattern 'AH_MUTATION_UNCERTAIN' -SimpleMatch -Quiet) {
            Status ('HARD STOP cycle={0}: AH_MUTATION_UNCERTAIN; DO NOT AUTO-RETRY' -f $cycle)
            Write-Host 'STOP: mutation state UNCERTAIN. Inspect AH/mail before rerun.' -ForegroundColor Red
            exit 3
        }

        $deTry = Select-String -Path $log -Pattern '[POC08-UNIFIED-MULTI] TRY' -SimpleMatch -ErrorAction SilentlyContinue | Where-Object { $_.Line -like '*route=de*' } | Select-Object -First 1
        if ($null -ne $deTry) {
            Status ('HARD STOP cycle={0}: impossible DE route marker detected; {1}' -f $cycle,$deTry.Line)
            Write-Host 'STOP: DE route marker detected despite Vendor-only lock.' -ForegroundColor Red
            exit 4
        }

        $sentIds = @(Get-AuctionIds -Path $log -Marker '[POC07-BUY] SENT')
        $serverIds = @(Get-AuctionIds -Path $log -Marker '[POC07-BUY] SERVER PASS')
        $confirmedIds = @(Get-AuctionIds -Path $log -Marker '[POC08-UNIFIED-MULTI] CONFIRMED')
        $sent = $sentIds.Count
        $server = $serverIds.Count
        $confirmed = $confirmedIds.Count

        $sentServerOk = Test-SameAuctionIds $sentIds $serverIds
        $sentConfirmedOk = Test-SameAuctionIds $sentIds $confirmedIds
        if (-not $sentServerOk -or -not $sentConfirmedOk) {
            $missingServer = @($sentIds | Where-Object { $_ -notin $serverIds }) -join ','
            $missingConfirmed = @($sentIds | Where-Object { $_ -notin $confirmedIds }) -join ','
            Status ('HARD STOP cycle={0}: BUY ID chain mismatch sent={1} server={2} confirmed={3} missing_server=[{4}] missing_confirmed=[{5}] exit={6}' -f $cycle,$sent,$server,$confirmed,$missingServer,$missingConfirmed,$code)
            Write-Host 'STOP: at least one BUY lacks exact SERVER PASS/CONFIRMED reconciliation. No retry.' -ForegroundColor Red
            exit 3
        }

        $cleanPass = Select-String -Path $log -Pattern '[POC08-UNIFIED-MULTI] LIVE PASS' -SimpleMatch -Quiet
        $cleanNoop = Select-String -Path $log -Pattern '[POC08-UNIFIED] NO_ELIGIBLE_LIVE_ROUTE' -SimpleMatch -Quiet

        if ($cleanPass) {
            $line = (Select-String -Path $log -Pattern '[POC08-UNIFIED-MULTI] LIVE PASS' -SimpleMatch | Select-Object -Last 1).Line
            $totalPasses++
            $totalConfirmedBuys += $confirmed
            $consecutiveRecoveries = 0
            Status ('CYCLE {0} PASS sent/server/confirmed={1}/{2}/{3} exact_ids=YES total_buys={4} {5}' -f $cycle,$sent,$server,$confirmed,$totalConfirmedBuys,$line)
            if ((Get-Date).AddSeconds($PostBuySleepSeconds) -ge $stopTime) { break }
            if ($PostBuySleepSeconds -gt 0) { Start-Sleep -Seconds $PostBuySleepSeconds }
        }
        elseif ($cleanNoop) {
            $totalNoops++
            $consecutiveRecoveries = 0
            Status ('CYCLE {0} NOOP zero BUY; healthy_noop={1}' -f $cycle,$totalNoops)
            if ((Get-Date).AddSeconds($NoopSleepSeconds) -ge $stopTime) { break }
            if ($NoopSleepSeconds -gt 0) { Start-Sleep -Seconds $NoopSleepSeconds }
        }
        else {
            $consecutiveRecoveries++
            $totalRecoveries++
            $delay = Get-RecoveryDelay $consecutiveRecoveries
            $err = Get-LastErrorSummary $log
            Status ('RECOVER cycle={0}: safe_boundary=YES exit={1} sent/server/confirmed={2}/{3}/{4} consecutive={5} total_recoveries={6} delay={7}s error="{8}"' -f $cycle,$code,$sent,$server,$confirmed,$consecutiveRecoveries,$totalRecoveries,$delay,$err)
            if ($consecutiveRecoveries -ge 4) {
                Status ('SERVER COOLDOWN active: {0} consecutive safe failures; exponential backoff protects login/AH from retry storm' -f $consecutiveRecoveries)
            }
            if ((Get-Date).AddSeconds($delay) -ge $stopTime) { break }
            Start-Sleep -Seconds $delay
        }

        if (($cycle % 10) -eq 0) {
            Status ('HEARTBEAT cycles={0} passes={1} noops={2} recoveries={3} confirmed_buys={4}' -f $cycle,$totalPasses,$totalNoops,$totalRecoveries,$totalConfirmedBuys)
        }
    }

    Status ('V2 COMPLETE cycles={0} passes={1} noops={2} recoveries={3} confirmed_buys={4} stop_at={5}' -f $cycle,$totalPasses,$totalNoops,$totalRecoveries,$totalConfirmedBuys,$stopTime.ToString('yyyy-MM-dd HH:mm'))
    Write-Host 'VENDOR NIGHT V2 COMPLETE - stop time reached.' -ForegroundColor Green
    exit 0
}
finally {
    if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
    Clear-Arm
}
