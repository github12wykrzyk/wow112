# CURRENT VERSION

## Stable baseline

**V67**

Oryginalny katalog: `baseline/V67/`

### Aktywny EXE

`WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe`

### Aktywne DLL

Zgodnie z `baseline/V67/dlls.txt`:

1. `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll`
2. `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll`
3. `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll`
4. `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll`
5. `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll`
6. `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll`
7. `MovementCore_V66_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_RETRY.dll`
8. `WoWPlayerESP_v1_2_range_sweep.dll`

### Potwierdzone zalozenia V67

- WoW 1.12.1 build 5875 x86.
- klientowy Stealth CD hard cap: 5.0 s dla spellId 1784-1787.
- Guardian v2 pozostaje druga warstwa kontroli Stealth CD.
- F11: toggle AutoPP.
- AutoPP ma player-target guard.
- `NO_POCKETS` blacklistuje GUID do smierci celu.
- PP ma HARDLOS3D retry.
- Mining-first, HARDLOS, Mining dozwolony w combat.
- PlayerESP v1.2 jest aktywny.

### Wazne: AutoStealth

W starszej V43 byl osobny `WoWAutoStealth_5875_v5_CHANNEL_KILLGRACE.dll`.
Nie ma go na aktywnej liscie V67. Nie traktowac ogolnego AutoStealth po wyjsciu z combat jako potwierdzonej funkcji V67 bez osobnego testu/kodu.

### Source completeness

Pelne/aktualne source istnieje dla czesci komponentow, m.in. MovementCore v19, SelectiveRange v10, SpeedFloor v0.4, PlayerESP v1.2 i Guardian v2.
Czesc aktywnych DLL pozostaje binary-patched/source-incomplete. Szczegoly: `docs/BASELINE_AUDIT_V67.md`.
