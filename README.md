# wow112

Prywatne repozytorium robocze projektu **World of Warcraft 1.12.1 (build 5875, x86)**.

## Aktualny baseline

**V68 — AutoPP rear-only HARDLOS3D + V67 feature stack**

Aktualna dokumentacja znajduje sie w:

`baseline/V68/`

V67 pozostaje bezposrednim rollbackiem w `baseline/V67/`.

Nie modyfikujemy plikow baseline w miejscu bez wyraznej potrzeby. Kolejne zmiany powinny byc widoczne w historii Git, z opisem celu i rollbacku.

## Najwazniejsze pliki

- `CURRENT_VERSION.md` — aktualny stan i lista aktywnych komponentow.
- `PROJECT_INSTRUCTIONS.md` — zasady pracy nad projektem.
- `docs/VERSION_RETENTION.md` — zasada zachowywania pelnej historii wersji bez sztywnego limitu.
- `baseline/V68/README_V68_PL.txt` — opis zmian V68.
- `baseline/V68/dlls.txt` — aktywna lista DLL V68.
- `artifacts/V68/runtime/` — zweryfikowana delta runtime V68.
- `artifacts/V68/source/` — zweryfikowane source V68.
- `tools/VERIFY_V68.bat` — weryfikacja V68.
- `tools/CLEAN_OLD_STACK_V68.bat` — cleanup starego stacku przed uruchomieniem V68.

## Zasada wersjonowania i historii

Kazda funkcjonalna zmiana powinna miec osobny commit. Przy zmianach ryzykownych zachowujemy poprzedni dzialajacy stan przez historie Git i/lub jawny rollback w repo.

Repo zachowuje wszystkie kolejne stabilne baseline'y bez automatycznego kasowania starszych wersji. V69, V70 itd. maja pozostawac obok poprzednich wersji jako rollback i material porownawczy.

Nie zakladamy zgodnosci z TBC/Wrath/Retail. Projekt dotyczy tylko WoW 1.12.1 build 5875.
