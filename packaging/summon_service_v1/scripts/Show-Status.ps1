[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootFull = [IO.Path]::GetFullPath($Root)
$svc = Join-Path $rootFull 'scripts/SummonService.ps1'
if (-not (Test-Path -LiteralPath $svc -PathType Leaf)) { throw "SummonService.ps1 missing: $svc" }

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $svc -Action Status -Root $rootFull | Out-Host
$statusExit = $LASTEXITCODE

$manifestPath = Join-Path $rootFull 'manifest.json'
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "PACKAGE version=$($manifest.version) source_sha=$($manifest.source_sha) demo_only=$($manifest.demo_only)"
}
$supervisorPidPath = Join-Path $rootFull 'state/supervisor.pid'
if (Test-Path -LiteralPath $supervisorPidPath -PathType Leaf) {
    try {
        $pidValue = [int](Get-Content -LiteralPath $supervisorPidPath -Raw).Trim()
        $p = Get-Process -Id $pidValue -ErrorAction Stop
        $uptime = [DateTime]::Now - $p.StartTime
        Write-Host ("UPTIME {0:dd\.hh\:mm\:ss} supervisor_pid={1}" -f $uptime,$pidValue)
    } catch { Write-Host 'UPTIME unavailable (stale or inaccessible supervisor PID)' }
}
Write-Host "ROOT   $rootFull"
Write-Host "CONFIG $(Join-Path $rootFull 'config/service.json')"
Write-Host "DATA   $(Join-Path $rootFull 'data')"
Write-Host "LOGS   $(Join-Path $rootFull 'logs')"
exit $statusExit
