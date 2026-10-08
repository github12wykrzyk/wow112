[CmdletBinding()]
param(
    [ValidateRange(1, 20)][int]$Cycles = 1,
    [string]$CustomerAccount = "octowar1",
    [string]$CustomerCharacter = "Smokinpole",
    [string]$SummonerAccount = "taxi3",
    [string]$SummonerCharacter = "Teletanaris",
    [ValidateRange(1, 2000000000)][int]$PayCopper = 40000,
    [ValidateSet("winterspring")][string]$Destination = "winterspring",
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

function Read-AllEvidence([string]$Root) {
    if (-not (Test-Path $Root)) { return "" }
    $parts = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.log', '.txt', '.json') } |
        ForEach-Object {
            try {
                $text = Get-Content $_.FullName -Raw -ErrorAction Stop
                if ($null -ne $text) { $parts.Add($text) }
            } catch {}
        }
    return ($parts -join "`n")
}

if ($SummonerAccount -ne "taxi3" -or $SummonerCharacter -ne "Teletanaris") {
    throw "This proven live-test runner is pinned to summoner taxi3/Teletanaris. Refusing an unverified summoner override."
}

$layout = Resolve-Layout
$probe = if ($layout.Repo) { Join-Path $layout.Repo "probes\Wow112HeadlessAndroid" } else { $null }
$requiredBins = @(
    "tele08_full_roundtrip.exe",
    "tele07_supervisor.exe",
    "tele06a_acceptor_runtime.exe",
    "tele06a_ritual_runtime.exe",
    "tele10_ledger.exe"
)

if (-not $layout.Packaged -and -not $NoBuild) {
    $missing = @($requiredBins | Where-Object { -not (Test-Path (Join-Path $layout.Bin $_)) })
    if ($missing.Count -gt 0) {
        Write-Step "Building TELE08/TELE10 headless runtime (missing: $($missing -join ', '))"
        & cargo build --release --manifest-path (Join-Path $probe "Cargo.toml") --bin tele08_full_roundtrip --bin tele10_ledger --bin tele07_supervisor --bin tele06a_acceptor_runtime --bin tele06a_ritual_runtime
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
$whisperRoot = Join-Path $runDir "WHISPER"
New-Item -ItemType Directory -Force -Path $whisperRoot | Out-Null
$ledgerPath = Join-Path $runDir "tele10_payment_ledger.json"
$supervisorStdout = Join-Path $runDir "SUPERVISOR.stdout.log"
$supervisorStderr = Join-Path $runDir "SUPERVISOR.stderr.log"
$whisperStdout = Join-Path $runDir "WHISPER.stdout.log"
$whisperStderr = Join-Path $runDir "WHISPER.stderr.log"
$finalReport = Join-Path $runDir "FINAL_REPORT.json"

$old = @{}
$vars = @(
    "WOW112_PASSWORD",
    "WOW112_TELE08_CUSTOMER_ACCOUNT", "WOW112_TELE08_CUSTOMER_CHARACTER",
    "WOW112_TELE08_SUMMONER_ACCOUNT", "WOW112_TELE08_SUMMONER_CHARACTER",
    "WOW112_TELE08_ROUNDTRIP_ROOT",
    "WOW112_TELE09_CUSTOMER_ACCOUNT", "WOW112_TELE09_CUSTOMER_CHARACTER",
    "WOW112_TELE10_PAY_SUMMONER", "WOW112_TELE10_PAY_COPPER", "WOW112_TELE10_PRICE_COPPER",
    "WOW112_TELE10_ACCEPT_PARTIAL", "WOW112_TELE10_LEDGER_PATH", "WOW112_TELE07_RUN_DIR",
    "WOW112_TELE_DESTINATION"
)
foreach ($name in $vars) { $old[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

$whisperExitCode = -1
$whisperPass = $false
$whisperStatusPath = $null
$whisperStatus = "missing"
$supervisorExitCode = -1
$paid = @()
$summons = @()
$supervisorState = "not_started"
$serverTradeComplete = $false
$hardUncertain = $false
$pass = $false

try {
    $env:WOW112_PASSWORD = $Password
    $env:WOW112_TELE08_CUSTOMER_ACCOUNT = $CustomerAccount
    $env:WOW112_TELE08_CUSTOMER_CHARACTER = $CustomerCharacter
    $env:WOW112_TELE08_SUMMONER_ACCOUNT = $SummonerAccount
    $env:WOW112_TELE08_SUMMONER_CHARACTER = $SummonerCharacter
    $env:WOW112_TELE08_ROUNDTRIP_ROOT = $whisperRoot
    $env:WOW112_TELE09_CUSTOMER_ACCOUNT = $CustomerAccount
    $env:WOW112_TELE09_CUSTOMER_CHARACTER = $CustomerCharacter
    $env:WOW112_TELE10_PAY_SUMMONER = $SummonerCharacter
    $env:WOW112_TELE10_PAY_COPPER = "$PayCopper"
    $env:WOW112_TELE10_PRICE_COPPER = "$PayCopper"
    $env:WOW112_TELE10_ACCEPT_PARTIAL = "0"
    $env:WOW112_TELE10_LEDGER_PATH = $ledgerPath
    $env:WOW112_TELE07_RUN_DIR = $runDir
    $env:WOW112_TELE_DESTINATION = $Destination

    Write-Step "PHASE 1/2: real headless whisper roundtrip"
    Write-Step "Customer=$CustomerCharacter -> Summoner=$SummonerCharacter request=winterspring pls"
    $whisperExe = Join-Path $layout.Bin "tele08_full_roundtrip.exe"
    $whisperProc = Start-Process -FilePath $whisperExe -WorkingDirectory $layout.Bin -NoNewWindow -Wait -PassThru -RedirectStandardOutput $whisperStdout -RedirectStandardError $whisperStderr
    $whisperExitCode = $whisperProc.ExitCode

    $statusFile = Get-ChildItem -Path $whisperRoot -Filter STATUS.txt -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $statusFile) {
        $whisperStatusPath = $statusFile.FullName
        $whisperStatus = Get-Content $statusFile.FullName -Raw
        $whisperPass = ($whisperExitCode -eq 0 -and $whisperStatus -match '(?m)^result=PASS\s*$' -and $whisperStatus -match 'real_whisper_in')
    }

    if ($whisperPass) {
        Write-Step "Whisper roundtrip PASS; allowing summon/payment phase"
        Start-Sleep -Milliseconds 1500

        Write-Step "PHASE 2/2: customer + 2 clickers + summoner, ritual, portal, teleport, payment"
        Write-Step "Payment=${PayCopper}c Cycles=$Cycles; economic send is one-shot/no-retry"
        $supervisor = Join-Path $layout.Bin "tele07_supervisor.exe"
        $args = @(
            "--cycles", "$Cycles",
            "--ready-timeout-secs", "240",
            "--cycle-timeout-secs", "150",
            "--stale-secs", "90",
            "--restart-budget", "3"
        )
        $process = Start-Process -FilePath $supervisor -ArgumentList $args -WorkingDirectory $layout.Bin -NoNewWindow -Wait -PassThru -RedirectStandardOutput $supervisorStdout -RedirectStandardError $supervisorStderr
        $supervisorExitCode = $process.ExitCode

        if (Test-Path $ledgerPath) {
            $ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json
            if ($null -ne $ledger -and $null -ne $ledger.summons) {
                $summons = @($ledger.summons)
                $paid = @($summons | Where-Object {
                    $_ -and
                    ($_.payment_status -eq "paid" -or $_.payment_status -eq "overpaid") -and
                    [int64]$_.amount_paid_copper -ge $PayCopper -and
                    $_.client_name -eq $CustomerCharacter
                })
            }
        }

        $supervisorStatePath = Join-Path $runDir "SUPERVISOR_STATE.txt"
        if (Test-Path $supervisorStatePath) {
            $supervisorState = Get-Content $supervisorStatePath -Raw
        }
    } else {
        Write-Step "Whisper roundtrip FAIL; summon/payment phase is blocked"
    }

    $evidence = Read-AllEvidence $runDir
    $hardUncertain = ($evidence -match 'TELE10_[A-Z0-9_]*UNCERTAIN|FAIL_TRADE_SETTLEMENT_UNASSIGNED|PAYMENT_UNCERTAIN')
    $serverTradeComplete = ($evidence -match 'proof=(server_)?TRADE_COMPLETE')

    $pass = (
        $whisperPass -and
        $supervisorExitCode -eq 0 -and
        $paid.Count -ge $Cycles -and
        $serverTradeComplete -and
        -not $hardUncertain
    )

    $report = [ordered]@{
        schema_version = 2
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
        result = if ($pass) { "PASS" } else { "FAIL" }
        chain = "real_whisper_in>parser>queue>reply>summon>ritual>portal>teleport>trade>server_TRADE_COMPLETE>durable_ledger"
        customer = $CustomerCharacter
        customer_account = $CustomerAccount
        summoner = $SummonerCharacter
        summoner_account = $SummonerAccount
        destination = $Destination
        payment_copper = $PayCopper
        cycles_requested = $Cycles
        whisper = [ordered]@{
            passed = $whisperPass
            exit_code = $whisperExitCode
            status_path = $whisperStatusPath
            status = $whisperStatus.Trim()
        }
        summon_payment = [ordered]@{
            supervisor_exit_code = $supervisorExitCode
            supervisor_state = $supervisorState.Trim()
            server_trade_complete = $serverTradeComplete
            paid_summon_count = $paid.Count
            summon_record_count = $summons.Count
            hard_uncertain = $hardUncertain
            ledger = $ledgerPath
        }
        evidence_dir = $runDir
        source_payment_runtime = "feature/tele10-headless-trade-payment-ledger-v1f@b5c793d0a55915a9cfd3b08395ee16f7000e6352"
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $finalReport

    Write-Host ""
    if ($pass) {
        Write-Host "=== AUTONOMOUS LIVE E2E PASS ==="
        Write-Host "Whisper + summon + teleport + server-confirmed trade + durable ledger: PASS"
    } else {
        Write-Host "=== AUTONOMOUS LIVE E2E FAIL ==="
        Write-Host "Whisper=$whisperPass SupervisorExit=$supervisorExitCode Paid=$($paid.Count)/$Cycles TradeComplete=$serverTradeComplete HardUncertain=$hardUncertain"
    }
    Write-Host "Report: $finalReport"
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
