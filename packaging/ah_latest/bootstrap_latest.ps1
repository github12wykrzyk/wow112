param(
    [string]$InstallRoot = '',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = (Get-Location).Path
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$Owner = 'github12wykrzyk'
$Repo = 'wow112'
$Branch = 'dev/windows-ah-de-liquidation-v3'
$Workflow = 'build_windows_ah_de_liquidation_v3.yml'
$ArtifactPrefix = 'WoW112-AH-DE-LIQUIDATION-V31-WINDOWS-'
$Api = 'https://api.github.com'
$Headers = @{
    'User-Agent' = 'WoW112-AH-Latest-Bootstrap/1.0'
    'Accept' = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Say([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
}

Say '============================================================' Cyan
Say 'WoW112 AH - UNIVERSAL LATEST BOOTSTRAP' Cyan
Say 'Vendor Stable is preserved. Only DE_LAB executable is updated.' DarkCyan
Say '============================================================' Cyan

$deDir = Join-Path $InstallRoot 'DE_LAB'
New-Item -ItemType Directory -Force -Path $deDir | Out-Null
$localExe = Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe'
$versionFile = Join-Path $deDir 'LATEST_GITHUB_BUILD.txt'
$history = Join-Path $deDir 'POC08_MATERIAL_HISTORY_V3.csv'

# Never overwrite accumulated market history during an update.
$historyBackup = $null
if (Test-Path $history) {
    $historyBackup = Join-Path $env:TEMP ('wow112_history_' + [guid]::NewGuid().ToString('N') + '.csv')
    Copy-Item $history $historyBackup -Force
}

$runsUrl = "$Api/repos/$Owner/$Repo/actions/workflows/$Workflow/runs?branch=$([uri]::EscapeDataString($Branch))&status=success&per_page=10"
Say 'Checking latest successful DE build on GitHub...'
$runs = Invoke-RestMethod -Uri $runsUrl -Headers $Headers -Method Get
$run = @($runs.workflow_runs | Where-Object { $_.conclusion -eq 'success' -and $_.head_branch -eq $Branch } | Sort-Object run_number -Descending | Select-Object -First 1)
if (-not $run) { throw 'No successful DE workflow run found.' }
$run = $run[0]

$artUrl = "$Api/repos/$Owner/$Repo/actions/runs/$($run.id)/artifacts?per_page=100"
$arts = Invoke-RestMethod -Uri $artUrl -Headers $Headers -Method Get
$artifact = @($arts.artifacts | Where-Object { -not $_.expired -and $_.name.StartsWith($ArtifactPrefix) } | Sort-Object id -Descending | Select-Object -First 1)
if (-not $artifact) { throw "No non-expired artifact matching $ArtifactPrefix found for run $($run.id)." }
$artifact = $artifact[0]

$remoteVersion = "run_id=$($run.id)`nrun_number=$($run.run_number)`nhead_sha=$($run.head_sha)`nartifact_id=$($artifact.id)`nartifact_name=$($artifact.name)`n"
if ((Test-Path $localExe) -and (Test-Path $versionFile)) {
    $localVersion = Get-Content $versionFile -Raw -ErrorAction SilentlyContinue
    if ($localVersion -eq $remoteVersion) {
        Say "Already latest: run #$($run.run_number), sha=$($run.head_sha.Substring(0,12))" Green
        if (-not $NoLaunch) {
            $launcher = Join-Path $InstallRoot 'START_AH.bat'
            if (Test-Path $launcher) { & $launcher; exit $LASTEXITCODE }
            Say 'START_AH.bat not found. Update completed; launch a DE_LAB .bat manually.' Yellow
        }
        exit 0
    }
}

$tmpRoot = Join-Path $env:TEMP ('wow112_ah_latest_' + [guid]::NewGuid().ToString('N'))
$tmpZip = Join-Path $tmpRoot 'artifact.zip'
$tmpOut = Join-Path $tmpRoot 'out'
New-Item -ItemType Directory -Force -Path $tmpRoot,$tmpOut | Out-Null

try {
    Say "Downloading artifact $($artifact.name)..."
    try {
        Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $Headers -OutFile $tmpZip -MaximumRedirection 10
    }
    catch {
        $fallback = "$Api/repos/$Owner/$Repo/actions/artifacts/$($artifact.id)/zip"
        Say 'Primary artifact URL failed; trying direct artifact endpoint...' Yellow
        Invoke-WebRequest -Uri $fallback -Headers $Headers -OutFile $tmpZip -MaximumRedirection 10
    }

    if (-not (Test-Path $tmpZip) -or (Get-Item $tmpZip).Length -lt 10000) {
        throw 'Downloaded artifact ZIP is missing or unexpectedly small.'
    }
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpOut -Force
    $exe = Get-ChildItem -Path $tmpOut -Recurse -File -Filter '*.exe' |
        Where-Object { $_.Name -like 'wow112-ah-de-liquidation-*.exe' -or $_.Name -eq 'wow112-headless-android-probe.exe' } |
        Sort-Object Length -Descending | Select-Object -First 1
    if (-not $exe) { throw 'DE executable not found inside artifact.' }

    $bytes = [IO.File]::ReadAllBytes($exe.FullName)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Downloaded executable failed PE/MZ smoke check.' }
    $sha = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $staged = Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe.new'
    Copy-Item $exe.FullName $staged -Force
    if (Test-Path $localExe) {
        Copy-Item $localExe ($localExe + '.previous') -Force
    }
    Move-Item $staged $localExe -Force
    Set-Content -Path $versionFile -Value $remoteVersion -Encoding ASCII
    Set-Content -Path (Join-Path $deDir 'LATEST_EXE_SHA256.txt') -Value $sha -Encoding ASCII

    if ($historyBackup -and (Test-Path $historyBackup)) {
        Copy-Item $historyBackup $history -Force
    }

    Say "UPDATED DE_LAB: run #$($run.run_number) sha=$($run.head_sha.Substring(0,12))" Green
    Say "EXE SHA256: $sha" DarkGreen
}
finally {
    if ($historyBackup -and (Test-Path $historyBackup)) { Remove-Item $historyBackup -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $NoLaunch) {
    $launcher = Join-Path $InstallRoot 'START_AH.bat'
    if (Test-Path $launcher) {
        Say 'Launching START_AH.bat...' Cyan
        & $launcher
        exit $LASTEXITCODE
    }
    Say 'START_AH.bat not found. Update completed; launch a DE_LAB .bat manually.' Yellow
}
