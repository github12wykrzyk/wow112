[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedSourceSha,
    [switch]$RequireDemoOnly,
    [switch]$RequireFinal
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($PackageRoot)
$manifestPath = Join-Path $root 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'manifest.json missing' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($manifest.schema_version -ne 1) { throw 'Unsupported manifest schema_version' }
if ($manifest.product -ne 'WoW112 Summon Service V1') { throw 'Unexpected product identity' }
if (($manifest.source_sha -as [string]).ToLowerInvariant() -ne $ExpectedSourceSha.ToLowerInvariant()) { throw "source_sha mismatch expected=$ExpectedSourceSha actual=$($manifest.source_sha)" }
if (($manifest.version -as [string]).Length -lt 1) { throw 'version missing' }
if (($manifest.built_utc -as [string]).Length -lt 10) { throw 'built_utc missing' }
if ($manifest.package_layout_version -ne 1) { throw 'package_layout_version mismatch' }
if ($manifest.config_schema_version -ne 1) { throw 'config_schema_version mismatch' }
if ($manifest.data_layout_version -ne 1) { throw 'data_layout_version mismatch' }
if ($manifest.compatibility.operating_system -ne 'Windows 11') { throw 'Windows 11 compatibility marker missing' }
if (($manifest.compatibility.service_runtime_contract -as [string]) -ne 'summon-service-v1') { throw 'service runtime contract marker missing' }
if (($manifest.compatibility.operator_console_contract -as [string]) -ne 'summon-operator-console-v1') { throw 'operator console contract marker missing' }
if ($RequireDemoOnly -and $manifest.demo_only -ne $true) { throw 'Expected DEMO_ONLY package' }
if ($RequireFinal -and $manifest.demo_only -ne $false) { throw 'Expected final package but demo_only is true' }
if ($RequireDemoOnly -and $RequireFinal) { throw 'RequireDemoOnly and RequireFinal are mutually exclusive' }

$required = @('bin/WoW112SummonService.exe','bin/WoW112SummonOperatorConsole.exe')
$declaredRequired = @($manifest.required_executables | ForEach-Object { $_ -as [string] })
foreach ($rel in $required) {
    if ($declaredRequired -notcontains $rel) { throw "required_executables missing $rel" }
    $full = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "required executable missing: $rel" }
}

$seen = @{}
foreach ($entry in @($manifest.files)) {
    $rel = $entry.path -as [string]
    if ([string]::IsNullOrWhiteSpace($rel)) { throw 'manifest file entry has empty path' }
    if ($seen.ContainsKey($rel)) { throw "duplicate manifest path: $rel" }
    $seen[$rel] = $true
    if ([IO.Path]::IsPathRooted($rel) -or $rel.Contains('..')) { throw "unsafe manifest path: $rel" }
    $expected = ($entry.sha256 -as [string]).ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw "bad SHA256: $rel" }
    $full = [IO.Path]::GetFullPath((Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "path escapes root: $rel" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "manifest file missing: $rel" }
    $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA256 mismatch: $rel" }
}
foreach ($rel in $required) { if (-not $seen.ContainsKey($rel)) { throw "required executable is not immutable-hash pinned: $rel" } }

foreach ($mutable in @('config/service.json','data/','logs/','state/','backups/')) {
    if (@($manifest.mutable_paths) -notcontains $mutable) { throw "mutable_paths missing $mutable" }
}

$forbidden = @(
    (Join-Path $root 'state/credential.dpapi'),
    (Join-Path $root '.env'),
    (Join-Path $root 'secrets.json')
)
foreach ($p in $forbidden) { if (Test-Path -LiteralPath $p) { throw "credential-bearing file must not ship: $p" } }

Write-Host "RELEASE CONTRACT PASS source_sha=$($manifest.source_sha) version=$($manifest.version) demo_only=$($manifest.demo_only) files=$($seen.Count)"
