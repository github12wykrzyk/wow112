$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$env:WOW112_ACCOUNT='octowar1'
$env:WOW112_CHARACTER='Smokinpole'
$env:WOW112_REALM_INDEX='1'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_MAILBOX_GUID='0xF11002A4A5002A0C'

$env:WOW112_POC08_E_ACTION='scan-only'
$env:WOW112_AUTOBUY_MAX_BUYOUT='150000'
$env:WOW112_AUTOBUY_MIN_PROFIT='1'
$env:WOW112_DE_MIN_SAFE_PROFIT='2000'
$env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'
$env:WOW112_DE_MAX_PLOSS_BPS='4000'
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_FILTER_MAX_PAGES='512'
$env:WOW112_DE_ITEM_QUERY_WINDOW='64'
$env:WOW112_ECONOMY_CANDIDATE_EXPORT=(Join-Path $PSScriptRoot 'POC08_E_CANDIDATES.csv')
$env:WOW112_ECONOMY_REJECTED_EXPORT=(Join-Path $PSScriptRoot 'POC08_E_REJECTED.csv')
$env:WOW112_POC08_MATERIAL_BOOK_EXPORT=(Join-Path $PSScriptRoot 'POC08_E_MATERIAL_BOOK.csv')
$env:WOW112_POC08_MATERIAL_HISTORY=(Join-Path $PSScriptRoot 'POC08_MATERIAL_HISTORY.csv')

if (-not (Test-Path "$PSScriptRoot\wow112-headless-windows.exe")) {
    Write-Host 'ERROR: wow112-headless-windows.exe not found.' -ForegroundColor Red
    exit 2
}

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & "$PSScriptRoot\wow112-headless-windows.exe" 2>&1 | Tee-Object (Join-Path $PSScriptRoot 'POC08_E_SCAN.log')
    exit $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}
