# AI START HERE

This repository is optimized for repeated AI-assisted development of **World of Warcraft 1.12.1 build 5875, Windows x86**.

`AGENTS.md` is the operating contract. This file is the fast routing entrypoint after that contract has been read.

## Read order for every task

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`
6. only files for the affected module.

Do not scan `archives/`, old baselines, `src/history/`, legacy `source/`, or recovery chunks unless the task actually needs rollback/reconstruction.

## Hard invariants

- `main` = last accepted stable state.
- `work` = normal development branch.
- `promote/**` = curated stable-candidate gate branches.
- `work` must contain current `main`.
- `runtime/current.json` decides active runtime/source lineage.
- `src/` is canonical editable source root.
- Stable runtime packages use exact accepted bytes, never an unverified rebuild.
- No direct promotion to `main` before the exact `promote/**` SHA passes `Pre-promote stable`.

## Lightweight AI session

For a user-selected branch (including `parallel`), use that exact branch even if generic metadata names `work` as the default. Finish the smallest independent GitHub change first, confirm its commit SHA, and provide a short factual checkpoint. Do not perform unrelated edits or repeatedly query all Actions runs in one response. After interrupted streaming, recheck HEAD and workflow for the intended SHA before doing any write. See `AGENTS.md` section 14.

## Fast TEST path

```text
read routing -> edit canonical source -> verify_current ->
one logical commit on work -> Build work candidate ->
verify_candidate_package -> artifact -> user test
```

Useful commands:

```text
python tools/ai_status.py
python tools/verify_current.py
python tools/verify_runtime_artifacts.py
python tools/verify_verified_symbols.py
```

The work workflow builds changed active modules, packages the complete stack, appends enabled candidate companion modules, then runs one final fail-closed ZIP verifier.

## Stable promotion path

Never promote the entire accumulated `work` branch just because one feature was accepted.

Curate accepted changes onto current `main`, create a `promote/<purpose>` branch, and require `Pre-promote stable` PASS on that exact SHA. Stable packaging must come from exact accepted runtime bytes:

```text
python tools/sync_source_metadata.py --check
python tools/verify_current.py
python tools/verify_runtime_artifacts.py
python tools/verify_repo.py
python tools/package_exact_current.py
python tools/verify_candidate_package.py --finalize ...
```

Only then may AI move `main`. Afterward, integrate the new main into work without deleting unrelated work experiments.

## Exact-byte runtime cache

An active stable DLL must be recoverable by exact SHA from either its `binary_artifact` metadata or:

`artifacts/runtime_cache/<sha256>.dll.xz`

Missing or mismatching exact bytes are a hard promotion failure.

## Current state

Do not copy the baseline number from this prose. Read `CURRENT.json`; it is the source of truth. `CURRENT_VERSION.md` is descriptive only.

## Definition of ready-to-test

A TEST artifact is ready only when:
- fast repository gates pass,
- changed x86 modules build,
- final ZIP contains one root EXE + all root DLLs + exact `dlls.txt`,
- all binary entries are PE32 x86,
- metadata SHA matches the final ZIP,
- `FINAL_PACKAGE: PASS`.

See `AGENTS.md` for the full operating contract.
