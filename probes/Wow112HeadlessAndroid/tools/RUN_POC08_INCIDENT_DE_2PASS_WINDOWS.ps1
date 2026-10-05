$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'wow112-headless-windows.exe'
if (-not (Test-Path $exe)) { throw 'wow112-headless-windows.exe not found' }

# Keep identity external to the runner. Existing WOW112_ACCOUNT / CHARACTER are reused.
if ([string]::IsNullOrWhiteSpace($env:WOW112_ACCOUNT)) { $env:WOW112_ACCOUNT = Read-Host 'Login WoW' }
if ([string]::IsNullOrWhiteSpace($env:WOW112_CHARACTER)) { $env:WOW112_CHARACTER = 'Smokinpole' }
$env:WOW112_REALM_INDEX='1'
$env:WOW112_SOAK_SECONDS='0'
$env:WOW112_RECONNECT_LIMIT='20'
$env:WOW112_RECONNECT_DELAY_MS='0'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_SOURCE_CLIENT=("{0}:{1}:poc08-incident" -f $env:WOW112_ACCOUNT,$env:WOW112_CHARACTER)
$env:WOW112_DE_SESSION_ID=([guid]::NewGuid().ToString('N'))

# Data integrity: current snapshots may warm history, but cannot price LIVE DE until
# three independent epochs exist. Missing/stale/malformed history or >20% upward
# shock produces safe_price=0 and therefore blocks DE.
$env:WOW112_MATERIAL_HISTORY_PATH='POC08_MATERIAL_HISTORY.csv'
$env:WOW112_DE_HISTORY_MAX_AGE_S='21600'
$env:WOW112_DE_HISTORY_EPOCH_S='900'
$env:WOW112_DE_MIN_HISTORY_EPOCHS='3'
$env:WOW112_DE_UPWARD_SHOCK_BPS='2000'
Remove-Item Env:WOW112_DE_ALLOW_MANUAL_OVERRIDE -ErrorAction SilentlyContinue

# Persistent exposure controls, all values in copper.
$env:WOW112_DE_RISK_STATE_PATH='POC08_DE_RISK_STATE'
$env:WOW112_DE_PRICE_EPOCH_S='900'
$env:WOW112_DE_EXPOSURE_WINDOW_S='86400'
$env:WOW112_DE_SESSION_SPEND_CAP='100000'
$env:WOW112_DE_ROLLING_SPEND_CAP='200000'
$env:WOW112_DE_PER_DEID_EXPOSURE_CAP='50000'
$env:WOW112_DE_PER_MATERIAL_EXPOSURE_CAP='50000'
$env:WOW112_DE_MAX_BUYS_PER_EPOCH='3'
$env:WOW112_DE_MAX_ELIGIBLE_CANDIDATES='20'
Remove-Item Env:WOW112_DE_MUTATION_ENABLED -ErrorAction SilentlyContinue

# Existing F2 gates remain underneath the incident controller.
$env:WOW112_AUTOBUY_MAX_BUYOUT='150000'
$env:WOW112_AUTOBUY_MIN_PROFIT='1'
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_FILTER_MAX_PAGES='256'
$env:WOW112_DE_ITEM_QUERY_WINDOW='64'
$env:WOW112_DE_MIN_SAFE_PROFIT='500'
$env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'
$env:WOW112_DE_MAX_PLOSS_BPS='4000'
$env:WOW112_F0_MIN_SAFE_PROFIT='500'
$env:WOW112_F0_MIN_SAFE_ROI_BPS='2000'
$env:WOW112_F0_MAX_PLOSS_BPS='4000'
$env:WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS='10000'
$env:WOW112_F0_MIN_EDGE_VS_VENDOR='0'
$env:WOW112_F0_HARD_MAX_SINGLE_BUYOUT='150000'
$env:WOW112_ECONOMY_CANDIDATE_EXPORT='POC08_F2_CANDIDATES.csv'
$env:WOW112_ECONOMY_REJECTED_EXPORT='POC08_F2_REJECTED.csv'
$env:WOW112_MATERIAL_BOOK_EXPORT='POC08_F2_MATERIAL_BOOK.csv'
$env:WOW112_F0_ELIGIBLE_EXPORT='POC08_F2_ELIGIBLE.csv'
$env:WOW112_DE_PROVENANCE_EXPORT='POC08_F2_DE_PROVENANCE.csv'
$env:WOW112_AUTOBUY_MAX_PURCHASES='1'

