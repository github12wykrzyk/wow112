# CURRENT VERSION

## Stable baseline

**V69**

V69 = V68 + zaakceptowany w grze `WoWControlHub V1` oraz ABI-enabled SpeedFloor. Pozostały runtime V68 pozostaje bez zmian.

### Active EXE
`WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe`

- Size: `4907008` bytes
- SHA256: `b24ebfe0a9fa49ba051911a904fc1dcb531d7c3908a35e77a84376d96b476f27`

### V69 change

`WoWControlHub.dll` jest centralnym GUI/config hubem dla build 5875 x86. Otwiera się klawiszem **Insert** i wykrywa providerów przez `W112_CONTROL_API_V1`.

Pierwszym zaakceptowanym providerem jest SpeedFloor. Panel steruje live:
- `Enabled`
- `Minimum Speed`
- `Disable on hostile player`

Użytkownik potwierdził w grze poprawne wyświetlanie panelu i działanie zmian SpeedFloor live.

Accepted TEST provenance:
- work commit: `112447c102226415bdd0d06de7c1e4c7c4946c54`
- GitHub Actions artifact ID: `10457293777`
- inner runnable ZIP SHA256: `9f295803d0c305346407c6114dde3535eed3bfefe7c733ce0924e7d239352291`
- SpeedFloor runtime SHA256: `a4dd0b0c44ecb4863231e0c92bab6767f3336003980fb552dc173448ab4b239c`
- WoWControlHub runtime SHA256: `f444a7c0c4769cc2f9546847fef54d41a0ccb79e823d132b73277e858571cf89`

The accepted ControlHub runtime is the candidate build plus the documented deterministic F10 -> Insert binary patch; see `artifacts/V69/runtime/CONTROLHUB_BINARY_PATCH.txt`.

### Active DLLs
1. `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll`
2. `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll`
3. `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll`
4. `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll`
5. `WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll`
6. `WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll`
7. `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll`
8. `WoWPlayerESP_v1_2_range_sweep.dll`
9. `WoWControlHub.dll`

### Promotion isolation

V69 intentionally does **not** promote concurrent PickPocket/MovementCore experiments from `work`. Stable PickPocket, MovementCore and the other unrelated V68 modules keep their V68 runtime identities.

### Canonical repository representation

V69 is defined jointly by:
- `CURRENT.json`
- `runtime/current.json`
- `baseline/V69/dlls.txt`
- `manifests/SHA256SUMS_V69.txt`
- `src/common/W112ControlAPI.h`
- `src/WoWControlHub/WoWControlHub_v1.c`
- `src/SpeedFloor/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG_RECONSTRUCTED.c`
- `artifacts/V69/ACCEPTED_TEST.txt`
- `artifacts/V69/runtime/CONTROLHUB_BINARY_PATCH.txt`

V68 remains available unchanged for rollback.
