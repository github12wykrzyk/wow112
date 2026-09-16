# Active runtime source inventory

Stan dla stabilnego baseline **V68**.

## Canonical normal source

| Runtime module | Source status | Canonical path |
| --- | --- | --- |
| `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll` | NORMAL SOURCE | `src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c` |
| `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll` | RECONSTRUCTED + BINARY VERIFIED | `src/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD_RECONSTRUCTED.c` |

MovementCore source jest zweryfikowany przez rozmiar i SHA256 oraz ma niezalezny recovery archive w `artifacts/V68/source/`.

PickPocketSelectiveRange v10 zostal odtworzony z finalnej DLL i zweryfikowany przez rebuild: sekcja `.text` jest byte-identical z runtime reference (0 roznic / 1634 bajtow), a przy zgodnej nazwie i flagach PE caly 4096-bajtowy DLL rozni sie tylko 3 bajtami timestampu COFF. Szczegoly: `src/PickPocketSelectiveRange/README_RECOVERY.md`.

## Active modules without indexed normal source

Ponizsze DLL sa aktywne w V68 i maja zweryfikowane runtime SHA256, ale pelne normalne source `.c/.cpp` nie jest obecnie indeksowane w repo:

| Runtime module | Repository state | History / recovery evidence |
| --- | --- | --- |
| `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V67 audit klasyfikuje aktywny wariant StealthCDSafe/NoFailHook jako source-incomplete; runtime recovery exists |
| `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v2; runtime binary recovery jest zachowany w repo |
| `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v0.4; runtime binary recovery jest zachowany w repo |
| `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V67 audit klasyfikuje v0.13 jako binary-patched/source-incomplete; starsze V39/V43 maja binaria i patch notes |
| `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V67 audit klasyfikuje v0.9 jako binary-patched/source-incomplete; V43 zachowuje starszy v0.8 runtime |
| `WoWPlayerESP_v1_2_range_sweep.dll` | SOURCE CONFIRMED, NOT INDEXED | pelny standalone source v1.2 zostal znaleziony w Project Library; trzeba przeniesc go byte-safe do Git |

`NOT INDEXED` nie oznacza, ze source nie istnieje. Oznacza, ze nie ma go obecnie jako normalnego pliku w drzewie Git.

## Confirmed historical source lead: PickPocketSelectiveRange

Zweryfikowany source przodka v8 z paczek V39/V43 jest zachowany w repo jako material historyczny:

`src/history/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v8_10YD.c`

Parametry oryginalnego pliku i pliku w Git sa identyczne:

- size: `8658` B,
- SHA256: `2d9e182f1a203f9a8b6247684edbe074f35dedf61f9795db40cfbbf1a50df0f4`.

Towarzyszace patch notes sa w:

`src/history/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v8_10YD_BINARY_PATCH_NOTES.txt`

- size: `439` B,
- SHA256: `7052f73f423271ce6d5c55c33d09f0558a7b469ee695b2fafe0aeecae7e54c18`.

V8 nie jest canonicalnym source obecnego v10. Jest zweryfikowanym przodkiem i materialem porownawczym. Obecne v10 zostalo juz niezaleznie odtworzone z finalnej binarki i zweryfikowane przez kompilacje.

## Confirmed V39/V43 lineage findings

Bezposrednia inspekcja dostarczonych paczek V39 i V43 potwierdzila:

- wspolne runtime `WoWPositionalSpoof ... WotFRetry5`, `WoWNonPvPSpeedFloor v0.1`, `PickPocketSelectiveRange v8` i `WoWLongPickPocket v0.8` sa bit-identyczne pomiedzy V39 i V43;
- V43 dodaje pelny source `WoWMovementCore_5875_v1_NOFALL_SAFEBREAK.c`, source `WoWAutoStealth_5875_v5_CHANNEL_KILLGRACE.c`, source `WoWNoFall_5875_v1.c` oraz binary patch notes dla AutoPP v0.11;
- V43 wprost dokumentuje, ze LongPickPocket i PositionalSpoof nie byly wtedy scalane z powodu braku pelnego biezacego source C;
- V39/V43 nie zawieraja finalnych aktywnych wersji v10/v0.4/v2/v1.2/v0.13/v0.9 ani wariantow `StealthCDSafe`/`NoFailHook`.

Wniosek: V39/V43 sa cennym lineage/reference, ale nie sa zrodlem finalnych brakujacych source dla V67/V68.

## Recovery priority

Aktualny priorytet:

1. `WoWStealthCDGuardian v2` — runtime binary recovery jest w Git; dobry kandydat do rekonstrukcji z DLL.
2. `WoWNonPvPSpeedFloor v0.4` — runtime binary recovery jest w Git; dobry kandydat do rekonstrukcji z DLL.
3. `WoWPlayerESP v1.2` — pelny source juz istnieje w Project Library; trzeba tylko przeniesc go do Git.
4. `WoWAutoLootPP v0.13`, `WoWLongPickPocket v0.9`, `WoWPositionalSpoof` — rekonstrukcja z binarki wsparta starszymi source/patch notes.

## Zasada migracji

Dla kazdego odzyskanego modulu:

1. ustalic dokladny source lub zrekonstruowac go z finalnej DLL,
2. zapisac go jako normalny plik pod `src/<Module>/`,
3. zapisac source SHA256 i status w `runtime/current.json`,
4. zachowac runtime artifact jako rollback/recovery,
5. jezeli mozliwe, zbudowac DLL tym samym toolchainem i porownac wynikowy kod maszynowy z referencyjnym DLL,
6. jasno oznaczyc `RECONSTRUCTED` vs original source,
7. dopiero potem wykonywac funkcjonalne refaktory.
