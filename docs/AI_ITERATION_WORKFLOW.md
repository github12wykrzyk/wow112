# AI iteration workflow

## Objective

Minimize wall-clock time from a user request to a verified runnable artifact while preserving an unambiguous stable rollback state.

`AGENTS.md` is authoritative. This document describes the lifecycle without duplicating low-level rules.

## 1. Route, do not rediscover

For ordinary work use the verified startup snapshot path from `AGENTS.md`. After it is validated, start module work with:

`python tools/ai_task_context.py --branch <selected-branch> --module <Module>`

The task context is deliberately small: selected ref/HEAD when locally resolvable, recent active experiments in ledger order, source hints, applicable delivery profiles and the exact delivery lifecycle. It is advisory and read-only; live GitHub refs and canonical manifests remain authoritative before a write. Fall back to the full canonical startup sequence when required by `AGENTS.md`.

Do not read the full `runtime/ai_experiments.json` merely to discover a branch. Use task context / compact indexes first and load full ledger evidence only when it must actually be inspected or updated.

`main` must be an ancestor of `work` before work-branch edits; retain existing parallel divergence without forced integration. Route independent work as described in `docs/AI_EXPERIMENTS.md`.

## 2. Parallel integration lifecycle

For non-trivial `parallel` work, branch from the current verified `parallel` HEAD into `feature/<purpose>`. Treat `parallel` as an integration/test trunk, not as the first compiler for unfinished native code.

1. Make the complete logical iteration on the feature branch.
2. Require `.github/workflows/parallel_feature_preflight.yml` to PASS on the exact feature SHA. It runs repository/parallel gates and compiles changed active and declared companion DLLs.
3. Require any path-specific feature workflow, such as updater or AutoLogin, when it is triggered.
4. Integrate the verified feature SHA into `parallel`.
5. Require the full aggregate `Build work candidate` on the resulting exact `parallel` SHA, including final package verification and attestation.
6. If the affected module belongs to a delivery fast profile such as ECONOMY, require that exact-parallel-SHA profile workflow too.
7. Hand off only the exact-SHA artifact after all required delivery workflows pass; feature `PREFLIGHT PASS` alone is never `TEST READY`.
8. Freeze an issued test SHA; unrelated work continues on another feature branch until the game result is recorded.

The expected state machine is therefore:

`EDITING -> FEATURE PREFLIGHT -> INTEGRATED -> PARALLEL BUILD -> PROFILE BUILD (if applicable) -> TEST READY`

Small documentation/metadata-only edits may remain direct, but an uncompiled native change must not advance `parallel` merely to obtain compiler feedback.

## 3. TEST lifecycle on selected development branch

1. Make one small functional change.
2. Run `python tools/verify_current.py`.
3. Commit the complete logical change atomically to the explicitly selected or safely routed branch.
4. Use the configured candidate builder for that branch. `Build work candidate` handles work and only any additional branches explicitly declared in its actual triggers.
5. Candidate companion modules are appended when their source exists.
6. `tools/verify_candidate_package.py` performs the final package gate.
7. Only a package with `FINAL_PACKAGE: PASS` is handed to the user.
8. The user tests in game.

Multiple failed/experimental commits may remain on their respective development branches; they do not consume stable version numbers.

## 4. Why stable promotion is curated

`work` can contain several unrelated experiments. Accepting one feature does not mean every work commit is accepted.

For a stable release, start from current `main` and curate only accepted state into a promotion tree.

## 5. Pre-promotion gate

Create `promote/<purpose>` at the curated stable SHA.

`.github/workflows/pre_promote_stable.yml` must pass on that exact SHA before `main` moves. The gate checks:

- current main is an ancestor of the promotion candidate,
- synchronized source promotion fingerprints,
- fast repository state,
- exact runtime artifact recoverability,
- verified build-5875 symbol registry,
- deep baseline/recovery consistency,
- exact-byte stable packaging,
- final runnable ZIP structure/hash/PE32 x86.

If any check fails, fix the promotion branch; do not move main.

## 6. Exact-byte stable packaging

TEST can be rebuilt.

STABLE must use exact accepted DLL bytes referenced by runtime metadata or stored as:

`artifacts/runtime_cache/<sha256>.dll.xz`

`tools/package_exact_current.py` verifies every decompressed DLL against runtime SHA256 and size. `tools/verify_candidate_package.py --finalize` then creates/verifies `dlls.txt`, root layout, PE32 x86 and final package metadata.

This prevents a source/toolchain rebuild from silently changing a stable runtime.

## 7. Promotion completion

After `Pre-promote stable` passes:

1. move `main` to the same verified SHA,
2. require `Build stable candidate` to pass,
3. preserve the previous stable baseline,
4. integrate new main into work without destroying unrelated work-only experiments.

## 8. Repository hygiene

Do not commit generated `build/`, `dist/`, `.wow112_debug/`, local updater state, logs or dumps.

Prefer one logical multi-file Git tree commit instead of serial file commits.

Do not duplicate current baseline numbers in general workflow prose; read them from `CURRENT.json`.
