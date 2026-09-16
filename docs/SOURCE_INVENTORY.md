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
| `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V39 juz uzywa wariantu `WotFRetry5` jako aktywnego binarium bez odpowiadajacego source C; V43 wprost stwierdza, ze PositionalSpoof nie byl scalany z MovementCore, bo brakowalo pelnego source C. V67 audit klasyfikuje pozniejszy StealthCDSafe/NoFailHook jako source-incomplete. |
| `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v2. V39/V43 sa chronologicznie starsze i nie zawieraja tego modulu. Dokladny runtime log v2 istnieje w Project Library, a patch V58 jest zachowany w Library. |
| `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v0.4. V39/V43 maja tylko `WoWNonPvPSpeedFloor_v0_1`; v0.4 powstal pozniej. Dokladny runtime log v0.4 oraz patch V57 sa zachowane w Project Library. |
| `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll` | SOURCE CONFIRMED, NOT INDEXED | V67 audit potwierdza kompletne source v10. V39/V43 zawieraja pelny source przodka v8 10YD, zachowany juz w `src/history/`; v10 nie wystepuje w tych starszych paczkach. |
| `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V39 ma aktywne v0.10 jako binarium + patch notes. V43 przechodzi do v0.11 przez udokumentowany binary patch selektora level gate, bez pelnego aktualnego source. V67 audit klasyfikuje v0.13 jako binary-patched/source-incomplete. |
| `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | V39/V43 maja aktywne v0.8 jako binarium bez pelnego odpowiadajacego source C. V43 wprost zaznacza, ze LongPickPocket nie byl scalany z MovementCore z powodu braku pelnego source C. V67 audit klasyfikuje v0.9 jako source-incomplete. |
| `WoWPlayerESP_v1_2_range_sweep.dll` | SOURCE CONFIRMED, AVAILABLE IN PROJECT LIBRARY, NOT YET PROMOTED | Pelny standalone `WoWPlayerESP_v1_2_range_sweep.c` zostal odnaleziony w Project Library: 81312 B. Jego tresc identyfikuje target WoW 1.12.1 build 5875 x86 oraz modul v1.2. Nie zostal jeszcze oznaczony jako canonical w Git, poniewaz obecny dostep do Library daje tekst/index, ale nie autoryzowana sciezke raw-byte do zachowania byte-exact SHA. |

`NOT INDEXED` nie oznacza, ze source nie istnieje. Oznacza, ze nie ma go obecnie jako normalnego pliku w drzewie Git.

## Direct inspection of uploaded V39 and V43 packages

Bezposrednio sprawdzone paczki:

- `WoW112_PP_HANDOFF_V39_AUTOWOTF_RETRYFIX(4).zip`
- `WoW112_PP_V43_FULL_MOVEMENTCORE_BGSAFE_AUTOKICK_DISABLED(3).zip`

Wspolne pliki source nie zostaly miedzy V39 i V43 po cichu podmienione. V43 dodaje nowe linie rozwojowe, a nie zmienia zawartosci wspolnych source pod ta sama sciezka.

Najwazniejsze zweryfikowane pliki z V43:

| File in V43 | Size | SHA256 | Meaning |
| --- | ---: | --- | --- |
| `source_active/WoWMovementCore_5875_v1_NOFALL_SAFEBREAK.c` | 17733 B | `0393a3182e8375cc7021c3dce8f229e37535f76fba8b1162efb8ff31a91a12c9` | Pierwszy source-level merge NoFall + ManualSafeBreak; przodek obecnego MovementCore. |
| `source_active/BUILD_NOTES_WoWMovementCore_5875_v1.txt` | 836 B | `f770a53658dd43a915000b91ef3e9e6674df16bcd2851cf09b1ca598e62230a9` | Toolchain clang 17 i lld-link, x86/no-CRT. |
| `archive_previous/movement_v42_individual_DO_NOT_LOAD/WoWNoFall_5875_v1.c` | 9236 B | `097f69b5a4d9e74c22a8f530cdf9b67e2fbbdc6c2cdbb24b31739e44111811a1` | Jedno z dwoch zrodel wejsciowych do MovementCore v1. |
| `source_active/WoWAutoStealth_5875_v5_CHANNEL_KILLGRACE.c` | 12337 B | `c9627a9c44924e7174420290cab6bd709c4bbc2bc6506d930b6d447429f79e49` | Pelny historyczny source AutoStealth v5. |
| `source_active/AutoPP_v0_11_LEVELGATE4_BINARY_PATCH_NOTES.txt` | 1328 B | `faea6b75083f734b76c1bd7da9a1ba5fcdaf3d4a95802ec4a4fa92d41d19735c` | Dokladny opis binary patch v0.10 -> v0.11 w selectorze AutoPP. |
| `README_V43_MOVEMENTCORE_BG_SAFETY_PL.txt` | 2825 B | `a1d5846dbef97d4dd084e4b53d184f53b2f389a13a10583d5419239a8dabe649` | Opis chainu movement hookow i powodow niescalania LongPickPocket/PositionalSpoof. |

Te pliki sa historycznym materialem referencyjnym. Nie zastępuja canonicalnego V68 source ani obecnych aktywnych DLL.

## Confirmed historical source lead: PickPocketSelectiveRange

Zweryfikowany source przodka v8 z paczek V39/V43 zostal zachowany w repo jako material historyczny:

`src/history/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v8_10YD.c`

Parametry oryginalnego pliku i pliku w Git sa identyczne:

- size: `8658` B,
- SHA256: `2d9e182f1a203f9a8b6247684edbe074f35dedf61f9795db40cfbbf1a50df0f4`.

Towarzyszace patch notes sa w:

`src/history/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v8_10YD_BINARY_PATCH_NOTES.txt`

- size: `439` B,
- SHA256: `7052f73f423271ce6d5c55c33d09f0558a7b469ee695b2fafe0aeecae7e54c18`.

V8 nie jest canonicalnym source obecnego v10. Jest tylko zweryfikowanym przodkiem i materialem porownawczym. Obecne v10 ma dodatkowe zmiany opisane nazwa `PP300_PICKLOCK300_9YD`, dlatego nie wolno podstawic v8 pod v10 bez pelnego chainu zmian.

## What V39/V43 rule out

Nie nalezy ponownie przeszukiwac V39/V43 w poszukiwaniu finalnych source:

- `PickPocketSelectiveRange v10`,
- `WoWNonPvPSpeedFloor v0.4`,
- `WoWStealthCDGuardian v2`,
- `WoWPlayerESP v1.2`.

Te wersje sa pozniejsze. Dla pierwszych trzech priorytetem sa paczki V57/V58/V67 i inne pliki Project Library. PlayerESP v1.2 zostal juz znaleziony jako osobny source w Project Library.

## Recovery priority

Najwiekszy zysk przy najmniejszym ryzyku daje teraz:

1. **Promowac byte-exact `WoWPlayerESP v1.2`**, gdy dostepna bedzie raw-byte kopia jego standalone `.c` lub ZIP z tym source.
2. **Odzyskac source potwierdzone jako istniejace:** `PickPocketSelectiveRange v10`, `WoWNonPvPSpeedFloor v0.4`, `WoWStealthCDGuardian v2` z pozniejszych paczek (V57/V58/V67), nie z V39/V43.
3. **Dla lineage binary-patched/source-incomplete** (`WoWAutoLootPP v0.13`, `WoWLongPickPocket v0.9`, `WoWPositionalSpoof` StealthCDSafe/NoFailHook) korzystac z najblizszych pelnych przodkow + patch notes zamiast szukac nieistniejacego finalnego source w starych paczkach.

W ramach funkcji Pick Pocket pierwszym celem nadal powinien byc `PickPocketSelectiveRange v10`, bo jego pelne source jest potwierdzone i mamy source przodka v8 do kontroli historii.

## Zasada migracji

Dla kazdego odzyskanego modulu:

1. ustalic dokladny source odpowiadajacy aktywnemu DLL,
2. zapisac go jako normalny plik pod `src/<Module>/`,
3. zapisac source SHA256 w `runtime/current.json`,
4. zachowac stary runtime artifact jako rollback/recovery,
5. jezeli mozliwe, zapisac toolchain/build command i porownac wynikowy DLL z referencyjnym hashem,
6. dopiero potem wykonywac funkcjonalne refaktory.

Nie rekonstruujemy source przez dekompilacje, jesli istnieje oryginalny source w starszych paczkach projektu — najpierw przeszukujemy paczki, archiwa i historie projektu.
