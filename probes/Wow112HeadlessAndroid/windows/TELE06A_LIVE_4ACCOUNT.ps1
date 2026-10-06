$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'WoW112 TELE-06A LIVE Ritual Orchestrator'

function Read-Default([string]$Prompt, [string]$Default) {
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Escape-SQ([string]$Value) {
    return $Value.Replace("'", "''")
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

Write-Host '============================================================'
Write-Host ' WoW112 TELE-06A - WINDOWS LIVE RITUAL CAST'
Write-Host ' real server / no WoW client / no Android / no emulator'
Write-Host '============================================================'
Write-Host ''
Write-Host 'Accounts:'
Write-Host '  CUSTOMER : octowar1'
Write-Host '  SUMMONER : taxi3'
Write-Host '  SLAVE 1  : octowinter1'
Write-Host '  SLAVE 2  : octowinter2'
Write-Host ''

$customerChar = Read-Default 'Customer character' 'Smokinpole'
$summonerChar = Read-Default 'Summoner character' 'Teletanaris'
$slave1Char = Read-Default 'Slave 1 character' 'Winterone'
$slave2Char = Read-Default 'Slave 2 character' 'Wintertwoo'

$secure = Read-Host 'Common WoW password (entered once; not written to logs/files)' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ([string]::IsNullOrEmpty($plain)) { throw 'Password cannot be empty.' }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$acceptorExe = Join-Path $root 'tele06a_acceptor_runtime.exe'
$summonerExe = Join-Path $root 'tele06a_ritual_runtime.exe'
if (!(Test-Path $acceptorExe)) { throw "Missing $acceptorExe" }
if (!(Test-Path $summonerExe)) { throw "Missing $summonerExe" }

$env:WOW112_PASSWORD = $plain
$env:WOW112_REALM_INDEX = '1'
$env:WOW112_RECONNECT_LIMIT = '60'
$env:WOW112_RECONNECT_DELAY_MS = '1000'
$env:WOW112_SOAK_SECONDS = '0'

function Start-Acceptor([string]$Label, [string]$Account, [string]$Character) {
    $log = Join-Path $root ("logs\TELE06A_{0}_{1}.log" -f $Label, $stamp)
    $cmd = @"
`$env:WOW112_ACCOUNT='$(Escape-SQ $Account)';
`$env:WOW112_CHARACTER='$(Escape-SQ $Character)';
`$env:WOW112_TELE_AUTO_ACCEPT_FROM='$(Escape-SQ $summonerChar)';
& '$(Escape-SQ $acceptorExe)' 2>&1 | Tee-Object -FilePath '$(Escape-SQ $log)';
Write-Host ''; Write-Host ('PROCESS EXIT CODE: ' + `$LASTEXITCODE); Write-Host ('LOG: $(Escape-SQ $log)');
if (`$LASTEXITCODE -ne 0) { Write-Host 'FAILED - keep this window open and send the log.' -ForegroundColor Red }
"@
    Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$cmd) | Out-Null
}

Write-Host ''
Write-Host '[1/2] Starting CUSTOMER + two SLAVES as reset-and-accept agents...'
Start-Acceptor 'CUSTOMER' 'octowar1' $customerChar
Start-Sleep -Milliseconds 700
Start-Acceptor 'SLAVE1' 'octowinter1' $slave1Char
Start-Sleep -Milliseconds 700
Start-Acceptor 'SLAVE2' 'octowinter2' $slave2Char

Write-Host ''
Write-Host 'Wait until ALL THREE windows show:' -ForegroundColor Yellow
Write-Host '  [TELE-06A-ACCEPTOR] ARMED ONCE whitelist=...'
Write-Host 'They first send one CMSG_GROUP_DISBAND to clear stale TELE-05 groups.'
Read-Host 'When all three are ARMED, press ENTER here to start taxi3 SUMMONER'

$log = Join-Path $root ("logs\TELE06A_SUMMONER_{0}.log" -f $stamp)
$inviteList = "$customerChar,$slave1Char,$slave2Char"
$cmd = @"
`$env:WOW112_ACCOUNT='taxi3';
`$env:WOW112_CHARACTER='$(Escape-SQ $summonerChar)';
`$env:WOW112_TELE_RESET_GROUP='1';
`$env:WOW112_TELE_INVITE_LIST='$(Escape-SQ $inviteList)';
`$env:WOW112_RITUAL_TARGET_NAME='$(Escape-SQ $customerChar)';
& '$(Escape-SQ $summonerExe)' 2>&1 | Tee-Object -FilePath '$(Escape-SQ $log)';
Write-Host ''; Write-Host ('PROCESS EXIT CODE: ' + `$LASTEXITCODE); Write-Host ('LOG: $(Escape-SQ $log)');
if (`$LASTEXITCODE -ne 0) { Write-Host 'FAILED - keep this window open and send the log.' -ForegroundColor Red }
"@

Write-Host '[2/2] Starting SUMMONER taxi3...'
Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$cmd) | Out-Null

# Child processes inherited the password. Remove it from the orchestrator immediately.
$env:WOW112_PASSWORD = $null
$plain = $null
$secure = $null

Write-Host ''
Write-Host 'SUMMONER launched.' -ForegroundColor Green
Write-Host 'Expected PASS chain:'
Write-Host '  RESET -> 3x INVITE-TX -> GROUP_LIST all 3 -> ROSTER PASS'
Write-Host '  -> CAST-TX spell=698 -> LIVE_CAST_START_PASS or LIVE_CAST_GO_PASS'
Write-Host ''
Write-Host 'If server rejects cast, this is still a valid diagnostic result:'
Write-Host '  SERVER_REJECT ... retry_allowed=false'
Write-Host ''
Write-Host "Logs: $root\logs"
Write-Host 'Portal clicks are intentionally DISABLED in TELE-06A.'
