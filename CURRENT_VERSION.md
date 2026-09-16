# CURRENT VERSION

## Stable baseline

**V68**

V68 = V67 + AutoPP HARDLOS3D rear-only MovementCore fix, with the currently promoted AutoLootPP v0.14 and LongPickPocket v1.0 runtime lineage. Mining HARDLOS is unchanged.

### Active EXE
`WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe`

- Path: repository root (`/WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe`)
- Size: `4907008` bytes
- SHA256: `b24ebfe0a9fa49ba051911a904fc1dcb531d7c3908a35e77a84376d96b476f27`
- Storage: direct canonical binary in `main`

### Active DLLs
1. `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll`
2. `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll`
3. `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll`
4. `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll`
5. `WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll`
6. `WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll`
7. `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll`
8. `WoWPlayerESP_v1_2_range_sweep.dll`

### V68 MovementCore change
`PPHardSelect()` generates HARDLOS retry candidates relative to target orientation and accepts only the rear hemisphere. There is no front-side fallback. Spoofed player orientation still faces the target for Pick Pocket.

### Promoted PP runtime lineage
- AutoLootPP v0.14 `NOSKIP` is reproduced byte-for-byte from the preserved v0.13 runtime by `artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py`.
- LongPickPocket v1.0 `ALLRANGE_360FACING` is reproduced byte-for-byte from the preserved v0.9 runtime by `artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py`.
- Recovery documentation and binary audits are stored under `artifacts/AutoLootPP/` and `artifacts/LongPickPocket/`.

### Canonical repository representation
The current V68 source of truth is defined jointly by:
- `CURRENT.json`
- `runtime/current.json`
- `baseline/V68/dlls.txt`
- `manifests/SHA256SUMS_V68.txt`
- this document

The active patched EXE is stored directly in the repository root. Historical V67 runtime artifacts remain the exact binary ancestors for the two promoted PP DLLs. MovementCore V68 remains stored as the verified V68 delta under `artifacts/V68/runtime/`.

Verified MovementCore runtime delta:
- `artifacts/V68/runtime/`
- restored MovementCore SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`
- runtime XZ SHA256: `b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a`

Verified MovementCore source:
- `artifacts/V68/source/`
- restored v20 source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- source XZ SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`

The old full-bundle chunks under `archives/` are deprecated and must not be treated as canonical.

### EXE
The active V68 client EXE is stored directly at repository root and is part of the canonical stable baseline. Its required SHA256 is `b24ebfe0a9fa49ba051911a904fc1dcb531d7c3908a35e77a84376d96b476f27`. V68 does not change the EXE relative to V67; the historical deterministic V66 -> V67/V68 Stealth5 patch documentation remains useful for audit/reconstruction, but the direct binary is now the primary artifact.

### Version history
Keep all stable working versions in the repository without an automatic retention limit. New baselines such as V69, V70 and later remain available alongside older versions for rollback and comparison.
