param(
    [ValidateSet('diag5','strict')]
    [string]$Mode = ''
)

$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Mode)) {
    Write-Host 'Choose READ-ONLY audit mode:'
    Write-Host '  [1] DIAG5  - 5s profit / 20% ROI / 40% P(loss)  [recommended now]'
    Write-Host '  [2] STRICT - 50s profit / 50% ROI / 20% P(loss)'
    $choice = Read-Host 'Mode [Enter=1]'
    if ($choice -eq '2' -or $choice -ieq 'strict' -or $choice -ieq 's') {
        $Mode = 'strict'
    } else {
        $Mode = 'diag5'
    }
}

$env:WOW112_ACCOUNT='octowar1'
$env:WOW112_CHARACTER='Smokinpole'
$env:WOW112_REALM_INDEX='1'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_MAILBOX_GUID='0xF11002A4A5002A0C'

$env:WOW112_AUTOBUY_ACTION='scan-only'
$env:WOW112_AUTOBUY_STRATEGY='both'
$env:WOW112_AUTOBUY_MAX_BUYOUT='150000'
$env:WOW112_AUTOBUY_MIN_PROFIT='1'
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_FILTER_MAX_PAGES='256'
$env:WOW112_DE_ITEM_QUERY_WINDOW='64'
$env:WOW112_MATERIAL_HISTORY_PATH='POC08_MATERIAL_HISTORY.csv'

if ($Mode -eq 'diag5') {
    # Lower diagnostic gate requested after POC08-D audit.
    # Keep provenance/material-confidence checks from F0, but neutralize the extra
    # strict F0 disagreement/vendor-edge gates so this answers the 5s/20%/40% question.
    $env:WOW112_DE_MIN_SAFE_PROFIT='500'
    $env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'
    $env:WOW112_DE_MAX_PLOSS_BPS='4000'

    $env:WOW112_F0_MIN_SAFE_PROFIT='500'
    $env:WOW112_F0_MIN_SAFE_ROI_BPS='2000'
    $env:WOW112_F0_MAX_PLOSS_BPS='4000'
    $env:WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS='10000'
    $env:WOW112_F0_MIN_EDGE_VS_VENDOR='0'
    $env:WOW112_F0_HARD_MAX_SINGLE_BUYOUT='150000'

    $env:WOW112_ECONOMY_CANDIDATE_EXPORT='POC08_DIAG5_CANDIDATES.csv'
    $env:WOW112_ECONOMY_REJECTED_EXPORT='POC08_DIAG5_REJECTED.csv'
    $env:WOW112_MATERIAL_BOOK_EXPORT='POC08_DIAG5_MATERIAL_BOOK.csv'
    $env:WOW112_F0_ELIGIBLE_EXPORT='POC08_DIAG5_ELIGIBLE.csv'
    $env:WOW112_DE_PROVENANCE_EXPORT='POC08_DIAG5_DE_PROVENANCE.csv'
    $logName='POC08_DIAG5.log'
} else {
    $env:WOW112_DE_MIN_SAFE_PROFIT='2000'
    $env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'
    $env:WOW112_DE_MAX_PLOSS_BPS='4000'

    $env:WOW112_F0_MIN_SAFE_PROFIT='5000'
    $env:WOW112_F0_MIN_SAFE_ROI_BPS='5000'
    $env:WOW112_F0_MAX_PLOSS_BPS='2000'
    $env:WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS='2500'
    $env:WOW112_F0_MIN_EDGE_VS_VENDOR='2000'
    $env:WOW112_F0_HARD_MAX_SINGLE_BUYOUT='50000'

    $env:WOW112_ECONOMY_CANDIDATE_EXPORT='POC08_F0_CANDIDATES.csv'
    $env:WOW112_ECONOMY_REJECTED_EXPORT='POC08_F0_REJECTED.csv'
    $env:WOW112_MATERIAL_BOOK_EXPORT='POC08_F0_MATERIAL_BOOK.csv'
    $env:WOW112_F0_ELIGIBLE_EXPORT='POC08_F0_ELIGIBLE.csv'
    $env:WOW112_DE_PROVENANCE_EXPORT='POC08_F0_DE_PROVENANCE.csv'
    $logName='POC08_F0_ELIGIBILITY.log'
}

if (-not (Test-Path "$PSScriptRoot\wow112-headless-windows.exe")) {
    Write-Host 'ERROR: wow112-headless-windows.exe not found.' -ForegroundColor Red
    exit 2
}

Write-Host '============================================================'
if ($Mode -eq 'diag5') {
    Write-Host 'POC08 DIAG5 - READ ONLY'
    Write-Host 'NO BUY / NO AH MUTATION'
    Write-Host 'Diagnostic gates:'
    Write-Host '  safe profit >= 5s'
    Write-Host '  safe ROI >= 20%'
    Write-Host '  P(loss) <= 40%'
    Write-Host '  accepted DE provenance required'
    Write-Host '  every possible DE material >= MEDIUM confidence'
    Write-Host '  model-disagreement gate disabled for diagnostic view'
    Write-Host '  vendor-edge gate disabled for diagnostic view'
    Write-Host '  hard max single buyout = 15g'
} else {
    Write-Host 'POC08-F0 DE BUY ELIGIBILITY AUDIT - READ ONLY'
    Write-Host 'NO BUY / NO AH MUTATION'
    Write-Host 'Strict hypothetical buy-one gates:'
    Write-Host '  safe profit >= 50s'
    Write-Host '  safe ROI >= 50%'
    Write-Host '  P(loss) <= 20%'
    Write-Host '  model disagreement <= 25%'
    Write-Host '  edge vs vendor >= 20s'
    Write-Host '  hard max single buyout = 5g'
    Write-Host '  every possible DE material >= MEDIUM confidence'
}
Write-Host '============================================================'

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & "$PSScriptRoot\wow112-headless-windows.exe" 2>&1 | Tee-Object "$PSScriptRoot\$logName"
    $code = $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host ''
if ($Mode -eq 'diag5') {
    Write-Host 'Outputs:'
    Write-Host '  POC08_DIAG5_ELIGIBLE.csv'
    Write-Host '  POC08_DIAG5_CANDIDATES.csv'
    Write-Host '  POC08_DIAG5_REJECTED.csv'
    Write-Host '  POC08_DIAG5_MATERIAL_BOOK.csv'
    Write-Host '  POC08_DIAG5_DE_PROVENANCE.csv'
    Write-Host '  POC08_DIAG5.log'
} else {
    Write-Host 'Outputs:'
    Write-Host '  POC08_F0_ELIGIBLE.csv'
    Write-Host '  POC08_F0_CANDIDATES.csv'
    Write-Host '  POC08_F0_REJECTED.csv'
    Write-Host '  POC08_F0_MATERIAL_BOOK.csv'
    Write-Host '  POC08_F0_DE_PROVENANCE.csv'
    Write-Host '  POC08_F0_ELIGIBILITY.log'
}
exit $code
