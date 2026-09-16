# CURRENT VERSION

## Stable baseline

**V68**

V68 = V67 + AutoPP HARDLOS3D rear-only fix. Mining HARDLOS is unchanged.

### Active EXE
`WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe`
SHA256: `b24ebfe0a9fa49ba051911a904fc1dcb531d7c3908a35e77a84376d96b476f27`

### Active DLLs
1. `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll`
2. `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll`
3. `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll`
4. `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll`
5. `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll`
6. `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll`
7. `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll`
8. `WoWPlayerESP_v1_2_range_sweep.dll`

### V68 change
`PPHardSelect()` generates HARDLOS retry candidates relative to target orientation and accepts only the rear hemisphere. There is no front-side fallback. Spoofed player orientation still faces the target for Pick Pocket.

### Canonical repository representation
V68 is stored as a delta against V67.

Verified runtime delta:
- `artifacts/V68/runtime/`
- restored MovementCore SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`
- runtime XZ SHA256: `b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a`

Verified source:
- `artifacts/V68/source/`
- restored v20 source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- source XZ SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`

Both artifact directories contain `README_RESTORE.md` with reconstruction commands. All eight Base64-part Git blob SHAs were verified against the local V68 build.

The old full-bundle chunks under `archives/` are deprecated and must not be treated as canonical.

### EXE
The large client EXE is represented by the existing deterministic V66 -> V67/V68 Stealth5 patch path and its SHA256 documentation. V68 does not change the EXE relative to V67.

### Version history
Keep all stable working versions in the repository without an automatic retention limit. New baselines such as V69, V70 and later remain available alongside older versions for rollback and comparison.
