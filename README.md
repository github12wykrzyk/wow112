# wow112

Prywatne repozytorium robocze projektu **World of Warcraft 1.12.1 (build 5875, x86)**.

## Aktualny baseline

**V67 — EXE STEALTH5 HARD + AutoPP blacklist/HARDLOS3D + ESP**

Oryginalna paczka V67 jest zachowana bez zmian w:

`baseline/V67/`

Nie modyfikujemy plikow baseline w miejscu bez wyraznej potrzeby. Kolejne zmiany powinny byc widoczne w historii Git, z opisem celu i rollbacku.

## Najwazniejsze pliki

- `CURRENT_VERSION.md` — aktualny stan i lista aktywnych komponentow.
- `PROJECT_INSTRUCTIONS.md` — zasady pracy nad projektem.
- `docs/BASELINE_AUDIT_V67.md` — audyt V67 i roznice wzgledem starszej bazy.
- `manifests/SHA256_ALL_V67.txt` — SHA256 wszystkich plikow oryginalnej paczki V67.
- `baseline/V67/dlls.txt` — aktywna lista DLL V67.
- `baseline/V67/source/` — dostepne zrodla.
- `baseline/V67/rollback_*` — rollbacki zachowane z paczki.
- `tools/CLEAN_OLD_STACK_V67_REPO.bat` — rozszerzona wersja cleanupu, bez zmiany oryginalnego skryptu V67.

## Zasada wersjonowania

Kazda funkcjonalna zmiana powinna miec osobny commit. Przy zmianach ryzykownych zachowujemy poprzedni dzialajacy stan przez historie Git i/lub jawny rollback w repo.

Nie zakladamy zgodnosci z TBC/Wrath/Retail. Projekt dotyczy tylko WoW 1.12.1 build 5875.
