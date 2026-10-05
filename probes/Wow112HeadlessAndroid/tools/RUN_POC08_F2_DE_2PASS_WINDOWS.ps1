$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$exe = Join-Path $PSScriptRoot 'wow112-headless-windows.exe'
if (-not (Test-Path $exe)) {
    Write-Host 'ERROR: wow112-headless-windows.exe not found.' -ForegroundColor Red
    exit 2
}

# Shared conservative profile. Mutation stays disabled during PASS 1.
$env:WOW112_ACCOUNT='octowar1'
$env:WOW112_CHARACTER='Smokinpole'
$env:WOW112_REALM_INDEX='1'
$env:WOW112_SOAK_SECONDS='0'
$env:WOW112_RECONNECT_LIMIT='20'
$env:WOW112_RECONNECT_DELAY_MS='0'

# Reuse the existing shared AH-open primitive, but seed it with the auctioneer GUID
# already proven LIVE end-to-end by the vendor path. The primitive still validates
# MSG_AUCTION_HELLO and retains bounded failover to any additionally discovered
# auctioneer candidates; no opcode/request format is changed here.
$env:WOW112_AH_GUID='0xF130003D4100023A'

$env:WOW112_AUTOBUY_MAX_BUYOUT='150000'
$env:WOW112_AUTOBUY_MIN_PROFIT='1'
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_FILTER_MAX_PAGES='256'
$env:WOW112_DE_ITEM_QUERY_WINDOW='64'
$env:WOW112_MATERIAL_HISTORY_PATH='POC08_MATERIAL_HISTORY.csv'
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

