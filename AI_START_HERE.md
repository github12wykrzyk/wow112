# AI START HERE

This repository is optimized for repeated AI-assisted development of **World of Warcraft 1.12.1 build 5875, Windows x86**.

The goal of this file is routing, not duplication. Never infer the active stack from filenames, old ZIPs or archive folders.

## Read order for every new task

1. `AI_INDEX.json` — machine-readable map of the repository.
2. `CURRENT.json` — current baseline, branches and canonical pointers.
3. `runtime/current.json` — exact active EXE/DLL stack, hashes and source provenance.
4. Read only the source/module files relevant to the requested change.
5. Read `docs/SOURCE_INVENTORY.md` only when source provenance/recovery matters.

Do **not** scan `archives/`, old baseline artifacts, `src/history/` or recovery chunks unless the task explicitly requires history, rollback or reconstruction.

## Hard invariants

- Target only WoW `1.12.1`, build `5875`, `x86`.
- `main` is the last stable state.
- `work` is the only normal development branch.
- `work` must start from current `main`; do not develop on a stale/diverged `work`.
- `runtime/current.json` is authoritative for the active runtime and each module's source provenance.
- `src/` is the canonical editable source root.
- `source/` is legacy/historical material only and must not contain an active canonical `source_path`.
- Never treat a DLL filename as proof of behavior; verify source, binary audit, reproducer or test evidence.
- Never silently replace an original source with a reconstruction.

## Fast iteration protocol

For normal development:

1. Start from current `main`, with `work` synchronized to it.
2. Locate the module through `runtime/current.json` instead of global repository search.
3. Change the smallest possible source/runtime surface.
4. Keep source provenance explicit (`original_source`, reconstruction, binary-patch lineage, etc.).
5. Update metadata/hashes that the change actually invalidates.
6. Run `python tools/verify_current.py`.
7. Commit the complete candidate to `work`.
8. User tests the candidate.
9. Only after a working state is accepted, promote it to `main` and create/update the next stable baseline metadata.

Do not create a new stable baseline for every experimental edit. Multiple candidate iterations may happen on `work`; stable baseline numbers are rollback points, not chat-message counters.

## Verification levels

Fast gate used during repeated iterations:

```text
python tools/verify_current.py
```

Human/AI status summary:

```text
python tools/ai_status.py
python tools/ai_status.py --json
```

Deep baseline/recovery audit:

```text
python tools/verify_repo.py
```

The fast gate follows current metadata and is intended to remain valid across V69, V70 and later. Deep recovery scripts may be baseline-specific and are primarily required when promoting or auditing a stable release.

## Where to edit

Always follow `runtime/current.json -> active_dlls[*].source_path` when it exists. A module directory may contain reconstructed/evidence files in addition to the canonical source; `source_path` decides which file is authoritative for the current runtime lineage.

For modules whose exact source is still stored only as a lossless recovery archive, follow the `source_restore_doc` / `source_archive` / `source_archive_prefix` metadata instead of guessing.

## Definition of done for an AI iteration

A candidate is ready for testing when:

- the requested change is implemented,
- unrelated modules were not modified,
- metadata points to the correct source/runtime lineage,
- `tools/verify_current.py` returns `PASS`,
- rollback remains available,
- the commit message states the functional change rather than only a version number.
