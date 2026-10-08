[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Package,
    [string]$ExpectedSourceSha
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootFull = [IO.Path]::GetFullPath($Root)
$packageFull = [IO.Path]::GetFullPath($Package)
$svc = Join-Path $rootFull 'scripts/SummonService.ps1'
if (-not (Test-Path -LiteralPath $svc -PathType Leaf)) { throw "SummonService.ps1 missing: $svc" }
if (-not (Test-Path -LiteralPath $packageFull)) { throw "Upgrade package missing: $packageFull" }
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceSha) -and $ExpectedSourceSha -notmatch '^[0-9a-fA-F]{40}$') { throw 'expected-source-sha must be exact 40-hex SHA' }

$stage = Join-Path $env:TEMP ('summon-upgrade-preflight-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $item = Get-Item -LiteralPath $packageFull
    if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $packageFull -Force | Copy-Item -Destination $stage -Recurse -Force }
    else { Expand-Archive -LiteralPath $packageFull -DestinationPath $stage -Force }

    $verifyArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$svc,'-Action','Verify','-Root',$stage)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceSha)) { $verifyArgs += @('-ExpectedSourceSha',$ExpectedSourceSha) }
    & powershell.exe @verifyArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Incoming package verification failed with exit $LASTEXITCODE; current service was not mutated." }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $svc -Action Stop -Root $rootFull | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Upgrade aborted: service stop failed with exit $LASTEXITCODE" }

$upgradeArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$svc,'-Action','Upgrade','-Root',$rootFull,'-Package',$packageFull)
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceSha)) { $upgradeArgs += @('-ExpectedSourceSha',$ExpectedSourceSha) }
& powershell.exe @upgradeArgs | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Upgrade failed with exit $LASTEXITCODE; no automatic retry will be attempted." }
Write-Host 'SAFE UPGRADE PASS.'