Write-Host '============================================================'
Write-Host 'POC08-F2 EXACT DE PILOT / 2 PASS'
Write-Host 'PASS 1 = AUDIT ONLY / ZERO MUTATION'
Write-Host 'PASS 2 = exact audited tuple + current gates + fresh AH precheck'
Write-Host 'Pilot: item_id=9823, DisenchantID=5, max buyout 15s'
Write-Host 'Gates: SAFE profit >=5s, ROI >=20%, P(loss) <=40%, model disagreement=0'
Write-Host 'Hard max purchases per process: 1'
Write-Host 'AH open: shared vendor/DE primitive; preferred LIVE-proven guid=0xF130003D4100023A'
Write-Host 'NO automatic retry after BUY send.'
Write-Host '============================================================'
Write-Host ''

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    # PASS 1: read-only audit and candidate export.
    $env:WOW112_F1_ACTION='audit'
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F2_EXPECT_AUCTION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F2_EXPECT_ITEM_ID -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F2_EXPECT_BUYOUT -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F2_EXPECT_COUNT -ErrorAction SilentlyContinue

    $auditLog = Join-Path $PSScriptRoot 'POC08_F2_AUDIT.log'
    Write-Host '[1/2] READ-ONLY risk/eligibility audit...' -ForegroundColor Cyan
    & $exe 2>&1 | Tee-Object -FilePath $auditLog
    $auditExit = $LASTEXITCODE
    if ($auditExit -ne 0) {
        Write-Host "AUDIT failed, exit=$auditExit. Zero BUY attempted." -ForegroundColor Red
        exit $auditExit
    }

    $eligiblePath = Join-Path $PSScriptRoot 'POC08_F2_ELIGIBLE.csv'
    if (-not (Test-Path $eligiblePath)) {
        Write-Host 'Eligible CSV missing after audit. Zero BUY attempted.' -ForegroundColor Red
        exit 5
    }

    $targets = @(Import-Csv $eligiblePath | Where-Object {
        ([uint32]$_.item_id -eq 9823) -and
        ([uint32]$_.disenchant_id -eq 5) -and
        ([uint32]$_.buyout -gt 0) -and
        ([uint32]$_.buyout -le 1500) -and
        ([int64]$_.de_profit -ge 500) -and
        ([uint32]$_.de_roi_bps -ge 2000) -and
        ([uint32]$_.de_ploss_bps -le 4000) -and
        ([uint32]$_.agreement_bps -eq 0)
    } | Sort-Object @{Expression={[int64]$_.de_profit};Descending=$true}, @{Expression={[uint32]$_.buyout};Ascending=$true}, @{Expression={[uint32]$_.auction_id};Ascending=$true})

    if ($targets.Count -eq 0) {
        Write-Host 'No DE pilot candidate passes all gates right now. Zero BUY attempted.' -ForegroundColor Yellow
        exit 0
    }

    $target = $targets[0]
    Write-Host ''
    Write-Host 'EXACT AUDITED DE TARGET:' -ForegroundColor Green
    Write-Host ("  auction_id={0} item_id={1} count=1 buyout={2}c" -f $target.auction_id,$target.item_id,$target.buyout)
    Write-Host ("  safe_ev={0}c profit={1}c ROI={2}bps P(loss)={3}bps" -f $target.safe_de_ev,$target.de_profit,$target.de_roi_bps,$target.de_ploss_bps)
    Write-Host ("  heuristic_ev={0} reference_ev={1} agreement={2}bps source={3} DEID={4}" -f $target.heuristic_ev,$target.reference_ev,$target.agreement_bps,$target.source,$target.disenchant_id)
    Write-Host ''
    Write-Host 'PASS 2 will re-login and recompute the market/risk model.' -ForegroundColor Yellow
    Write-Host 'It may buy ONLY the exact auction/item/buyout/count shown above.' -ForegroundColor Yellow
    Write-Host 'Immediately before send, the existing fresh-page exact precheck runs again.' -ForegroundColor Yellow
    $confirm = Read-Host 'Type BUY to arm this exact DE purchase'
    if ($confirm -cne 'BUY') {
        Write-Host 'Not armed. Finished with zero mutation.'
        exit 0
    }

    # PASS 2: same exact auction tuple must still independently pass all gates.
    $env:WOW112_F1_ACTION='de-whitelist'
    $env:WOW112_F1_DE_WHITELIST='9823'
    $env:WOW112_F1_HARD_MAX_SINGLE_BUYOUT='1500'
    $env:WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS='0'
    $env:WOW112_F1_LIVE_CONFIRM='BUY_ONE_NOW'
    $env:WOW112_AUTOBUY_CONFIRM='YES'
    $env:WOW112_AUTOBUY_MAX_PURCHASES='1'
    $env:WOW112_F2_EXPECT_AUCTION_ID=[string]$target.auction_id
    $env:WOW112_F2_EXPECT_ITEM_ID=[string]$target.item_id
    $env:WOW112_F2_EXPECT_BUYOUT=[string]$target.buyout
    $env:WOW112_F2_EXPECT_COUNT='1'

    $buyLog = Join-Path $PSScriptRoot 'POC08_F2_DE_BUY.log'
    Write-Host '[2/2] GUARDED exact DE BUY-ONE...' -ForegroundColor Cyan
    & $exe 2>&1 | Tee-Object -FilePath $buyLog
    $buyExit = $LASTEXITCODE

    Write-Host ''
    if (Select-String -Path $buyLog -Pattern 'AH_MUTATION_UNCERTAIN' -SimpleMatch -Quiet) {
        Write-Host 'STOP: AH_MUTATION_UNCERTAIN detected. DO NOT RERUN.' -ForegroundColor Red
        Write-Host 'Check AH/mail state first and upload POC08_F2_DE_BUY.log.' -ForegroundColor Red
        exit 3
    }
    if (Select-String -Path $buyLog -Pattern '[POC08-F2] LIVE BUY-ONE PASS purchases=1' -SimpleMatch -Quiet) {
        Write-Host 'DE LIVE SUCCESS: BUY-ONE PASS purchases=1' -ForegroundColor Green
        Write-Host 'Upload POC08_F2_DE_BUY.log for reconciliation before expanding automation.' -ForegroundColor Green
        exit 0
    }
    if (Select-String -Path $buyLog -Pattern 'POC08_F2_EXACT_DE_TARGET_NOT_ELIGIBLE' -SimpleMatch -Quiet) {
        Write-Host 'Target disappeared or no longer passes gates. Purchase blocked; zero mutation.' -ForegroundColor Yellow
        exit 4
    }
    if (Select-String -Path $buyLog -Pattern '[POC07-BUY] SENT' -SimpleMatch -Quiet) {
        Write-Host 'STOP: BUY packet was SENT but final LIVE BUY-ONE PASS is missing. DO NOT RERUN.' -ForegroundColor Red
        Write-Host 'Treat mutation state as uncertain; inspect AH/mail and upload POC08_F2_DE_BUY.log.' -ForegroundColor Red
        exit 3
    }
    Write-Host "DE pass ended without BUY-ONE PASS (exit=$buyExit). No SENT marker observed." -ForegroundColor Yellow
    exit $buyExit
}
finally {
    if ($ptr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
}
