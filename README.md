# wow112

Prywatne repozytorium robocze projektu **World of Warcraft 1.12.1 (build 5875, x86)**.

## Aktualny baseline

**V68 — AutoPP rear-only HARDLOS3D + V67 feature stack**

Stabilny stan pozostaje na `main`. Biezaca praca rozwojowa odbywa sie na branchu `work` i dopiero po weryfikacji trafia do `main`.

Aktualna dokumentacja baseline znajduje sie w `baseline/V68/`. V67 pozostaje bezposrednim rollbackiem w `baseline/V67/`.

Nie modyfikujemy plikow baseline w miejscu bez wyraznej potrzeby. Kolejne zmiany powinny byc widoczne w historii Git, z opisem celu i rollbacku.

## Jednoznaczny stan projektu

- `CURRENT.json` — maszynowy wskaznik aktualnego baseline, runtime i manifestow.
- `runtime/current.json` — dokladny aktywny EXE/DLL stack wraz z SHA256.
- `CURRENT_VERSION.md` — opis aktualnej wersji dla czlowieka.
- `baseline/V68/dlls.txt` — aktywna lista DLL V68; jej kolejnosc musi zgadzac sie z `runtime/current.json`.
- `manifests/SHA256SUMS_V68.txt` — referencyjne SHA256 V68.

## Automatyczna weryfikacja

`tools/verify_repo.py` sprawdza spojnosc baseline, listy aktywnych DLL, manifestow SHA256, EXE oraz reprezentacji source MovementCore.

GitHub Actions uruchamia `.github/workflows/verify.yml` przy pushu na `work`/`main` oraz przy pull requescie do `main`.

Pelne zweryfikowane zrodlo MovementCore V68 nadal jest przechowywane jako skompresowane czesci w `artifacts/V68/source/`. `tools/restore_movementcore_source.py` odtwarza je deterministycznie, sprawdzajac rozmiar i SHA256 przed zapisaniem `.c`.

**UWAGA:** `source/V20_SOURCE_PARTS/` jest stara, niepelna reprezentacja pomocnicza i nie moze byc traktowana jako canonical source.

## Najwazniejsze pliki

- `PROJECT_INSTRUCTIONS.md` — zasady pracy nad projektem.
- `docs/VERSION_RETENTION.md` — zasada zachowywania pelnej historii wersji bez sztywnego limitu.
- `docs/DEVELOPMENT_WORKFLOW.md` — workflow `work -> verify -> main`.
- `baseline/V68/README_V68_PL.txt` — opis zmian V68.
- `artifacts/V68/runtime/` — zweryfikowana delta runtime V68.
- `artifacts/V68/source/` — zweryfikowane source V68.
- `tools/VERIFY_V68.bat` — starsza lokalna weryfikacja V68.
- `tools/CLEAN_OLD_STACK_V68.bat` — cleanup starego stacku przed uruchomieniem V68.

## Zasada wersjonowania i historii

Kazda funkcjonalna zmiana powinna miec osobny commit. Przy zmianach ryzykownych zachowujemy poprzedni dzialajacy stan przez historie Git i/lub jawny rollback w repo.

Repo zachowuje wszystkie kolejne stabilne baseline'y bez automatycznego kasowania starszych wersji. V69, V70 itd. maja pozostawac obok poprzednich wersji jako rollback i material porownawczy.

Nie zakladamy zgodnosci z TBC/Wrath/Retail. Projekt dotyczy tylko WoW 1.12.1 build 5875.
