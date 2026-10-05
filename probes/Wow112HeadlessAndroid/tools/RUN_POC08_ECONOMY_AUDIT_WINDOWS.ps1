param(
    [string]$Account = 'octowar1',
    [string]$Character = 'Smokinpole',
    [int]$RealmIndex = 1
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$exe = Join-Path $PSScriptRoot 'wow112-headless-windows.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "wow112-headless-windows.exe not found in $PSScriptRoot"
}

$env:WOW112_ACCOUNT = $Account
$env:WOW112_CHARACTER = $Character
$env:WOW112_REALM_INDEX = [string]$RealmIndex

# Proven Octo interaction target. Mailbox is not mutated in POC08-A, but keep
# the known value available for future transaction-core work.
$env:WOW112_AH_GUID = '0xF130003D4100023A'
$env:WOW112_MAILBOX_GUID = '0xF11002A4A5002A0C'

# POC08-A is hard read-only.
$env:WOW112_AUTOBUY_ACTION = 'scan-only'
$env:WOW112_AUTOBUY_STRATEGY = 'both'
$env:WOW112_AUTOBUY_MAX_BUYOUT = '150000'       # 15g audit cap
$env:WOW112_AUTOBUY_MIN_PROFIT = '1'            # audit everything positive
$env:WOW112_DE_NET_BPS = '8500'                  # existing conservative 15% haircut
$env:WOW112_DE_FILTER_MAX_PAGES = '512'
$env:WOW112_DE_ITEM_QUERY_WINDOW = '64'

$env:WOW112_ECONOMY_CANDIDATE_EXPORT = (Join-Path $PSScriptRoot 'POC08_ECONOMY_CANDIDATES.csv')
$env:WOW112_ECONOMY_REJECTED_EXPORT = (Join-Path $PSScriptRoot 'POC08_ECONOMY_REJECTED.csv')

Write-Host '============================================================'
Write-Host 'WoW112 POC08-A ECONOMY CORE - COMBINED AUDIT'
Write-Host 'READ ONLY - ZERO AH MUTATION'
Write-Host 'DE fast filtered scan + exact DisenchantID gate + live VendorValue'
Write-Host 'DE distribution: V4 heuristic (audit only; NO DE BUY)'
Write-Host 'Material price unit rounding: FLOOR'
Write-Host 'Max audited buyout: 15g | positive-profit audit threshold: 1c'
Write-Host '============================================================'

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & $exe 2>&1 | Tee-Object (Join-Path $PSScriptRoot 'POC08_ECONOMY_AUDIT.log')
    $code = $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Candidates: $env:WOW112_ECONOMY_CANDIDATE_EXPORT"
Write-Host "Rejected:   $env:WOW112_ECONOMY_REJECTED_EXPORT"
Write-Host "Log:        $(Join-Path $PSScriptRoot 'POC08_ECONOMY_AUDIT.log')"
exit $code
