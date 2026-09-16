# Project instructions — WoW 1.12 / AI-first workflow

Projekt dotyczy wyłącznie **World of Warcraft 1.12.1 build 5875, Windows x86**.

## Start każdej pracy

Najpierw przeczytaj:

1. `AI_START_HERE.md`
2. `AI_INDEX.json`
3. `CURRENT.json`
4. `runtime/current.json`

Dopiero potem otwieraj kod modułu, którego dotyczy zadanie. Nie skanuj automatycznie `archives/`, starych baseline ani całego `artifacts/`.

## Twarde zasady techniczne

- Nie mieszać API, struktur ani założeń z TBC/Wrath/Retail.
- Zachowywać kompatybilność z buildem 5875 x86.
- Preferować małe, punktowe zmiany zamiast przepisywania stabilnych modułów.
- Nie zakładać, że funkcja opisana w nazwie DLL faktycznie działa — weryfikować source, diff, audit/reproducer lub test.
- Przy modyfikacji binarnej zachować offset, oryginalne bajty, nowe bajty i sposób rollbacku.
- Nie usuwać działającego rollbacku bez technicznej potrzeby.
- Oryginalny source i source zrekonstruowany z binarki to różne klasy dowodu i muszą pozostać jawnie rozróżnione.

## Canonical state

- `CURRENT.json` — wskazuje bieżący baseline i wszystkie canonical pointers.
- `runtime/current.json` — dokładny aktywny EXE/DLL stack, SHA256 i provenance source.
- `baseline/<wersja>/dlls.txt` — lista aktywnych DLL; kolejność musi być identyczna jak w `runtime/current.json`.
- `manifests/SHA256SUMS_<wersja>.txt` — referencyjne hashe stabilnego runtime.
- `src/` — canonical editable source root.
- `source/` — legacy/history only; aktywne `source_path` nie mogą wskazywać tego katalogu.

Jeżeli `runtime/current.json` zawiera `source_path`, ten dokładny plik jest canonicalnym punktem edycji dla danego lineage. Podobna nazwa pliku nie ma pierwszeństwa przed metadanymi runtime.

## Workflow Git

- `main` = ostatni zaakceptowany stabilny stan.
- `work` = bieżący kandydat rozwojowy.
- `work` musi startować z aktualnego `main`; nie rozwijamy projektu na starym/diverged `work`.
- Eksperymentalne iteracje mogą wykonywać wiele commitów na `work` bez zużywania kolejnych numerów baseline.
- Po zaakceptowaniu działającego stanu tworzymy następny stabilny baseline (`V69`, `V70`, ...), promujemy do `main` i synchronizujemy `work` do nowego `main`.

## Verification

Szybka kontrola każdej iteracji:

```text
python tools/verify_current.py
```

Krótki status dla AI/człowieka:

```text
python tools/ai_status.py
python tools/ai_status.py --json
```

Głęboki audit baseline/recovery:

```text
python tools/verify_repo.py
```

`verify_current.py` jest wersjo-niezależny i powinien pozostać podstawowym gate dla kolejnych V69/V70/... . `verify_repo.py` może zawierać dodatkowe kontrole recovery specyficzne dla aktualnie zabezpieczonych baseline.

## Zasada aktualizacji metadanych

- Zmiana canonical source -> aktualizuj jego SHA256/size w metadanych, które na niego wskazują.
- Zmiana DLL/EXE -> aktualizuj runtime SHA256 i właściwy manifest.
- Stabilna promocja -> aktualizuj `CURRENT.json`, `runtime/current.json`, `CURRENT_VERSION.md`, baseline i manifest nowej wersji.
- Nie deklaruj byte-identical/rebuild-exact bez weryfikacji.

## MovementCore legacy warning

Nie budować MovementCore z `source/V20_SOURCE_PARTS/`. To niepełny materiał historyczny. Canonicalny plik wskazuje zawsze `CURRENT.json` / `runtime/current.json`.
