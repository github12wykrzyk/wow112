$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$env:WOW112_ACCOUNT='octowar1'
$env:WOW112_CHARACTER='Smokinpole'
$env:WOW112_REALM_INDEX='1'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_MAILBOX_GUID='0xF11002A4A5002A0C'

$env:WOW112_POC08_E_ACTION='buy-one'
$env:WOW112_AH_MUTATION_CONFIRM='YES'
$env:WOW112_DE_BUY_CONFIRM='YES'
$env:WOW112_DE_MAX_SINGLE_BUY='50000'       # 5g hard cap for first DE buy-one
$env:WOW112_DE_REVALIDATE_MAX_PAGES='16'

$env:WOW112_AUTOBUY_MAX_BUYOUT='150000'
$env:WOW112_AUTOBUY_MIN_PROFIT='1'
$env:WOW112_DE_MIN_SAFE_PROFIT='2000'       # 20s
$env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'      # 20%
$env:WOW112_DE_MAX_PLOSS_BPS='4000'         # 40%
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_FILTER_MAX_PAGES='512'
$env:WOW112_DE_ITEM_QUERY_WINDOW='64'
$env:WOW112_POC08_E_JOURNAL=(Join-Path $PSScriptRoot 'POC08_E_TX_JOURNAL.log')
$env:WOW112_ECONOMY_CANDIDATE_EXPORT=(Join-Path $PSScriptRoot 'POC08_E_CANDIDATES.csv')
$env:WOW112_ECONOMY_REJECTED_EXPORT=(Join-Path $PSScriptRoot 'POC08_E_REJECTED.csv')
$env:WOW112_POC08_MATERIAL_BOOK_EXPORT=(Join-Path $PSScriptRoot 'POC08_E_MATERIAL_BOOK.csv')
$env:WOW112_POC08_MATERIAL_HISTORY=(Join-Path $PSScriptRoot 'POC08_MATERIAL_HISTORY.csv')

if (-not (Test-Path "$PSScriptRoot\wow112-headless-windows.exe")) {
    Write-Host 'ERROR: wow112-headless-windows.exe not found.' -ForegroundColor Red
    exit 2
}

Write-Host '============================================================'
Write-Host 'POC08-E GUARDED DE BUY-ONE'
Write-Host 'MAX PURCHASES: 1 | MAX SINGLE BUY: 5g'
Write-Host 'DE gate: safe profit >=20s | ROI >=20% | P(loss) <=40%'
Write-Host 'Fresh targeted exact-name revalidation before SEND'
Write-Host 'Success requires ACK + exact NEW mail stack'
Write-Host 'Dirty journal blocks another BUY after uncertain state'
Write-Host '============================================================'
$confirm = Read-Host 'Type BUY ONE to arm one DE purchase, or anything else to cancel'
if ($confirm -ne 'BUY ONE') {
    Write-Host 'Cancelled. No mutation sent.' -ForegroundColor Yellow
    exit 0
}

$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    & "$PSScriptRoot\wow112-headless-windows.exe" 2>&1 | Tee-Object (Join-Path $PSScriptRoot 'POC08_E_BUYONE.log')
    exit $LASTEXITCODE
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}
