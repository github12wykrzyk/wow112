[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputBinDir,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceSha,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputZip,
    [switch]$DemoOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sourceRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$requiredBinaryNames = @('WoW112SummonService.exe','WoW112SummonOperatorConsole.exe')
foreach($required in $requiredBinaryNames) {
    if(-not (Test-Path -LiteralPath (Join-Path $InputBinDir $required) -PathType Leaf)) { throw "Missing binary input: $required" }
}
$stage = Join-Path $env:TEMP ('summon-package-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach($name in @('scripts','docs')) { Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $stage $name) -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $stage 'bin'),(Join-Path $stage 'config'),(Join-Path $stage 'data'),(Join-Path $stage 'logs'),(Join-Path $stage 'state'),(Join-Path $stage 'backups') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $InputBinDir 'WoW112SummonService.exe') -Destination (Join-Path $stage 'bin/WoW112SummonService.exe')
    Copy-Item -LiteralPath (Join-Path $InputBinDir 'WoW112SummonOperatorConsole.exe') -Destination (Join-Path $stage 'bin/WoW112SummonOperatorConsole.exe')
    foreach($name in @('START_SUMMON_SERVICE.cmd','STOP_SUMMON_SERVICE.cmd','STATUS_SUMMON_SERVICE.cmd','OPEN_CONSOLE.cmd','BACKUP_DATA.cmd','ROLLBACK.cmd','UPGRADE_SUMMON_SERVICE.cmd')) { Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $stage $name) }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'README.md') -Destination (Join-Path $stage 'README.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config/service.example.json') -Destination (Join-Path $stage 'config/service.example.json')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config/service.example.json') -Destination (Join-Path $stage 'config/service.json')
    Set-Content -LiteralPath (Join-Path $stage 'VERSION') -Value $Version -Encoding ASCII
    $stageName = Split-Path -Leaf $stage
    $mutablePrefixes = @('config/service.json','data/','logs/','state/','backups/')
    $entries = @()
    Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
        $parts = New-Object Collections.Generic.List[string]
        $parts.Insert(0, $_.Name)
        $dir = $_.Directory
        while($null -ne $dir -and $dir.Name -ne $stageName) {
            $parts.Insert(0, $dir.Name)
            $dir = $dir.Parent
        }
        if($null -eq $dir) { throw "Cannot derive package-relative path for $($_.FullName)" }
        $rel = ($parts -join '/')
        if($mutablePrefixes -contains $rel -or $rel.StartsWith('data/') -or $rel.StartsWith('logs/') -or $rel.StartsWith('state/') -or $rel.StartsWith('backups/')) { return }
        $entries += [ordered]@{path=$rel;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $requiredExecutables = @(
        'bin/WoW112SummonService.exe',
        'bin/WoW112SummonOperatorConsole.exe'
    )
    $manifest=[ordered]@{
        schema_version=1
        product='WoW112 Summon Service V1'
        version=$Version
        source_sha=$SourceSha.ToLowerInvariant()
        built_utc=[DateTime]::UtcNow.ToString('o')
        demo_only=[bool]$DemoOnly
        package_layout_version=1
        config_schema_version=1
        data_layout_version=1
        compatibility=[ordered]@{
            operating_system='Windows 11'
            powershell='Windows PowerShell 5.1+'
            service_runtime_contract='summon-service-v1'
            operator_console_contract='summon-operator-console-v1'
        }
        required_executables=$requiredExecutables
        mutable_paths=@('config/service.json','data/','logs/','state/','backups/')
        files=$entries
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
    if(Test-Path -LiteralPath $OutputZip){Remove-Item -LiteralPath $OutputZip -Force}
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutputZip -CompressionLevel Optimal
    $hash=(Get-FileHash -LiteralPath $OutputZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath ($OutputZip + '.sha256') -Value "$hash  $([IO.Path]::GetFileName($OutputZip))" -Encoding ASCII
    Write-Host "PACKAGE=$OutputZip"
    Write-Host "SHA256=$hash"
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
