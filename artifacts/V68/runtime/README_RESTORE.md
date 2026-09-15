# Restore MovementCore V68 runtime

The DLL archive is split into four Base64 text parts:

- `MovementCore_V68.dll.xz.b64.part000`
- `MovementCore_V68.dll.xz.b64.part001`
- `MovementCore_V68.dll.xz.b64.part002`
- `MovementCore_V68.dll.xz.b64.part003`

## Expected hashes

- XZ archive SHA256: `b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a`
- Restored DLL SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`
- XZ size: `21596` bytes
- DLL size: `61440` bytes

Restored file name:

`MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll`

## PowerShell restore

```powershell
$parts = 0..3 | ForEach-Object { Get-Content ("MovementCore_V68.dll.xz.b64.part{0:D3}" -f $_) -Raw }
[IO.File]::WriteAllBytes("MovementCore_V68.dll.xz", [Convert]::FromBase64String(($parts -join "").Trim()))
Get-FileHash .\MovementCore_V68.dll.xz -Algorithm SHA256
xz -d -k .\MovementCore_V68.dll.xz
Rename-Item .\MovementCore_V68.dll 'MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll'
Get-FileHash .\MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll -Algorithm SHA256
```
