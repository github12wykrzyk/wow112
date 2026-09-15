param(
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\restored\V68')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$partsDir = Join-Path $root 'archives\V68_FULL_NO_EXE_BUNDLE_B64'
$workDir = Join-Path $root '_restore_tmp'
$xzPath = Join-Path $workDir 'WoW112_V68_FULL_NO_EXE.tar.xz'
$expected = '19df89d9b944388d275077222cb3bc4765f81e0ad5ea94cdc7a401ab66e3f17d'

Write-Host '[V68] Restoring bundle from Base64 chunks...'
if (!(Test-Path $partsDir)) { throw "Missing parts directory: $partsDir" }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$parts = Get-ChildItem -Path $partsDir -Filter 'part*.txt' | Sort-Object Name
if ($parts.Count -ne 23) { throw "Expected 23 parts, found $($parts.Count)" }
$b64 = ($parts | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes($xzPath, [Convert]::FromBase64String($b64))

$actual = (Get-FileHash -Algorithm SHA256 $xzPath).Hash.ToLowerInvariant()
Write-Host "[V68] XZ SHA256: $actual"
if ($actual -ne $expected) { throw "Bundle SHA256 mismatch. Expected $expected" }

$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (!$tar) { throw 'tar.exe not found. Windows 10/11 normally includes it.' }
& $tar.Source -xJf $xzPath -C $OutputDir
if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }

Write-Host "[V68] Restored to: $OutputDir"
Write-Host '[V68] EXE is intentionally not stored in this bundle; use the documented V66->V67/V68 EXE patch path.'
