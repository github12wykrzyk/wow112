# AI START HERE

This repository is optimized for repeated AI-assisted development of **World of Warcraft 1.12.1 build 5875, Windows x86**.

`AGENTS.md` is the operating contract. This file is the fast routing entrypoint after that contract has been read.

## Startup read path

For ordinary non-promotion work, first read `runtime/ai_startup_snapshot.json` and verify its five `git_blob_sha1` identities against Git tree metadata from the live selected-branch HEAD. If all match, continue with `runtime/ai_experiment_index.json` and only the affected module.

Fail closed to the full canonical order when the snapshot is missing/stale/unverifiable, when editing startup-contract files, during stable promotion, recovery after unknown state, or when authority is ambiguous:

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`
6. only files for the affected module.

Do not scan `archives/`, old baselines, `src/history/`, legacy `source/`, or recovery chunks unless the task actually needs rollback/reconstruction.

## Hard invariants

- `main` = last accepted stable state.
- `work` = existing development branch; `parallel` = independent alternative branch.
- `feature/**` = short-lived branch for independent experiments.
- `promote/**` = curated stable-candidate gate branches.
- `work` must contain current `main`; preserve the independent `parallel` branch and its existing experiments.
- `runtime/current.json` decides active runtime/source lineage.
- `src/` is canonical editable source root.
- Stable runtime packages use exact accepted bytes, never an unverified rebuild.
- No direct promotion to `main` before the exact `promote/**` SHA passes `Pre-promote stable`.

## Lightweight AI session

For a user-selected branch (including `parallel`), use that exact branch even if generic metadata names `work` as the default. Finish the smallest independent GitHub change first, confirm its commit SHA, and provide a short factual checkpoint. Do not perform unrelated edits or repeatedly query all Actions runs in one response. After interrupted streaming, recheck HEAD and workflow for the intended SHA before doing any write. See `AGENTS.md` section 14.

Default latency path: batch the mandatory startup reads, make one focused atomic commit, check required feature workflows together at run level, integrate after PASS, then observe required `parallel` workflows together. **Do not inspect successful job/step progress or fetch logs on the success path.** Deep CI inspection is failure-driven. For a small already-understood one-module fix, aim for roughly 4–6 minutes end-to-end when runner capacity permits, without weakening any verification or package gate.

## Experiment routing

After verified startup context inspect the compact `runtime/ai_experiment_index.json` first, then relevant live branch heads and module/dependency ownership. It is generated from `runtime/ai_experiments.json` and intentionally omits heavy notes/test evidence; read the full ledger only when compact routing is insufficient or evidence must be updated. `python tools/ai_experiments.py route --module MODULE [--branch parallel]` provides advisory routing and `python tools/ai_experiments.py index --check` verifies the fast index. Explicitly selected `parallel` remains parallel; independent changes use a temporary `feature/<purpose>` from the appropriate verified base. See `docs/AI_EXPERIMENTS.md`.

For ordinary module work, prefer one compact task-context read before opening source files:

```text
python tools/ai_task_context.py --branch parallel --module MODULE
```

The helper is read-only. It resolves the selected checkout/ref when available, shows the latest active experiments for that module in ledger order, canonical source hints, STANDARD/ECONOMY delivery eligibility, and the complete `feature preflight -> integrate -> exact parallel build -> profile build -> TEST READY` lifecycle. It exists specifically to prevent a successful feature preflight from being mistaken for delivered code. Live GitHub HEAD and the canonical manifests remain authoritative before every write.

## Fast TEST path

```text
read routing -> edit canonical source -> verify_current ->
one logical commit on selected branch -> branch-specific candidate workflow ->
verify_candidate_package -> artifact -> user test
```

Useful commands:

```text
python tools/ai_task_context.py --branch parallel --module MODULE
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
