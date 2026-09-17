# wow112

Private AI-first repository for **World of Warcraft 1.12.1 build 5875, Windows x86**.

## Start here

For every AI task, read in this order:

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`

Do not infer the active baseline or stack from this README. `CURRENT.json` and `runtime/current.json` are canonical.

## Branches

- `main` — last accepted stable state.
- `work` — current development candidate.
- `promote/**` — temporary curated stable candidates; these must pass the pre-promotion gate before `main` moves.

Normal feature/fix work happens on `work`. Accepted changes are curated onto current `main`; the entire accumulated `work` branch is not promoted wholesale.

## Build and verification

Routine:

```text
python tools/verify_current.py
python tools/verify_runtime_artifacts.py
python tools/verify_verified_symbols.py
```

TEST artifact:
- `.github/workflows/build_work_candidate.yml`
- ends with `tools/verify_candidate_package.py`
- publishes only after final package verification.

Stable promotion:
- `.github/workflows/pre_promote_stable.yml`
- strict source/deep checks
- exact-byte packaging with `tools/package_exact_current.py`
- final ZIP verification before `main` is updated.

Stable artifact:
- `.github/workflows/build_stable_candidate.yml`
- packages exact accepted runtime bytes; it does not silently replace them with a new rebuild.

## Canonical layout

- `CURRENT.json` — current baseline/branch/tool pointers.
- `runtime/current.json` — exact active EXE/DLL stack and provenance.
- `src/` — canonical editable source root.
- `baseline/` — stable rollback metadata.
- `manifests/` — stable/reference hashes.
- `artifacts/runtime_cache/` — content-addressed exact DLL bytes.
- `artifacts/` — recovery/audit/reproducer evidence.
- `archives/`, `src/history/`, `source/` — historical material; do not scan by default.

## Human role

The human user describes desired behavior and tests ready artifacts. AI owns routine GitHub edits, branch housekeeping, verification, packaging, and promotion workflow.

Full contract: `AGENTS.md`.
