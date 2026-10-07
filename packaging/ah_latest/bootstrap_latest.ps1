param(
    [string]$InstallRoot = '',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = (Get-Location).Path
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$ReleaseBase = 'https://github.com/github12wykrzyk/wow112/releases/download/ah-de-latest'
$ZipUrl = "$ReleaseBase/WoW112_DE_LATEST.zip"
$ManifestUrl = "$ReleaseBase/WoW112_DE_LATEST.txt"
$RawLauncherBase = 'https://raw.githubusercontent.com/github12wykrzyk/wow112/refs/heads/dev/windows-ah-de-liquidation-v3/packaging/ah_latest/launcher'
$Headers = @{ 'User-Agent' = 'WoW112-AH-Latest-Bootstrap/2.3' }

function Say([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
}

function Sync-LatestLauncher([string]$Directory) {
    $launcherDir = Join-Path $Directory '_launcher'
    New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
    $targets = @(
        @{ Url = "$RawLauncherBase/START_AH.bat"; Target = (Join-Path $Directory 'START_AH.bat') },
        @{ Url = "$RawLauncherBase/_launcher/START_AH.ps1"; Target = (Join-Path $launcherDir 'START_AH.ps1') },
        @{ Url = "$RawLauncherBase/_launcher/RUN_DE_LAB.ps1"; Target = (Join-Path $launcherDir 'RUN_DE_LAB.ps1') }
    )
    $updated = 0
    foreach ($entry in $targets) {
        $tmp = $entry.Target + '.latest.tmp'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $entry.Url -Headers $Headers -OutFile $tmp
            if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 100) {
                throw "launcher download missing or unexpectedly small: $($entry.Url)"
            }
            $replace = $true
            if (Test-Path $entry.Target) {
                $oldSha = (Get-FileHash $entry.Target -Algorithm SHA256).Hash
                $newSha = (Get-FileHash $tmp -Algorithm SHA256).Hash
                $replace = $oldSha -ne $newSha
            }
            if ($replace) {
                Move-Item $tmp $entry.Target -Force
                $updated++
            } else {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $updated
}

function Refresh-LiveWrapperHash([string]$Directory, [string]$ExeSha) {
    $patched = 0
    foreach ($file in @(Get-ChildItem -Path $Directory -File -Filter 'RUN_DE_*.ps1' -ErrorAction SilentlyContinue)) {
        $text = Get-Content $file.FullName -Raw
        $pattern = "(?m)^`$expectedExeSha='[0-9a-fA-F]{64}'\s*$"
        $replacement = "`$expectedExeSha='$ExeSha'"
        $new = [regex]::Replace($text, $pattern, $replacement)
        if ($new -ne $text) {
            Set-Content -Path $file.FullName -Value $new -Encoding UTF8
            $patched++
        }
    }
    return $patched
}

Say '============================================================' Cyan
Say 'WoW112 AH - UNIVERSAL LATEST BOOTSTRAP' Cyan
Say 'Vendor Stable is preserved. DE_LAB + launchers are updated from GitHub.' DarkCyan
Say '============================================================' Cyan

$deDir = Join-Path $InstallRoot 'DE_LAB'
New-Item -ItemType Directory -Force -Path $deDir | Out-Null
$localExe = Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe'
$versionFile = Join-Path $deDir 'LATEST_GITHUB_BUILD.txt'
$history = Join-Path $deDir 'POC08_MATERIAL_HISTORY_V3.csv'

Say 'Syncing latest launcher wrappers...'
$launcherUpdates = Sync-LatestLauncher -Directory $InstallRoot
Say ("Launcher wrapper updates: {0}" -f $launcherUpdates) DarkGreen

Say 'Checking rolling DE release manifest...'
$remoteManifest = (Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -Headers $Headers).Content
if ([string]::IsNullOrWhiteSpace($remoteManifest)) { throw 'Rolling release manifest is empty.' }

$remote = @{}
foreach ($line in ($remoteManifest -split "`r?`n")) {
    if ($line -match '^([^=]+)=(.*)$') { $remote[$Matches[1].Trim()] = $Matches[2].Trim() }
}
if (-not $remote.ContainsKey('ZIP_SHA256') -or -not $remote.ContainsKey('HEAD_SHA')) {
    throw 'Rolling release manifest is missing ZIP_SHA256 or HEAD_SHA.'
}

if ((Test-Path $localExe) -and (Test-Path $versionFile)) {
    $localVersion = Get-Content $versionFile -Raw -ErrorAction SilentlyContinue
    if ($localVersion -eq $remoteManifest) {
        $sha = (Get-FileHash $localExe -Algorithm SHA256).Hash.ToLowerInvariant()
        $patched = Refresh-LiveWrapperHash -Directory $deDir -ExeSha $sha
        Say ("Already latest: sha={0}; launcher_updates={1}; wrapper_hash_updates={2}" -f $remote['HEAD_SHA'].Substring(0,[Math]::Min(12,$remote['HEAD_SHA'].Length)),$launcherUpdates,$patched) Green
        if (-not $NoLaunch) {
            $launcher = Join-Path $InstallRoot 'START_AH.bat'
            if (Test-Path $launcher) { & $launcher; exit $LASTEXITCODE }
            Say 'START_AH.bat not found. Update completed; launch a DE_LAB .bat manually.' Yellow
        }
        exit 0
    }
}

$tmpRoot = Join-Path $env:TEMP ('wow112_ah_latest_' + [guid]::NewGuid().ToString('N'))
$tmpZip = Join-Path $tmpRoot 'WoW112_DE_LATEST.zip'
$tmpOut = Join-Path $tmpRoot 'out'
New-Item -ItemType Directory -Force -Path $tmpRoot,$tmpOut | Out-Null

$historyBackup = $null
if (Test-Path $history) {
    $historyBackup = Join-Path $tmpRoot 'POC08_MATERIAL_HISTORY_V3.csv'
    Copy-Item $history $historyBackup -Force
}

try {
    Say 'Downloading public WoW112_DE_LATEST.zip...'
    Invoke-WebRequest -UseBasicParsing -Uri $ZipUrl -Headers $Headers -OutFile $tmpZip
    if (-not (Test-Path $tmpZip) -or (Get-Item $tmpZip).Length -lt 10000) {
        throw 'Downloaded release ZIP is missing or unexpectedly small.'
    }

    $zipSha = (Get-FileHash $tmpZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedZipSha = ([string]$remote['ZIP_SHA256']).ToLowerInvariant()
    if ($zipSha -ne $expectedZipSha) {
        throw "Release ZIP SHA256 mismatch. expected=$expectedZipSha actual=$zipSha"
    }

    Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpOut -Force
    $exe = Get-ChildItem -Path $tmpOut -Recurse -File -Filter '*.exe' |
        Where-Object { $_.Name -like 'wow112-ah-de-liquidation-*.exe' -or $_.Name -eq 'wow112-headless-android-probe.exe' } |
        Sort-Object Length -Descending | Select-Object -First 1
    if (-not $exe) { throw 'DE executable not found inside release ZIP.' }

    $bytes = [IO.File]::ReadAllBytes($exe.FullName)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'Downloaded executable failed PE/MZ smoke check.'
    }
    $exeSha = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $staged = Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe.new'
    Copy-Item $exe.FullName $staged -Force
    if (Test-Path $localExe) { Copy-Item $localExe ($localExe + '.previous') -Force }
    Move-Item $staged $localExe -Force

    if ($historyBackup -and (Test-Path $historyBackup)) {
        Copy-Item $historyBackup $history -Force
    }

    $patched = Refresh-LiveWrapperHash -Directory $deDir -ExeSha $exeSha
    Set-Content -Path $versionFile -Value $remoteManifest -Encoding ASCII
    Set-Content -Path (Join-Path $deDir 'LATEST_EXE_SHA256.txt') -Value $exeSha -Encoding ASCII

    Say ("UPDATED DE_LAB: sha={0}" -f $remote['HEAD_SHA'].Substring(0,[Math]::Min(12,$remote['HEAD_SHA'].Length))) Green
    Say "Release ZIP SHA256: $zipSha" DarkGreen
    Say "EXE SHA256: $exeSha" DarkGreen
    Say "Launcher wrapper updates: $launcherUpdates" DarkGreen
    Say "Live wrapper hash lines refreshed: $patched" DarkGreen
}
finally {
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
