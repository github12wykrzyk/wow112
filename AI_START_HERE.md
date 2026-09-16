# AI START HERE

This repository is optimized for repeated AI-assisted development of **World of Warcraft 1.12.1 build 5875, Windows x86**.

`AGENTS.md` is the repository-wide operating contract for AI agents. This file is the fast routing entrypoint. The goal is to minimize context cost and avoid rediscovering the repository on every task.

Never infer the active stack from filenames, old ZIPs, chat history or archive folders when current repository metadata is available.

## Read order for every new task

1. `AGENTS.md` — operating contract: how the AI must work, use GitHub, verify, package and communicate.
2. `AI_INDEX.json` — machine-readable map of the repository.
3. `CURRENT.json` — current baseline, branches and canonical pointers.
4. `runtime/current.json` — exact active EXE/DLL stack, hashes and source provenance.
5. Read only the source/module files relevant to the requested change.
6. Read `docs/SOURCE_INVENTORY.md` only when source provenance/recovery matters.

Do **not** scan `archives/`, old baseline artifacts, `src/history/` or recovery chunks unless the task explicitly requires history, rollback or reconstruction.

## Hard invariants

- Target only WoW `1.12.1`, build `5875`, `x86`.
- `main` is the last accepted stable state.
- `work` is the only normal development branch.
- `work` must start from current `main`; do not develop on a stale/diverged `work`.
- `runtime/current.json` is authoritative for the active runtime and each module's source provenance.
- `src/` is the canonical editable source root.
- `source/` is legacy/historical material only and must not contain an active canonical `source_path`.
- Never treat a DLL filename as proof of behavior; verify source, binary audit, reproducer or test evidence.
- Never silently replace an original source with a reconstruction.
- Routine GitHub housekeeping belongs to the AI. The user should mainly describe desired behavior and perform in-game tests.

## Fast iteration protocol

For normal development:

1. Start from current `main`, with `work` synchronized to it.
2. Locate the module through `runtime/current.json` instead of global repository search.
3. Change the smallest possible canonical source/runtime surface.
4. Keep source provenance explicit (`original_source`, reconstruction, binary-patch lineage, etc.).
5. Do not manually recalculate `source_sha256` / `source_size` after every source-only experiment. On `work` these are promotion fingerprints: `verify_current.py` warns if they lag, while candidate build metadata records the exact source hash actually compiled.
6. Run `python tools/verify_current.py`.
7. Commit one logical iteration to `work`. When GitHub git-data tools are available, group multi-file edits into one tree/commit instead of creating one commit per file.
8. `.github/workflows/build_work_candidate.yml` automatically detects which active `source_path` files changed, builds only those DLLs, and packages one complete candidate ZIP. Changes to the builder/runtime routing itself trigger a full active-stack build audit.
9. User tests the candidate in game and reports the result.
10. Before stable promotion run `python tools/sync_source_metadata.py`, then the normal/deep verification gates. Only then promote to `main` and update the next stable baseline metadata when appropriate.

Do not create a new stable baseline for every experimental edit. Multiple candidate iterations may happen on `work`; stable baseline numbers are rollback points, not chat-message counters.

## Verification levels

Fast gate used during repeated iterations:

```text
python tools/verify_current.py
```

A stale `source_sha256` / `source_size` on a candidate source is a warning, not a gameplay/runtime-integrity failure. All runtime binary hashes, cache artifacts, paths, recipes and structural invariants remain strict.

Human/AI status summary:

```text
python tools/ai_status.py
python tools/ai_status.py --json
```

Promotion fingerprint synchronization:

```text
python tools/sync_source_metadata.py
python tools/sync_source_metadata.py --check
```

Deep baseline/recovery audit:

```text
python tools/verify_repo.py
```

The fast gate follows current metadata and is intended to remain cheap across V69, V70 and later. Deep recovery checks and exact source-fingerprint checks are primarily promotion/stable-release gates.

## Where to edit and build

Always follow `runtime/current.json -> active_dlls[*].source_path` when it exists. A module directory may contain reconstructed/evidence files in addition to the canonical source; `source_path` decides which file is authoritative for the current runtime lineage.

For modules whose exact source is stored with recovery evidence, follow the recorded `source_restore_doc` / archive / reproducer metadata instead of guessing.

For one active DLL with `build_recipe`, build through:

```text
python tools/build_active_module.py --name <runtime-dll-name>
```

For a normal candidate iteration, prefer the generic changed-module route:

```text
python tools/build_changed_active.py --base <previous-git-sha>
```

It resolves active sources from `runtime/current.json`, builds only affected active DLLs, passes them as candidate overrides to `tools/package_current.py`, and emits candidate/build metadata.

## Definition of done for an AI iteration

A candidate is ready for testing when:

- the requested behavior is implemented,
- unrelated modules were not modified,
- canonical source path/provenance is correct,
- `tools/verify_current.py` returns `PASS` (candidate source-fingerprint warnings are allowed after an intentional source edit),
- the changed active DLLs build as x86 through their verified recipes,
- one complete runnable ZIP is produced when needed,
- rollback remains available,
- the candidate is committed to `work`,
- the commit message states the functional change rather than only a version number.

Before stable promotion, source fingerprints must be synchronized and the deep audit must pass.
