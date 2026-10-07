from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: SOURCE_VENDOR_V2.ps1 OUTPUT_HOTKEY.ps1')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

def rep(label: str, old: str, new: str) -> None:
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit(f'{label}: expected exact anchor once, got {n}')
    src = src.replace(old, new, 1)

# Keep the proven Vendor V2 body intact. Only adapt its install root, arm prompt and
# password source so START_AH can launch it non-interactively with the local DPAPI profile.
rep('root parameter',
    "param(\n    [string]$Account = '',",
    "param(\n    [Parameter(Mandatory=$true)][string]$Root,\n    [string]$Account = '',")
rep('vendor directory',
    "$ErrorActionPreference = 'Stop'\nSet-Location $PSScriptRoot\n$exe = Join-Path $PSScriptRoot 'wow112-ah-windows.exe'",
    "$ErrorActionPreference = 'Stop'\n$vendorDir = Join-Path ([IO.Path]::GetFullPath($Root)) 'VENDOR_STABLE'\nSet-Location $vendorDir\n$exe = Join-Path $vendorDir 'wow112-ah-windows.exe'")
src = src.replace('Join-Path $PSScriptRoot ', 'Join-Path $vendorDir ')

old_arm = """Write-Host 'UWAGA: realne zakupy Vendor beda wykonywane do czasu StopAt.' -ForegroundColor Yellow
$arm = Read-Host 'Type VENDOR to arm overnight Vendor-only loop'
if ($arm -cne 'VENDOR') { Status 'USER DECLINED; zero mutation'; exit 0 }
"""
new_arm = """Write-Host 'HOTKEY V: realne zakupy Vendor beda wykonywane do czasu StopAt. AUTO-ARM=YES' -ForegroundColor Yellow
Status 'AUTO ARM from START_AH hotkey V'
"""
rep('arm', old_arm, new_arm)

old_pwd = """$sec = Read-Host 'Haslo WoW' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $env:WOW112_PASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
"""
new_pwd = """$ptr = [IntPtr]::Zero
try {
    if ([string]::IsNullOrWhiteSpace($env:WOW112_PASSWORD)) {
        $sec = Read-Host 'Haslo WoW' -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $env:WOW112_PASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } else {
        Write-Host 'Haslo: loaded from local Windows DPAPI launcher profile.' -ForegroundColor DarkGreen
    }
"""
rep('password', old_pwd, new_pwd)

for required in [
    "[Parameter(Mandatory=$true)][string]$Root",
    "$vendorDir = Join-Path ([IO.Path]::GetFullPath($Root)) 'VENDOR_STABLE'",
    "WOW112_F1_ACTION='vendor-best'",
    "WOW112_UNIFIED_DE_MAX_PURCHASES='0'",
    'AH_MUTATION_UNCERTAIN',
    'exact_ids=YES',
    "AUTO ARM from START_AH hotkey V",
    'loaded from local Windows DPAPI launcher profile',
]:
    if required not in src:
        raise SystemExit('missing required marker: ' + required)

if 'Join-Path $PSScriptRoot ' in src:
    raise SystemExit('unconverted PSScriptRoot join remains')

Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[BUILD-VENDOR-HOTKEY] PASS')
