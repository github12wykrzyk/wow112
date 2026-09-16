# Active runtime source inventory

Stan dla stabilnego baseline **V68**.

## Canonical normal source

| Runtime module | Source status | Canonical path |
| --- | --- | --- |
| `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll` | NORMAL SOURCE | `src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c` |

MovementCore source jest zweryfikowany przez rozmiar i SHA256 oraz ma niezalezny recovery archive w `artifacts/V68/source/`.

## Active modules without indexed normal source

Ponizsze DLL sa aktywne w V68 i maja zweryfikowane runtime SHA256, ale pelne normalne source `.c/.cpp` nie jest obecnie indeksowane w repo:

| Runtime module | Repository state | History / recovery evidence |
| --- | --- | --- |
| `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V67 audit klasyfikuje aktywny wariant StealthCDSafe/NoFailHook jako source-incomplete; runtime recovery exists |
| `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v2; trzeba odzyskac je z pelnej paczki V67 |
| `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v0.4; trzeba odzyskac je z pelnej paczki V67 |
| `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v10; V43 zawiera dodatkowo pelny source przodka v8 10YD |
| `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V67 audit klasyfikuje v0.13 jako binary-patched/source-incomplete; starsze V39/V43 maja binaria i patch notes |
| `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V67 audit klasyfikuje v0.9 jako binary-patched/source-incomplete; V43 zachowuje starszy v0.8 runtime |
| `WoWPlayerESP_v1_2_range_sweep.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v1.2; trzeba odzyskac je z pelnej paczki V67 |

`NOT INDEXED` nie oznacza, ze source nie istnieje. Oznacza, ze nie ma go obecnie jako normalnego pliku w drzewie Git.

## Confirmed historical source lead: PickPocketSelectiveRange

Dostepna paczka `WoW112_PP_V43_FULL_MOVEMENTCORE_BGSAFE_AUTOKICK_DISABLED` zawiera:

`source_active/PickPocketSelectiveRange_5875_v8_10YD.c`

Parametry tego pliku:

- size: `8658` B,
- SHA256: `2d9e182f1a203f9a8b6247684edbe074f35dedf61f9795db40cfbbf1a50df0f4`.

Towarzyszace patch notes:

- `source_active/PickPocketSelectiveRange_5875_v8_10YD_BINARY_PATCH_NOTES.txt`,
- size: `439` B,
- SHA256: `7052f73f423271ce6d5c55c33d09f0558a7b469ee695b2fafe0aeecae7e54c18`.

V8 nie jest canonicalnym source obecnego v10. Jest tylko zweryfikowanym przodkiem i materialem porownawczym. Obecne v10 ma dodatkowe zmiany opisane nazwa `PP300_PICKLOCK300_9YD`, dlatego nie wolno podstawic v8 pod v10 bez pelnego chainu zmian.

## Recovery priority

Najwiekszy zysk przy najmniejszym ryzyku daje odzyskiwanie w dwoch grupach:

1. **Najpierw source potwierdzone jako istniejace w V67:** `PickPocketSelectiveRange v10`, `WoWNonPvPSpeedFloor v0.4`, `WoWStealthCDGuardian v2`, `WoWPlayerESP v1.2`.
2. **Potem lineage binary-patched/source-incomplete:** `WoWAutoLootPP v0.13`, `WoWLongPickPocket v0.9`, `WoWPositionalSpoof` StealthCDSafe/NoFailHook.

W ramach funkcji Pick Pocket pierwszym celem nadal powinien byc `PickPocketSelectiveRange v10`, bo jego pelne source jest potwierdzone i mamy dodatkowo source przodka v8 do kontroli historii.

## Zasada migracji

Dla kazdego odzyskanego modulu:

1. ustalic dokladny source odpowiadajacy aktywnemu DLL,
2. zapisac go jako normalny plik pod `src/<Module>/`,
3. zapisac source SHA256 w `runtime/current.json`,
4. zachowac stary runtime artifact jako rollback/recovery,
5. jezeli mozliwe, zapisac toolchain/build command i porownac wynikowy DLL z referencyjnym hashem,
6. dopiero potem wykonywac funkcjonalne refaktory.

Nie rekonstruujemy source przez dekompilacje, jesli istnieje oryginalny source w starszych paczkach projektu — najpierw przeszukujemy paczki, archiwa i historie projektu.
