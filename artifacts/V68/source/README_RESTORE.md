# Restore WoWMovementCore v20 source

The source archive is split into four Base64 text parts:

- `WoWMovementCore_v20.c.xz.b64.part000`
- `WoWMovementCore_v20.c.xz.b64.part001`
- `WoWMovementCore_v20.c.xz.b64.part002`
- `WoWMovementCore_v20.c.xz.b64.part003`

## Expected hashes

- XZ archive SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`
- Restored C source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- XZ size: `23480` bytes
- C source size: `107833` bytes

## PowerShell restore

```powershell
$parts = 0..3 | ForEach-Object { Get-Content ("WoWMovementCore_v20.c.xz.b64.part{0:D3}" -f $_) -Raw }
[IO.File]::WriteAllBytes("WoWMovementCore_v20.c.xz", [Convert]::FromBase64String(($parts -join "").Trim()))
Get-FileHash .\WoWMovementCore_v20.c.xz -Algorithm SHA256
xz -d -k .\WoWMovementCore_v20.c.xz
Get-FileHash .\WoWMovementCore_v20.c -Algorithm SHA256
```

The restored source corresponds to `WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c`.