Write-Host 'POC08 INCIDENT DE: PASS1 read-only; PASS2 exact tuple only.'
Write-Host 'History >=3 independent 15m epochs; upward shock >20% quarantined.'
Write-Host 'Exposure defaults: 10g/session, 20g/24h, 5g/DEID, 5g/material, 3 buys/epoch.'
Write-Host ("risk_session={0}" -f $env:WOW112_DE_SESSION_ID)

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    # PASS 1. The incident mutation latch is deliberately absent.
    $env:WOW112_F1_ACTION='audit'
    Remove-Item Env:WOW112_DE_MUTATION_ENABLED -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
    foreach ($n in 'WOW112_F2_EXPECT_AUCTION_ID','WOW112_F2_EXPECT_ITEM_ID','WOW112_F2_EXPECT_BUYOUT','WOW112_F2_EXPECT_COUNT') {
        Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue
    }

    $auditLog = Join-Path $PSScriptRoot 'POC08_F2_AUDIT.log'
    & $exe 2>&1 | Tee-Object -FilePath $auditLog
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $eligiblePath = Join-Path $PSScriptRoot 'POC08_F2_ELIGIBLE.csv'
    if (-not (Test-Path $eligiblePath)) { throw 'POC08_F2_ELIGIBLE.csv missing' }
    $targets = @(Import-Csv $eligiblePath | Where-Object {
        ([uint32]$_.item_id -eq 9823) -and ([uint32]$_.disenchant_id -eq 5) -and
        ([uint32]$_.buyout -gt 0) -and ([uint32]$_.buyout -le 1500) -and
        ([int64]$_.de_profit -ge 500) -and ([uint32]$_.de_roi_bps -ge 2000) -and
        ([uint32]$_.de_ploss_bps -le 4000) -and ([uint32]$_.agreement_bps -eq 0)
    } | Sort-Object @{Expression={[int64]$_.de_profit};Descending=$true}, @{Expression={[uint32]$_.buyout};Ascending=$true})
    if ($targets.Count -eq 0) {
        Write-Host 'No eligible DE pilot. Expected during history warm-up/quarantine.' -ForegroundColor Yellow
        exit 0
    }

    $target = $targets[0]
    Write-Host ("AUDITED TARGET auction_id={0} item_id={1} buyout={2} safe_ev={3} ROI={4} P(loss)={5}" -f $target.auction_id,$target.item_id,$target.buyout,$target.safe_de_ev,$target.de_roi_bps,$target.de_ploss_bps)
    $confirm = Read-Host 'Type BUY to arm ONLY this exact purchase'
    if ($confirm -cne 'BUY') { exit 0 }

    # PASS 2 only. The new latch exists only after explicit confirmation.
    $env:WOW112_DE_MUTATION_ENABLED='YES'
    $env:WOW112_F1_ACTION='de-whitelist'
    $env:WOW112_F1_DE_WHITELIST='9823'
    $env:WOW112_F1_HARD_MAX_SINGLE_BUYOUT='1500'
    $env:WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS='0'
    $env:WOW112_F1_LIVE_CONFIRM='BUY_ONE_NOW'
    $env:WOW112_AUTOBUY_CONFIRM='YES'
    $env:WOW112_F2_EXPECT_AUCTION_ID=[string]$target.auction_id
    $env:WOW112_F2_EXPECT_ITEM_ID=[string]$target.item_id
    $env:WOW112_F2_EXPECT_BUYOUT=[string]$target.buyout
    $env:WOW112_F2_EXPECT_COUNT='1'

    $buyLog = Join-Path $PSScriptRoot 'POC08_F2_DE_BUY.log'
    & $exe 2>&1 | Tee-Object -FilePath $buyLog
    $code = $LASTEXITCODE
    if (Select-String -Path $buyLog -Pattern '[POC07-BUY] SENT' -SimpleMatch -Quiet) {
        if (-not (Select-String -Path $buyLog -Pattern '[POC08-F2] LIVE BUY-ONE PASS purchases=1' -SimpleMatch -Quiet)) {
            Write-Host 'STOP: send without final PASS; persistent UNKNOWN exposure remains reserved.' -ForegroundColor Red
            exit 3
        }
    }
    exit $code
}
finally {
    if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_DE_MUTATION_ENABLED -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
}
