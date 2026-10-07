param(
    [string]$InstallRoot = '',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = (Get-Location).Path
}

# Windows cmd + powershell.exe can pass a quoted path ending in '\' as a value
# with a stray trailing quote (for example C:\path\"). Normalize that legacy
# invocation here so already-downloaded START_AH_LATEST.bat files self-heal.
$InstallRoot = ([string]$InstallRoot).Trim()
$InstallRoot = $InstallRoot.Trim([char[]]@([char]34, [char]39))
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = (Get-Location).Path
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$ReleaseBase = 'https://github.com/github12wykrzyk/wow112/releases/download/ah-de-latest'
$ZipUrl = "$ReleaseBase/WoW112_DE_LATEST.zip"
$ManifestUrl = "$ReleaseBase/WoW112_DE_LATEST.txt"
$Headers = @{ 'User-Agent' = 'WoW112-AH-Latest-Bootstrap/4.0' }

function Say([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
}

function Install-FileIfChanged([string]$Source, [string]$Target) {
    if (-not (Test-Path $Source)) { throw "Required release file missing: $Source" }
    $parent = Split-Path -Parent $Target
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $replace = $true
    if (Test-Path $Target) {
        $oldSha = (Get-FileHash $Target -Algorithm SHA256).Hash
        $newSha = (Get-FileHash $Source -Algorithm SHA256).Hash
        $replace = $oldSha -ne $newSha
    }
    if (-not $replace) { return $false }
    $tmp = $Target + '.release.tmp'
    try {
        Copy-Item $Source $tmp -Force
        Move-Item $tmp $Target -Force
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return $true
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
Say 'WoW112 AH - LATEST / CORP-FRIENDLY V4' Cyan
Say 'Release-only runtime channel. No raw.githubusercontent.com. No GitHub API.' DarkCyan
Say 'Vendor Stable EXE pozostaje nietkniety.' DarkCyan
Say '============================================================' Cyan

$deDir = Join-Path $InstallRoot 'DE_LAB'
$launcherDir = Join-Path $InstallRoot '_launcher'
New-Item -ItemType Directory -Force -Path $deDir,$launcherDir | Out-Null
$localExe = Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe'
$versionFile = Join-Path $deDir 'LATEST_GITHUB_BUILD.txt'

Say 'Reading rolling DE release metadata...'
$remoteManifest = (Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -Headers $Headers).Content
if ([string]::IsNullOrWhiteSpace($remoteManifest)) { throw 'Rolling release manifest is empty.' }

$remote = @{}
foreach ($line in ($remoteManifest -split "`r?`n")) {
    if ($line -match '^([^=]+)=(.*)$') { $remote[$Matches[1].Trim()] = $Matches[2].Trim() }
}
if (-not $remote.ContainsKey('ZIP_SHA256') -or -not $remote.ContainsKey('HEAD_SHA')) {
    throw 'Rolling release manifest is missing ZIP_SHA256 or HEAD_SHA.'
}
if (-not $remote.ContainsKey('RUNTIME_CHANNEL') -or $remote['RUNTIME_CHANNEL'] -ne 'GITHUB_RELEASE_ONLY') {
    throw 'Rolling release is not marked RUNTIME_CHANNEL=GITHUB_RELEASE_ONLY.'
}
if (-not $remote.ContainsKey('LAUNCHER_BUNDLE') -or $remote['LAUNCHER_BUNDLE'] -ne 'YES') {
    throw 'Rolling release does not contain the required launcher bundle contract.'
}

$tmpRoot = Join-Path $env:TEMP ('wow112_ah_release_' + [guid]::NewGuid().ToString('N'))
$tmpZip = Join-Path $tmpRoot 'WoW112_DE_LATEST.zip'
$tmpOut = Join-Path $tmpRoot 'out'
New-Item -ItemType Directory -Force -Path $tmpRoot,$tmpOut | Out-Null

try {
    Say 'Downloading latest DE + launcher release ZIP...'
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

    $bundleStart = Join-Path $tmpOut 'launcher\START_AH.bat'
    $bundleMenu = Join-Path $tmpOut 'launcher\_launcher\START_AH.ps1'
    $bundleDe = Join-Path $tmpOut 'launcher\_launcher\RUN_DE_LAB.ps1'
    $bundleStarter = Join-Path $tmpOut 'bootstrap\START_AH_LATEST.bat'
    $bundleBootstrap = Join-Path $tmpOut 'bootstrap\bootstrap_latest.ps1'
    foreach ($required in @($bundleStart,$bundleMenu,$bundleDe,$bundleStarter,$bundleBootstrap)) {
        if (-not (Test-Path $required) -or (Get-Item $required).Length -lt 100) {
            throw "Release launcher bundle incomplete: $required"
        }
    }

    $bytes = [IO.File]::ReadAllBytes($exe.FullName)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'Downloaded executable failed PE/MZ smoke check.'
    }
    $exeSha = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $exeUpdated = $false
    if (-not (Test-Path $localExe) -or (Get-FileHash $localExe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $exeSha) {
        $staged = Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe.new'
        Copy-Item $exe.FullName $staged -Force
        if (Test-Path $localExe) { Copy-Item $localExe ($localExe + '.previous') -Force }
        Move-Item $staged $localExe -Force
        $exeUpdated = $true
    }

    $launcherUpdates = 0
    if (Install-FileIfChanged $bundleStart (Join-Path $InstallRoot 'START_AH.bat')) { $launcherUpdates++ }
    if (Install-FileIfChanged $bundleMenu (Join-Path $launcherDir 'START_AH.ps1')) { $launcherUpdates++ }
    if (Install-FileIfChanged $bundleDe (Join-Path $launcherDir 'RUN_DE_LAB.ps1')) { $launcherUpdates++ }
    if (Install-FileIfChanged $bundleStarter (Join-Path $InstallRoot 'START_AH_LATEST.bat')) { $launcherUpdates++ }
    [void](Install-FileIfChanged $bundleBootstrap (Join-Path $launcherDir 'bootstrap_latest.ps1'))

    $patched = Refresh-LiveWrapperHash -Directory $deDir -ExeSha $exeSha
    Set-Content -Path $versionFile -Value $remoteManifest -Encoding ASCII
    Set-Content -Path (Join-Path $deDir 'LATEST_EXE_SHA256.txt') -Value $exeSha -Encoding ASCII

    $shortSha = $remote['HEAD_SHA'].Substring(0,[Math]::Min(12,$remote['HEAD_SHA'].Length))
    if ($exeUpdated) { Say ("DE UPDATED: {0}" -f $shortSha) Green } else { Say ("DE already latest: {0}" -f $shortSha) Green }
    Say "Release ZIP SHA256: $zipSha" DarkGreen
    Say "EXE SHA256: $exeSha" DarkGreen
    Say "Launcher files updated from same verified release ZIP: $launcherUpdates" DarkGreen
    Say "Live wrapper hash lines refreshed: $patched" DarkGreen
    Say 'RUNTIME CHANNEL PASS: github.com release assets only.' Green
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
    Say 'START_AH.bat not found. Update completed.' Yellow
}
