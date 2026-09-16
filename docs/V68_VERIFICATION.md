# V68 verification

Verified against local package `WoW112_V68_AUTOPP_REARONLY_HARDLOS3D.zip`.

## Canonical model

V68 is a delta against V67. The EXE and seven non-MovementCore DLLs are unchanged from V67. V68 replaces only MovementCore and adds the corresponding v20 source.

## Runtime

Restored file:
`MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll`

- DLL size: `61440`
- DLL SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`
- XZ compression reproduced with `xz -9`
- XZ size: `21596`
- XZ SHA256: `b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a`

Repository Base64 parts under `artifacts/V68/runtime/` were reproduced locally and their Git blob SHA1 values match exactly:

- part000: `a72ca3cc1f67324b2b30ee56b60bca13de6bd176`
- part001: `2f737f8960fd23c47eec75cd64acddd5c053d718`
- part002: `004643b048f74c7a1db2ff1bf6eaf25d95985a7f`
- part003: `34b89d3d2e79795337675153424aaad2d230ce1f`

## Source

Restored source:
`WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c`

- source size: `107833`
- source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- XZ compression reproduced with `xz -9`
- XZ size: `23480`
- XZ SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`

Repository Base64 parts under `artifacts/V68/source/` were reproduced locally and their Git blob SHA1 values match exactly:

- part000: `5647619fa140c44a6733dc9c9dfe7e71a5772898`
- part001: `e26d80002e0afc7bb6b9bffca2c4732a860fef53`
- part002: `79184d7b78b48715b53fe500222f2e15bf565278`
- part003: `7024ad9896df99419b47ddb9ba4610d4a60bdf38`

## Functional scope of V68

- PP HARDLOS3D candidates are generated relative to target orientation.
- Horizontal candidates are restricted to the rear hemisphere.
- No front-side fallback is allowed for AutoPP HARDLOS selection.
- Spoofed player orientation still faces the target for Pick Pocket.
- Mining HARDLOS behavior is unchanged.

## Deprecated artifacts

The experimental full-bundle chunk paths under `archives/` are not canonical and must not be used to define V68. Canonical V68 is `artifacts/V68/runtime/` + `artifacts/V68/source/` on top of V67.
