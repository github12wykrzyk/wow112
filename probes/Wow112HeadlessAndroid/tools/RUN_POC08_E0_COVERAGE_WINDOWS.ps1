param(
    [string]$Account = 'octowar1',
    [string]$Character = 'Smokinpole',
    [int]$RealmIndex = 1
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'wow112-headless-windows.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "wow112-headless-windows.exe not found in $PSScriptRoot" }

$env:WOW112_ACCOUNT = $Account
$env:WOW112_CHARACTER = $Character
$env:WOW112_REALM_INDEX = [string]$RealmIndex
$env:WOW112_AH_GUID = '0xF130003D4100023A'
$env:WOW112_MAILBOX_GUID = '0xF11002A4A5002A0C'

# Hard read-only coverage/risk audit.
$env:WOW112_AUTOBUY_ACTION = 'scan-only'
$env:WOW112_AUTOBUY_STRATEGY = 'both'
$env:WOW112_AUTOBUY_MAX_BUYOUT = '150000'
$env:WOW112_AUTOBUY_MIN_PROFIT = '1'
$env:WOW112_DE_NET_BPS = '8500'
$env:WOW112_DE_FILTER_MAX_PAGES = '512'
$env:WOW112_DE_ITEM_QUERY_WINDOW = '64'
$env:WOW112_MATERIAL_BOOK_MAX_PAGES = '8'

$env:WOW112_DE_MIN_SAFE_PROFIT = '2000'
$env:WOW112_DE_MIN_SAFE_ROI_BPS = '2000'
$env:WOW112_DE_MAX_PLOSS_BPS = '4000'

$env:WOW112_MATERIAL_HISTORY_PATH = (Join-Path $PSScriptRoot 'POC08_MATERIAL_HISTORY.csv')
$env:WOW112_MATERIAL_BOOK_EXPORT = (Join-Path $PSScriptRoot 'POC08_E0_MATERIAL_BOOK.csv')
$env:WOW112_ECONOMY_CANDIDATE_EXPORT = (Join-Path $PSScriptRoot 'POC08_E0_CANDIDATES.csv')
$env:WOW112_ECONOMY_REJECTED_EXPORT = (Join-Path $PSScriptRoot 'POC08_E0_REJECTED.csv')

Write-Host '============================================================'
Write-Host 'WoW112 POC08-E0 - FULL DEID COVERAGE + RISK AUDIT'
Write-Host 'READ ONLY - ZERO AH MUTATION'
Write-Host 'Fresh DEID provenance is tracked per item.'
Write-Host 'DE safe-profit >=20s | safe ROI >=20% | P(loss) <=40%'
Write-Host 'Reference loot distribution is still NOT Octo-authoritative.'
Write-Host '============================================================'

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & $exe 2>&1 | Tee-Object (Join-Path $PSScriptRoot 'POC08_E0_COVERAGE_AUDIT.log')
    $code = $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host "Log:        $(Join-Path $PSScriptRoot 'POC08_E0_COVERAGE_AUDIT.log')"
Write-Host "PriceBook:  $env:WOW112_MATERIAL_BOOK_EXPORT"
Write-Host "History:    $env:WOW112_MATERIAL_HISTORY_PATH"
Write-Host "Candidates: $env:WOW112_ECONOMY_CANDIDATE_EXPORT"
Write-Host "Rejected:   $env:WOW112_ECONOMY_REJECTED_EXPORT"
exit $code
