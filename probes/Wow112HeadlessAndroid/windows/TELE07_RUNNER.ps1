param(
    [switch]$SelfTest,
    [int]$Cycles = 1,
    [string]$FaultRole = '',
    [int]$FaultCycle = 0,
    [int]$ReadyTimeoutSeconds = 180,
    [int]$CycleTimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'WoW112 TELE07 STATIONARY SUPERVISOR'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$SupervisorExe = Join-Path $Root 'tele07_supervisor.exe'
$AcceptorExe = Join-Path $Root 'tele06a_acceptor_runtime.exe'
$SummonerExe = Join-Path $Root 'tele06a_ritual_runtime.exe'
$LocalDir = Join-Path $Root '.local'
$PasswordFile = Join-Path $LocalDir 'wow_password.dpapi'
$ResultsRoot = Join-Path $Root 'results'
$LatestZip = Join-Path $Root 'LATEST_TELE07_RESULT.zip'

if (!(Test-Path $SupervisorExe)) { throw 'Missing tele07_supervisor.exe. Extract the complete ZIP.' }

if ($SelfTest) {
    & $SupervisorExe --self-test
    exit $LASTEXITCODE
}

foreach ($path in @($AcceptorExe,$SummonerExe)) {
    if (!(Test-Path $path)) { throw "Missing required runtime: $path" }
}

if ($Cycles -lt 1) { throw 'Cycles must be >= 1.' }
if ($FaultCycle -lt 0) { throw 'FaultCycle cannot be negative.' }
if ($FaultCycle -gt 0 -and [string]::IsNullOrWhiteSpace($FaultRole)) { throw 'FaultRole is required when FaultCycle > 0.' }
if (-not [string]::IsNullOrWhiteSpace($FaultRole) -and @('CUSTOMER','SLAVE1','SLAVE2') -notcontains $FaultRole.ToUpperInvariant()) {
    throw 'FaultRole must be CUSTOMER, SLAVE1, or SLAVE2.'
}

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
New-Item -ItemType Directory -Force -Path $ResultsRoot | Out-Null

function SecureString-ToPlain([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-LocalPassword {
    if (Test-Path $PasswordFile) {
        try {
            $encrypted = Get-Content $PasswordFile -Raw
            $secure = ConvertTo-SecureString $encrypted
            Write-Host '[CREDENTIAL] using DPAPI-encrypted local password for current Windows user'
            return SecureString-ToPlain $secure
        } catch {
            Write-Host '[CREDENTIAL] saved password could not be decrypted; asking again' -ForegroundColor Yellow
        }
    }

    $secure = Read-Host 'Common WoW password' -AsSecureString
    $plain = SecureString-ToPlain $secure
    if ([string]::IsNullOrEmpty($plain)) { throw 'Password cannot be empty.' }
    $save = Read-Host 'Save password encrypted with Windows DPAPI for future TELE07 runs? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($save) -or $save.Trim().ToLowerInvariant() -eq 'y') {
        $secure | ConvertFrom-SecureString | Set-Content -Encoding ASCII $PasswordFile
        Write-Host "[CREDENTIAL] saved encrypted credential: $PasswordFile"
    }
    return $plain
}

$PlainPassword = Get-LocalPassword
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir = Join-Path $ResultsRoot ("TELE07_{0}" -f $Stamp)
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$LaunchInfo = @(
    'runner=TELE07_RUNNER_V1_7',
    "cycles=$Cycles",
    "fault_role=$FaultRole",
    "fault_cycle=$FaultCycle",
    "ready_timeout_seconds=$ReadyTimeoutSeconds",
    "cycle_timeout_seconds=$CycleTimeoutSeconds",
    "timestamp=$Stamp"
)
$LaunchInfo | Set-Content -Encoding UTF8 (Join-Path $RunDir 'LAUNCH_INFO.txt')

$argsList = @(
    '--cycles', $Cycles.ToString(),
    '--ready-timeout-secs', $ReadyTimeoutSeconds.ToString(),
    '--cycle-timeout-secs', $CycleTimeoutSeconds.ToString()
)
if (-not [string]::IsNullOrWhiteSpace($FaultRole)) {
    $argsList += @('--fault-role', $FaultRole.ToUpperInvariant())
}
if ($FaultCycle -gt 0) {
    $argsList += @('--fault-cycle', $FaultCycle.ToString())
}

Write-Host '============================================================'
Write-Host ' WoW112 TELE07 V1.7 STATIONARY SUPERVISOR'
Write-Host (" cycles={0} fault_role={1} fault_cycle={2}" -f $Cycles,$FaultRole,$FaultCycle)
Write-Host ' V1.6 child mutation guards remain fail-closed and one-shot.'
Write-Host '============================================================'

$exitCode = 2
try {
    $env:WOW112_PASSWORD = $PlainPassword
    $env:WOW112_TELE07_RUN_DIR = $RunDir
    & $SupervisorExe @argsList
    $exitCode = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('WOW112_PASSWORD', $null, 'Process')
    [Environment]::SetEnvironmentVariable('WOW112_TELE07_RUN_DIR', $null, 'Process')
    $PlainPassword = $null
}

if (Test-Path $LatestZip) { Remove-Item -Force $LatestZip }
$RunZip = Join-Path $ResultsRoot ("TELE07_{0}.zip" -f $Stamp)
if (Test-Path $RunZip) { Remove-Item -Force $RunZip }
Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $RunZip -Force
Copy-Item -Force $RunZip $LatestZip

$verdictPath = Join-Path $RunDir 'SUPERVISOR_VERDICT.txt'
if (Test-Path $verdictPath) {
    Write-Host ''
    Write-Host '--- SUPERVISOR VERDICT ---'
    Get-Content $verdictPath | ForEach-Object { Write-Host $_ }
}
Write-Host ''
Write-Host ("ZIP: {0}" -f $LatestZip) -ForegroundColor Cyan
Write-Host 'Upload LATEST_TELE07_RESULT.zip to ChatGPT.' -ForegroundColor Cyan
exit $exitCode
