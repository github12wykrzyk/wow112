# AI iteration workflow

## Objective

Minimize wall-clock time from a user request to a verified runnable artifact while preserving an unambiguous stable rollback state.

`AGENTS.md` is authoritative. This document describes the lifecycle without duplicating low-level rules.

## 1. Route, do not rediscover

Read `AGENTS.md -> AI_START_HERE.md -> AI_INDEX.json -> CURRENT.json -> runtime/current.json`, then only the relevant source.

`main` must be an ancestor of `work` before work-branch edits; retain existing parallel divergence without forced integration. Route independent work as described in `docs/AI_EXPERIMENTS.md`.

## 2. TEST lifecycle on selected development branch

1. Make one small functional change.
2. Run `python tools/verify_current.py`.
3. Commit the complete logical change atomically to the explicitly selected or safely routed branch.
4. Use the configured candidate builder for that branch. `Build work candidate` handles work and only any additional branches explicitly declared in its actual triggers.
5. Candidate companion modules are appended when their source exists.
6. `tools/verify_candidate_package.py` performs the final package gate.
7. Only a package with `FINAL_PACKAGE: PASS` is handed to the user.
8. The user tests in game.

Multiple failed/experimental commits may remain on their respective development branches; they do not consume stable version numbers.

## 3. Why stable promotion is curated

`work` can contain several unrelated experiments. Accepting one feature does not mean every work commit is accepted.

For a stable release, start from current `main` and curate only accepted state into a promotion tree.

## 4. Pre-promotion gate

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

## 5. Exact-byte stable packaging

TEST can be rebuilt.

STABLE must use exact accepted DLL bytes referenced by runtime metadata or stored as:

`artifacts/runtime_cache/<sha256>.dll.xz`

`tools/package_exact_current.py` verifies every decompressed DLL against runtime SHA256 and size. `tools/verify_candidate_package.py --finalize` then creates/verifies `dlls.txt`, root layout, PE32 x86 and final package metadata.

This prevents a source/toolchain rebuild from silently changing a stable runtime.

## 6. Promotion completion

After `Pre-promote stable` passes:

1. move `main` to the same verified SHA,
2. require `Build stable candidate` to pass,
3. preserve the previous stable baseline,
4. integrate new main into `work` without destroying unrelated work-only experiments.

## 7. Repository hygiene

Do not commit generated `build/`, `dist/`, `.wow112_debug/`, local updater state, logs or dumps.

Prefer one logical multi-file Git tree commit instead of serial file commits.

Do not duplicate current baseline numbers in general workflow prose; read them from `CURRENT.json`.
