$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

$env:WOW112_ACCOUNT='octowar1'
$env:WOW112_CHARACTER='Smokinpole'
$env:WOW112_REALM_INDEX='1'
$env:WOW112_SOAK_SECONDS='0'
$env:WOW112_RECONNECT_LIMIT='60'
$env:WOW112_RECONNECT_DELAY_MS='0'

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
$env:WOW112_ECONOMY_CANDIDATE_EXPORT='POC08_F1_CANDIDATES.csv'
$env:WOW112_ECONOMY_REJECTED_EXPORT='POC08_F1_REJECTED.csv'
$env:WOW112_MATERIAL_BOOK_EXPORT='POC08_F1_MATERIAL_BOOK.csv'
$env:WOW112_F0_ELIGIBLE_EXPORT='POC08_F1_ELIGIBLE.csv'
$env:WOW112_DE_PROVENANCE_EXPORT='POC08_F1_DE_PROVENANCE.csv'

Write-Host '============================================================'
Write-Host 'POC08-F1 GUARDED LIVE BUY-ONE'
Write-Host 'Hard rule: MAX 1 PURCHASE PER PROCESS'
Write-Host 'Fresh AH precheck immediately before BUY; NO RETRY after BUY send.'
Write-Host ''
Write-Host '  [1] VENDOR SMOKE  - deterministic server sell price, recommended FIRST'
Write-Host '  [2] DE PILOT      - whitelist item_id=9823 only, max buyout 15s'
Write-Host '  [3] AUDIT ONLY    - zero mutation'
Write-Host '============================================================'
$choice = Read-Host 'Mode [Enter=1]'

switch ($choice) {
    '2' {
        $env:WOW112_F1_ACTION='de-whitelist'
        $env:WOW112_F1_DE_WHITELIST='9823'
        $env:WOW112_F1_HARD_MAX_SINGLE_BUYOUT='1500'
        $env:WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS='0'
        $modeLabel='DE PILOT 9823'
    }
    '3' {
        $env:WOW112_F1_ACTION='audit'
        $modeLabel='AUDIT ONLY'
    }
    default {
        $env:WOW112_F1_ACTION='vendor-smoke'
        $env:WOW112_F1_HARD_MAX_SINGLE_BUYOUT='10000'
        $env:WOW112_F1_MIN_VENDOR_PROFIT='1'
        $modeLabel='VENDOR SMOKE'
    }
}

if ($env:WOW112_F1_ACTION -ne 'audit') {
    Write-Host ''
    Write-Host "LIVE MODE: $modeLabel" -ForegroundColor Yellow
    Write-Host 'This run can spend in-game gold and buy exactly ONE auction.' -ForegroundColor Yellow
    $confirm = Read-Host 'Type BUY to arm one purchase'
    if ($confirm -cne 'BUY') {
        Write-Host 'Not armed. Exiting with zero mutation.'
        exit 0
    }
    $env:WOW112_F1_LIVE_CONFIRM='BUY_ONE_NOW'
    $env:WOW112_AUTOBUY_CONFIRM='YES'
    $env:WOW112_AUTOBUY_MAX_PURCHASES='1'
} else {
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
    $env:WOW112_AUTOBUY_MAX_PURCHASES='1'
}

if (-not (Test-Path "$PSScriptRoot\wow112-headless-windows.exe")) {
    Write-Host 'ERROR: wow112-headless-windows.exe not found.' -ForegroundColor Red
    exit 2
}

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & "$PSScriptRoot\wow112-headless-windows.exe" 2>&1 | Tee-Object "$PSScriptRoot\POC08_F1_LIVE.log"
    $code = $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Exit code: $code"
Write-Host 'Log: POC08_F1_LIVE.log'
Write-Host 'If the log contains AH_MUTATION_UNCERTAIN, DO NOT rerun until the AH/mail state is checked.' -ForegroundColor Yellow
exit $code
