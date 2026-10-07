from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: SOURCE_VENDOR_V2.ps1 OUTPUT_HOTKEY.ps1')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

old_arm = """Write-Host 'UWAGA: realne zakupy Vendor beda wykonywane do czasu StopAt.' -ForegroundColor Yellow
$arm = Read-Host 'Type VENDOR to arm overnight Vendor-only loop'
if ($arm -cne 'VENDOR') { Status 'USER DECLINED; zero mutation'; exit 0 }
"""
new_arm = """Write-Host 'HOTKEY V: realne zakupy Vendor beda wykonywane do czasu StopAt. AUTO-ARM=YES' -ForegroundColor Yellow
Status 'AUTO ARM from START_AH hotkey V'
"""

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

for label, old, new in [('arm', old_arm, new_arm), ('password', old_pwd, new_pwd)]:
    count = src.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exact anchor once, got {count}')
    src = src.replace(old, new, 1)

for required in [
    "WOW112_F1_ACTION='vendor-best'",
    "WOW112_UNIFIED_DE_MAX_PURCHASES='0'",
    'AH_MUTATION_UNCERTAIN',
    'exact_ids=YES',
    "AUTO ARM from START_AH hotkey V",
    'loaded from local Windows DPAPI launcher profile',
]:
    if required not in src:
        raise SystemExit('missing required marker: ' + required)

Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[BUILD-VENDOR-HOTKEY] PASS')
