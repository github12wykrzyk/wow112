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
$env:WOW112_MATERIAL_BOOK_EXPORT = (Join-Path $PSScriptRoot 'POC08_E_MATERIAL_BOOK.csv')
$env:WOW112_ECONOMY_CANDIDATE_EXPORT = (Join-Path $PSScriptRoot 'POC08_E_CANDIDATES.csv')
$env:WOW112_ECONOMY_REJECTED_EXPORT = (Join-Path $PSScriptRoot 'POC08_E_REJECTED.csv')
$env:WOW112_DE_PROVENANCE_EXPORT = (Join-Path $PSScriptRoot 'POC08_E_DE_PROVENANCE.csv')

Write-Host '============================================================'
Write-Host 'WoW112 POC08-E - DEID PROVENANCE + RISK AUDIT'
Write-Host 'READ ONLY - ZERO AH MUTATION'
Write-Host 'Preserves OctoWow / CapyDB / SeedLegacy source per DEID.'
Write-Host 'DE distribution is still NOT Octo-verified: mutation-ready stays 0.'
Write-Host '============================================================'

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & $exe 2>&1 | Tee-Object (Join-Path $PSScriptRoot 'POC08_E_PROVENANCE_AUDIT.log')
    $code = $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host "Log:        $(Join-Path $PSScriptRoot 'POC08_E_PROVENANCE_AUDIT.log')"
Write-Host "Provenance: $env:WOW112_DE_PROVENANCE_EXPORT"
Write-Host "Candidates: $env:WOW112_ECONOMY_CANDIDATE_EXPORT"
Write-Host "Rejected:   $env:WOW112_ECONOMY_REJECTED_EXPORT"
exit $code
