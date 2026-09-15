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
`PPHardSelect()` now generates HARDLOS retry candidates relative to target orientation and accepts only the rear hemisphere. It no longer falls back to front-side world-axis candidates. The spoofed player orientation still faces the target for Pick Pocket.

### Repository binary format
DLL snapshots are stored as UTF-8 Base64 under `artifacts/V67` and `artifacts/V68` so the GitHub connector can read them. Run `tools/RESTORE_ARTIFACTS.bat` in a checkout to reconstruct the DLL files byte-for-byte.

The large client EXE is represented by a deterministic patch from the V66 executable. Run `tools/PATCH_EXE_STEALTH5_V67.bat` and verify SHA256.
