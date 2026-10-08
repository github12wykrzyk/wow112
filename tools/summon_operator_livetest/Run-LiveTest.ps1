[CmdletBinding()]
param(
    [ValidateRange(1, 20)][int]$Cycles = 1,
    [string]$CustomerAccount = "octowar1",
    [string]$CustomerCharacter = "Smokinpole",
    [string]$SummonerCharacter = "Teletanaris",
    [ValidateRange(1, 2000000000)][int]$PayCopper = 40000,
    [string]$Destination = "winterspring",
    [string]$TriggerMessage = "need one winterspring",
    [string]$Password = $env:WOW112_PASSWORD,
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Text) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Text)
}

function Resolve-Layout {
    $packageSupervisor = Join-Path $PSScriptRoot "bin\tele07_supervisor.exe"
    if (Test-Path $packageSupervisor) {
        return [pscustomobject]@{
            Bin = (Join-Path $PSScriptRoot "bin")
            Repo = $null
            Packaged = $true
        }
    }
    $repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    return [pscustomobject]@{
        Bin = (Join-Path $repo "probes\Wow112HeadlessAndroid\target\release")
        Repo = $repo
        Packaged = $false
    }
}

function Require-File([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required file: $Path" }
}

$layout = Resolve-Layout
$probe = if ($layout.Repo) { Join-Path $layout.Repo "probes\Wow112HeadlessAndroid" } else { $null }
$requiredBins = @(
    "tele07_supervisor.exe",
    "tele06a_acceptor_runtime.exe",
    "tele06a_ritual_runtime.exe",
    "tele10_ledger.exe"
)

if (-not $layout.Packaged -and -not $NoBuild) {
    $missing = @($requiredBins | Where-Object { -not (Test-Path (Join-Path $layout.Bin $_)) })
    if ($missing.Count -gt 0) {
        Write-Step "Building TELE10 headless runtime (missing: $($missing -join ', '))"
        & cargo build --release --manifest-path (Join-Path $probe "Cargo.toml") --bin tele10_ledger --bin tele07_supervisor --bin tele06a_acceptor_runtime --bin tele06a_ritual_runtime
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
}
foreach ($bin in $requiredBins) { Require-File (Join-Path $layout.Bin $bin) }

$secureHandle = [IntPtr]::Zero
$passwordFromPrompt = $false
if ([string]::IsNullOrWhiteSpace($Password)) {
    $passwordFromPrompt = $true
    $secure = Read-Host "WoW password (used in memory only)" -AsSecureString
    $secureHandle = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secureHandle)
}
if ([string]::IsNullOrWhiteSpace($Password)) { throw "WOW112 password is required" }

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runRoot = Join-Path $PSScriptRoot "results"
$runDir = Join-Path $runRoot ("LIVE_{0}" -f $stamp)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ledgerPath = Join-Path $runDir "tele10_payment_ledger.json"
$stdoutPath = Join-Path $runDir "RUNNER.stdout.log"
$stderrPath = Join-Path $runDir "RUNNER.stderr.log"
$finalReport = Join-Path $runDir "FINAL_REPORT.json"

$old = @{}
$vars = @(
    "WOW112_PASSWORD", "WOW112_TELE09_CUSTOMER_ACCOUNT", "WOW112_TELE09_CUSTOMER_CHARACTER",
    "WOW112_TELE10_PAY_SUMMONER", "WOW112_TELE10_PAY_COPPER", "WOW112_TELE10_PRICE_COPPER",
    "WOW112_TELE10_ACCEPT_PARTIAL", "WOW112_TELE10_LEDGER_PATH", "WOW112_TELE07_RUN_DIR",
    "WOW112_TELE_DESTINATION", "WOW112_TELE_TRIGGER_MESSAGE"
)
foreach ($name in $vars) { $old[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

$exitCode = -1
$pass = $false
try {
    $env:WOW112_PASSWORD = $Password
    $env:WOW112_TELE09_CUSTOMER_ACCOUNT = $CustomerAccount
    $env:WOW112_TELE09_CUSTOMER_CHARACTER = $CustomerCharacter
    $env:WOW112_TELE10_PAY_SUMMONER = $SummonerCharacter
    $env:WOW112_TELE10_PAY_COPPER = "$PayCopper"
    $env:WOW112_TELE10_PRICE_COPPER = "$PayCopper"
    $env:WOW112_TELE10_ACCEPT_PARTIAL = "0"
    $env:WOW112_TELE10_LEDGER_PATH = $ledgerPath
    $env:WOW112_TELE07_RUN_DIR = $runDir
    $env:WOW112_TELE_DESTINATION = $Destination
    $env:WOW112_TELE_TRIGGER_MESSAGE = $TriggerMessage

    Write-Step "Starting fully headless TELE10 live E2E: customer + 2 clickers + summoner"
    Write-Step "Customer=$CustomerCharacter Summoner=$SummonerCharacter Destination=$Destination Payment=${PayCopper}c Cycles=$Cycles"

    $supervisor = Join-Path $layout.Bin "tele07_supervisor.exe"
    $args = @(
        "--cycles", "$Cycles",
        "--ready-timeout-secs", "240",
        "--cycle-timeout-secs", "150",
        "--stale-secs", "90",
        "--restart-budget", "3"
    )
    $process = Start-Process -FilePath $supervisor -ArgumentList $args -WorkingDirectory $layout.Bin -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $exitCode = $process.ExitCode

    $paid = @()
    $summons = @()
    if (Test-Path $ledgerPath) {
        $ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json
        $summons = @($ledger.summons)
        $paid = @($summons | Where-Object {
            ($_.payment_status -eq "paid" -or $_.payment_status -eq "overpaid") -and
            [int64]$_.amount_paid_copper -ge $PayCopper -and
            $_.client_name -eq $CustomerCharacter
        })
    }

    $supervisorStatePath = Join-Path $runDir "SUPERVISOR_STATE.txt"
    $supervisorState = if (Test-Path $supervisorStatePath) { Get-Content $supervisorStatePath -Raw } else { "missing" }
    $combinedLogs = ((Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue))
    $hardUncertain = ($combinedLogs -match "UNCERTAIN|FAIL_TRADE_SETTLEMENT_UNASSIGNED")

    $pass = ($exitCode -eq 0 -and $paid.Count -ge $Cycles -and -not $hardUncertain)
    $report = [ordered]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
        result = if ($pass) { "PASS" } else { "FAIL" }
        supervisor_exit_code = $exitCode
        cycles_requested = $Cycles
        customer = $CustomerCharacter
        customer_account = $CustomerAccount
        summoner = $SummonerCharacter
        destination = $Destination
        payment_copper = $PayCopper
        paid_summon_count = $paid.Count
        summon_record_count = $summons.Count
        hard_uncertain = $hardUncertain
        supervisor_state = $supervisorState.Trim()
        ledger = $ledgerPath
        stdout = $stdoutPath
        stderr = $stderrPath
        source_payment_runtime = "feature/tele10-headless-trade-payment-ledger-v1f@b5c793d0a55915a9cfd3b08395ee16f7000e6352"
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $finalReport

    if ($pass) {
        Write-Host ""
        Write-Host "=== AUTONOMOUS LIVE TEST PASS ==="
        Write-Host "Summon + server-confirmed trade payment + durable ledger: PASS"
        Write-Host "Report: $finalReport"
    } else {
        Write-Host ""
        Write-Host "=== AUTONOMOUS LIVE TEST FAIL ==="
        Write-Host "Exit=$exitCode Paid=$($paid.Count)/$Cycles HardUncertain=$hardUncertain"
        Write-Host "Report: $finalReport"
    }
}
finally {
    foreach ($name in $vars) {
        [Environment]::SetEnvironmentVariable($name, $old[$name], "Process")
    }
    $Password = $null
    if ($passwordFromPrompt -and $secureHandle -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secureHandle)
    }
}

if ($pass) { exit 0 }
exit 1
