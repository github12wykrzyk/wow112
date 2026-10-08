[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootFull = [IO.Path]::GetFullPath($Root)
$svc = Join-Path $rootFull 'scripts/SummonService.ps1'
if (-not (Test-Path -LiteralPath $svc -PathType Leaf)) { throw "SummonService.ps1 missing: $svc" }

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $svc -Action Status -Root $rootFull | Out-Host
$wasHealthy = ($LASTEXITCODE -eq 0)

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $svc -Action Stop -Root $rootFull | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Safe backup aborted: service stop failed with exit $LASTEXITCODE" }

$backupFailure = $null
try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $svc -Action Backup -Root $rootFull | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Backup failed with exit $LASTEXITCODE" }
} catch {
    $backupFailure = $_
} finally {
    if ($wasHealthy) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $svc -Action Start -Root $rootFull | Out-Host
        if ($LASTEXITCODE -ne 0) {
            if ($backupFailure) { throw "Backup failed and service restart also failed. backup=$($backupFailure.Exception.Message) restart_exit=$LASTEXITCODE" }
            throw "Backup completed but service restart failed with exit $LASTEXITCODE"
        }
    }
}
if ($backupFailure) { throw $backupFailure }
Write-Host 'SAFE BACKUP PASS: data/config copied while service was stopped.'
