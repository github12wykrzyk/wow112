# Project instructions — WoW 1.12

Projekt dotyczy wylacznie **World of Warcraft 1.12.1 build 5875 x86**.

## Zasady

- Nie mieszac API, struktur ani zalozen z TBC/Wrath/Retail.
- Zachowywac kompatybilnosc z buildem 5875.
- Preferowac male, punktowe zmiany zamiast przepisywania stabilnych modulow.
- Przed modyfikacja binarna zapisywac offset, oryginalne bajty, nowe bajty i sposob rollbacku.
- Przy zmianie DLL/EXE aktualizowac manifest SHA256, `runtime/current.json`, `CURRENT.json` i `CURRENT_VERSION.md`.
- Nie usuwac dzialajacego rollbacku bez potrzeby.
- Nie zakladac, ze funkcja opisana w nazwie DLL faktycznie dziala — weryfikowac source, diff lub test.
- Aktywna lista runtime jest okreslona przez `baseline/<wersja>/dlls.txt` i musi byc zgodna z `runtime/current.json`.
- Canonicalny aktualny source ma byc normalnym plikiem w `src/`; skompresowane artefakty sluza jako recovery/rollback, nie jako podstawowy plik do edycji.
- Nie budowac MovementCore z `source/V20_SOURCE_PARTS/` — ta reprezentacja jest niepelna.

## Workflow Git

- `main` = ostatni sprawdzony stabilny stan.
- `work` = biezace zmiany rozwojowe.
- Zmiany najpierw trafiaja na `work`.
- Przed scaleniem do `main` GitHub Actions / `tools/verify_repo.py` musi zakonczyc sie `PASS`.
- Kolejny stabilny stan otrzymuje nowy baseline (`V69`, `V70`, ...); poprzednich baseline nie nadpisujemy.

## Canonical MovementCore V68

Source:

`src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c`

SHA256:

`764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`

Recovery archive pozostaje w `artifacts/V68/source/` i jest niezaleznie weryfikowany przez `tools/restore_movementcore_source.py`.

## Baseline

Pierwszym baseline repo jest V67 z katalogu `baseline/V67/`. Aktualny stabilny baseline opisuje `CURRENT.json`.
