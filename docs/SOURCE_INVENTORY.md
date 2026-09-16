# Active runtime source inventory

Stan dla stabilnego baseline **V68**.

## Canonical normal source

| Runtime module | Source status | Canonical path |
| --- | --- | --- |
| `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll` | NORMAL SOURCE | `src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c` |

MovementCore source jest zweryfikowany przez rozmiar i SHA256 oraz ma niezalezny recovery archive w `artifacts/V68/source/`.

## Active modules without indexed normal source

Ponizsze DLL sa aktywne w V68 i maja zweryfikowane runtime SHA256, ale pelne normalne source `.c/.cpp` nie jest obecnie indeksowane w repo:

| Runtime module | Repository state | Recovery/runtime evidence |
| --- | --- | --- |
| `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll` | SOURCE NOT INDEXED | compressed runtime artifact under `artifacts/V67/runtime/` |
| `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll` | SOURCE NOT INDEXED | compressed runtime artifact under `artifacts/V67/runtime/` |
| `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll` | SOURCE NOT INDEXED | compressed runtime artifact under `artifacts/V67/runtime/` |
| `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll` | SOURCE NOT INDEXED | runtime artifact under `baseline/V67/` and compressed artifact under `artifacts/V67/runtime/` |
| `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll` | SOURCE NOT INDEXED | compressed runtime artifact under `artifacts/V67/runtime/` |
| `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll` | SOURCE NOT INDEXED | compressed runtime artifact under `artifacts/V67/runtime/` |
| `WoWPlayerESP_v1_2_range_sweep.dll` | SOURCE NOT INDEXED | compressed runtime artifact under `artifacts/V67/runtime/` |

`SOURCE NOT INDEXED` nie oznacza, ze source nigdy nie istnial. Oznacza tylko, ze w aktualnym drzewie Git nie ma pelnego, normalnego pliku source powiazanego jednoznacznie z aktywnym DLL.

## Recovery priority

Najwiekszy zysk developerski da odzyskanie source w tej kolejnosci funkcjonalnej:

1. Pick Pocket stack: `WoWAutoLootPP`, `WoWLongPickPocket`, `PickPocketSelectiveRange`.
2. `WoWPositionalSpoof` — wspolny element zachowania pozycyjnego/stealth i ryzyko regresji miedzy funkcjami.
3. `WoWStealthCDGuardian` i `WoWNonPvPSpeedFloor` — mniejsze, wyspecjalizowane moduly.
4. `WoWPlayerESP` — modul bardziej niezalezny od glownego AutoPP/MovementCore workflow.

Priorytet jest developerski: chodzi o zmniejszenie czasu analizy i ryzyka zmian, nie o ocene waznosci funkcji w grze.

## Zasada migracji

Dla kazdego odzyskanego modulu:

1. ustalic dokladny source odpowiadajacy aktywnemu DLL,
2. zapisac go jako normalny plik pod `src/<Module>/`,
3. zapisac source SHA256 w `runtime/current.json`,
4. zachowac stary runtime artifact jako rollback/recovery,
5. jezeli mozliwe, zapisac toolchain/build command i porownac wynikowy DLL z referencyjnym hashem,
6. dopiero potem wykonywac funkcjonalne refaktory.

Nie rekonstruujemy source przez dekompilacje, jesli istnieje oryginalny source w starszych paczkach projektu — najpierw przeszukujemy paczki, archiwa i historie projektu.
