# wow112

Prywatne repozytorium projektu **World of Warcraft 1.12.1 build 5875, Windows x86** zoptymalizowane pod wielokrotne iteracje AI-assisted development.

## AI / szybki start

**Zawsze zaczynaj od `AI_START_HERE.md`.**

Minimalny zestaw do odczytu na początku zadania:

1. `AI_INDEX.json`
2. `CURRENT.json`
3. `runtime/current.json`
4. tylko kod modułu potrzebnego do danej zmiany

Nie trzeba przeszukiwać całego repo przy każdej rozmowie. `archives/`, historyczne baseline i recovery chunks są materiałem on-demand.

## Aktualny stabilny baseline

**V68 — AutoPP rear-only HARDLOS3D + V67 feature stack**

- `main` — ostatni zaakceptowany stabilny stan.
- `work` — bieżący kandydat rozwojowy; musi być zsynchronizowany z aktualnym `main` przed rozpoczęciem nowej iteracji.
- poprzednie stabilne baseline pozostają dostępne jako rollback.

Canonical state:

- `CURRENT.json` — główny wskaźnik stanu,
- `runtime/current.json` — dokładny aktywny EXE/DLL stack + SHA256 + source provenance,
- `baseline/V68/dlls.txt` — kolejność aktywnych DLL,
- `manifests/SHA256SUMS_V68.txt` — referencyjne hashe,
- `CURRENT_VERSION.md` — opis bieżącej stabilnej wersji.

## Source layout

`src/` jest jedynym normalnym **canonical editable source root**.

Aktywny plik dla konkretnego DLL wybiera pole `source_path` w `runtime/current.json`. Jeżeli moduł ma tylko lossless recovery archive, runtime metadata wskazuje restore doc/tool/artifact.

`source/` jest katalogiem legacy/history. Nie należy dodawać tam nowych aktywnych źródeł ani wskazywać go jako canonical `source_path`.

## Szybka weryfikacja

Dla codziennych iteracji:

```text
python tools/verify_current.py
```

Kompaktowy stan repo:

```text
python tools/ai_status.py
python tools/ai_status.py --json
```

Głęboki audit obecnego baseline/recovery:

```text
python tools/verify_repo.py
```

GitHub Actions wykonuje szybki gate na `work` i `main`; dodatkowe głębokie kontrole są przeznaczone dla stabilnej promocji/audytu.

## Iteracje i wersjonowanie

Nie tworzymy nowego baseline dla każdej eksperymentalnej poprawki. Kilka lub kilkadziesiąt prób może żyć na `work`. Gdy użytkownik zaakceptuje działający stan, dopiero wtedy powstaje kolejny stabilny rollback point (`V69`, `V70`, ...), poprzedni baseline zostaje zachowany, a `work` jest synchronizowany do nowego `main`.

Pełny workflow: `docs/AI_ITERATION_WORKFLOW.md`.

## Najważniejsze dokumenty

- `AI_START_HERE.md` — najszybszy punkt wejścia dla AI,
- `AI_INDEX.json` — machine-readable routing index,
- `PROJECT_INSTRUCTIONS.md` — twarde zasady projektu,
- `docs/AI_ITERATION_WORKFLOW.md` — workflow setek kolejnych iteracji,
- `docs/SOURCE_INVENTORY.md` — provenance aktywnych źródeł,
- `docs/VERSION_RETENTION.md` — polityka rollbacków,
- `CURRENT_VERSION.md` — bieżąca stabilna wersja.

Projekt nie zakłada zgodności z TBC/Wrath/Retail.
