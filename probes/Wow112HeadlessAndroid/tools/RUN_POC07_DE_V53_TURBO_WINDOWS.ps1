param(
    [ValidateRange(1,128)][int]$ItemQueryWindow = 64
)

$ErrorActionPreference = 'Stop'
$env:WOW112_DE_ITEM_QUERY_WINDOW = [string]$ItemQueryWindow
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host 'WoW112 WINDOWS HEADLESS - V5.3 TURBO' -ForegroundColor Cyan
Write-Host "AH: CLASS-SPECIFIC ECONOMIC CEILINGS / RESPONSE-PACED" -ForegroundColor Cyan
Write-Host "ITEM QUERY WINDOW: $ItemQueryWindow" -ForegroundColor Cyan
Write-Host 'OFFLINE EXACT DE GATE / ZERO BUY' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'RUN_POC07_DE_V5_WINDOWS.ps1')
$code = $LASTEXITCODE
Remove-Item Env:WOW112_DE_ITEM_QUERY_WINDOW -ErrorAction SilentlyContinue
exit $code
