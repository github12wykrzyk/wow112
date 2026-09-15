# Baseline audit V67

Data audytu: 2026-09-15

## Status

V67 zostaje przyjeta jako pierwszy stable baseline repozytorium.

## Ciaglosc ze starszym stackiem

Porownanie wykonano z dostepnymi paczkami V39 i V43 oraz rollbackami zawartymi w V67.

Potwierdzono m.in.:

- V43 `WoW_5875_BASE_MELEE_300YD_PICKPOCKET_BYPASS.exe` odpowiada rollbackowi EXE zachowanemu w V67.
- V43 `WoWAutoLootPP_v0_11...LEVELGATE4...dll` jest zachowany w rollbacku V58.
- V43 `WoWLongPickPocket_v0_8_FacingOnly.dll` jest zachowany w rollbacku V62.
- aktualne warianty AutoLootPP i LongPickPocket sa potomkami tych samych rodzin, a nie przypadkowo przemianowanymi plikami.

## V67 — glowne elementy

### EXE Stealth 5 s

Dokumentacja V67 wskazuje twardy patch klientowego wpisu cooldownu dla Stealth rank 1-4 (spellId 1784-1787), z limitem 5000 ms.
Ze wzgledu na to, ze WoW.exe jest binarnym plikiem gry, repo przechowuje SHA256 i kompletna dokumentacje patcha, a nie sam executable.

### MovementCore

Aktualny runtime:

`MovementCore_V66_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_RETRY.dll`

Dostepny source:

`source/WoWMovementCore_5875_v19_AUTOPP_BLACKLIST_HARDLOS3D_RETRY.c`

Zakres funkcji obejmuje m.in. Mining-first, Mining HARDLOS, Mining w combat, AutoPP F11, player target guard, blacklist pustych kieszeni i HARDLOS3D retry.

### ESP

Aktywny:

`WoWPlayerESP_v1_2_range_sweep.dll`

Source jest zachowany w paczce.

## Luka funkcjonalna do pamietania

V43 miala osobny aktywny modul:

`WoWAutoStealth_5875_v5_CHANNEL_KILLGRACE.dll`

Nie wystepuje on w aktywnym `dlls.txt` V67. Obecnosc zachowan zwiazanych ze Stealth w innych DLL nie jest wystarczajacym dowodem, ze ogolny AutoStealth V43 nadal istnieje.

## Source completeness

Aktualne source jest dostepne dla:

- MovementCore v19,
- PickPocketSelectiveRange v10,
- WoWNonPvPSpeedFloor v0.4,
- WoWPlayerESP v1.2,
- WoWStealthCDGuardian v2.

Aktywne komponenty bez kompletnego aktualnego source w V67 nalezy traktowac jako `binary-patched / source-incomplete`, w szczegolnosci:

- WoWAutoLootPP v0.13,
- WoWLongPickPocket v0.9,
- WoWPositionalSpoof wariant StealthCDSafe/NoFailHook.

## Cleanup

Oryginalny `CLEAN_OLD_STACK_V67.bat` pozostaje referencja baseline.
Repo dodaje `tools/CLEAN_OLD_STACK_V67_REPO.bat`, ktory rozszerza liste znanych rodzin, ale nadal nie rusza obcych/niezwiazanych DLL.
