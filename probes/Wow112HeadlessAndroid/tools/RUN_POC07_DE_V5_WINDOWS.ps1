param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exe = Join-Path $Root 'wow112-headless-windows.exe'
$Resolver = Join-Path $Root 'RESOLVE_OCTOWOW_DE_GATE.ps1'
$Runtime = Join-Path $Root 'runtime'
$Candidates = Join-Path $Runtime 'V5_RAW_CANDIDATES.csv'
$Safe = Join-Path $Runtime 'V5_SAFE_CANDIDATES.csv'
$Cache = Join-Path $Runtime 'DE_DISENCHANT_CACHE.csv'
$ScanLog = Join-Path $Runtime 'V5_WINDOWS_SCAN.log'
$GateLog = Join-Path $Runtime 'V5_GATE.log'

New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
if (-not (Test-Path -LiteralPath $Exe)) { throw "Missing executable: $Exe" }
if (-not (Test-Path -LiteralPath $Resolver)) { throw "Missing resolver: $Resolver" }

function Read-Default([string]$Prompt, [string]$Default) {
    $value = Read-Host "$Prompt [Enter=$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

Write-Host '============================================================'
Write-Host 'WoW112 WINDOWS HEADLESS - POC07 DE V5'
Write-Host 'Native Windows -> AH scan -> DE EV -> exact DisenchantID gate'
Write-Host 'ZERO BUY / NO ADB / NO ANDROID'
Write-Host '============================================================'

$account = Read-Host 'Login WoW'
$secure = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}
$character = Read-Host 'Postac [Enter=pierwsza postac]'
$maxBuyout = Read-Default 'Max buyout do analizy (copper)' '4294967295'
$minProfit = Read-Default 'Min DE profit (copper)' '1'
$netBps = Read-Default 'DE net BPS' '8500'
$maxPages = Read-Default 'Safety max filtrowanych stron na klase' '128'

$env:WOW112_ACCOUNT = $account
$env:WOW112_PASSWORD = $password
$env:WOW112_REALM_INDEX = '1'
$env:WOW112_AUTOBUY_ACTION = 'scan-only'
$env:WOW112_AUTOBUY_MAX_BUYOUT = $maxBuyout
$env:WOW112_AUTOBUY_MIN_PROFIT = $minProfit
$env:WOW112_DE_NET_BPS = $netBps
$env:WOW112_DE_FILTER_MAX_PAGES = $maxPages
$env:WOW112_DE_CANDIDATE_EXPORT = $Candidates
$env:WOW112_RECONNECT_LIMIT = '10'
$env:WOW112_RECONNECT_DELAY_MS = '1000'
$env:WOW112_AH_GUID = '0xF130003D4100023A'
$env:WOW112_MAILBOX_GUID = '0xF11002A4A5002A0C'
if (-not [string]::IsNullOrWhiteSpace($character)) { $env:WOW112_CHARACTER = $character.Trim() } else { Remove-Item Env:WOW112_CHARACTER -ErrorAction SilentlyContinue }

try {
    Remove-Item -LiteralPath $Candidates -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Safe -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ScanLog -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $GateLog -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '[WINDOWS-V5] STEP 1/2 native WoW headless scan'
    & $Exe 2>&1 | Tee-Object -FilePath $ScanLog
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "Windows headless exited with code $exitCode" }
    if (-not (Test-Path -LiteralPath $Candidates)) { throw "Candidate export missing: $Candidates" }

    Write-Host ''
    Write-Host '[WINDOWS-V5] STEP 2/2 exact DisenchantID gate'
    & $Resolver -CandidateCsv $Candidates -CacheCsv $Cache -SafeCsv $Safe -TimeoutSec 15 -Retries 3 2>&1 | Tee-Object -FilePath $GateLog
    if (-not (Test-Path -LiteralPath $Safe)) { throw "Safe candidate output missing: $Safe" }

    $rawCount = @(Import-Csv -LiteralPath $Candidates).Count
    $safeCount = @(Import-Csv -LiteralPath $Safe).Count
    Write-Host ''
    Write-Host '============================================================'
    Write-Host "[WINDOWS-V5] END-TO-END PASS raw_candidates=$rawCount safe_candidates=$safeCount"
    Write-Host "[WINDOWS-V5] raw=$Candidates"
    Write-Host "[WINDOWS-V5] safe=$Safe"
    Write-Host "[WINDOWS-V5] cache=$Cache"
    Write-Host '[WINDOWS-V5] MUTATION=DISABLED ZERO_BUY=YES'
    Write-Host '============================================================'
}
finally {
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_ACCOUNT -ErrorAction SilentlyContinue
    Remove-Item Env:WOW112_CHARACTER -ErrorAction SilentlyContinue
    $password = $null
}
