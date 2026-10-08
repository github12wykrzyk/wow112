param(
    [int]$Cycles = 0,
    [switch]$Faults,
    [switch]$Whispers,
    [switch]$Payments,
    [switch]$QualityOnly,
    [switch]$Live
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$harness = Join-Path $PSScriptRoot 'harness.py'

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python is required for the terminal soak harness.'
}

$argsList = @($harness)
if ($Cycles -gt 0) { $argsList += @('--cycles', [string]$Cycles) }
if ($Faults) { $argsList += '--faults' }
if ($Whispers) { $argsList += '--whispers' }
if ($Payments) { $argsList += '--payments' }
if ($QualityOnly) { $argsList += '--quality-only' }
if ($Live) { $argsList += '--live' }

# Default UX is a live-preflight/full-quality request. The Python harness stops
# before credentials if required canonical headless primitives are absent.
Push-Location $root
try {
    & python @argsList
    $code = $LASTEXITCODE
    if ($code -ne 0) { exit $code }
} finally {
    Pop-Location
}
