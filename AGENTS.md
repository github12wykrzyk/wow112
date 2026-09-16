# AGENTS.md — AI AUTOPILOT CONTRACT

This repository is operated primarily by AI agents. The human user should not be expected to browse, edit, organize, merge, hash, package or maintain repository files manually.

Target is permanently **World of Warcraft 1.12.1 build 5875, Windows x86** unless the user explicitly requests a comparison with another version.

## 1. Operating model

The normal interaction model is:

1. The user describes the desired behavior, bug or experiment in natural language.
2. The AI inspects the current repository state through GitHub.
3. The AI identifies the smallest relevant module and canonical source/recovery path.
4. The AI implements the change on `work`.
5. The AI updates only metadata that must be exact for the candidate; source promotion fingerprints may intentionally lag during source-only experiments.
6. The AI runs repository verification/CI.
7. The AI reports a concise test plan and, when appropriate, prepares the test artifact/package.
8. The user only performs in-game testing and reports the observed result.
9. The AI iterates until accepted.
10. Accepted stable state is synchronized, deeply verified, promoted to `main` and receives the next stable baseline when appropriate.

Do not make the user perform repository housekeeping that the AI can perform through GitHub.

## 2. Mandatory startup sequence for every task

Before editing anything:

1. Read `AI_START_HERE.md`.
2. Read `AI_INDEX.json`.
3. Read `CURRENT.json`.
4. Read `runtime/current.json`.
5. Identify the affected active module(s).
6. Read only the canonical source/evidence required for those modules.

Do not begin by scanning the whole repository. Do not infer the active version from filenames, ZIP names or old conversations when current repository metadata is available.

## 3. Sources of truth

Authority order:

1. `CURRENT.json` — current stable baseline and canonical pointers.
2. `runtime/current.json` — exact active EXE/DLL stack and per-module source provenance/routing.
3. `src/<Module>/...` — canonical editable source when `source_path` points there.
4. candidate build metadata — exact hash/size of the source and DLL actually built for a work candidate.
5. `manifests/` and baseline metadata — hashes and rollback identity.
6. `artifacts/` — recovery, binary audits and deterministic reproducers.
7. `archives/`, `src/history/`, old baselines and legacy `source/` — historical evidence only unless the task explicitly requires recovery/rollback/reconstruction.

`source_sha256` / `source_size` in current routing are promotion fingerprints. During an intentional source-only experiment on `work` they may temporarily describe the last synchronized source snapshot; the fast verifier warns about that condition. Before stable promotion they must be synchronized with `python tools/sync_source_metadata.py` and checked by the deep gate.

If documentation conflicts with current machine-readable routing, stop treating the prose as authoritative and reconcile the inconsistency before continuing.

## 4. Git branch and commit protocol

- `main` = last accepted stable state.
- `work` = active development candidate.
- Normal edits go to `work`, not directly to `main`.
- `work` must contain current `main` before a new iteration starts.
- If `work` is stale/diverged, preserve any unique useful state under an archive branch if needed, then resynchronize `work` to `main`.
- Do not create a new stable baseline number for every experiment.
- Promote to `main` only after verification passes and the candidate is accepted as stable.
- When GitHub git-data tools are available, group one logical multi-file iteration into one tree/commit instead of using one Contents-API commit per file. This avoids duplicate CI runs and keeps rollback points meaningful.
- For updates to existing canonical source files, prefer the Git-data path `create_blob -> create_tree -> create_commit -> update_ref`. Use Contents API `update_file` only for small/simple text-file edits when appropriate. If a Contents-API write is blocked before reaching GitHub, retry through the normal Git-data path instead of asking the user to edit or upload files manually.

The AI owns routine branch synchronization and commit hygiene. Do not ask the user to merge, rebase or resolve routine repository state manually when GitHub tools can do it.

## 5. Change discipline

For every requested change:

- Prefer the smallest isolated modification that can satisfy the request.
- Preserve unrelated working behavior.
- Do not rewrite stable modules without a concrete reason.
- Do not silently change game version, architecture, offsets, hook semantics or calling conventions.
- Never introduce TBC/Wrath/Retail API assumptions into 1.12.1 code.
- If an API/address/structure is uncertain for build 5875, say so in the implementation notes and prefer the safer verified path.
- Treat filenames as labels, not evidence of actual behavior.
- Verify important behavior from source, binary audit, reproducer, disassembly evidence or user test results.

For binary patches/hook changes preserve enough information to rollback: original location/bytes or ancestor artifact, new bytes/logic, provenance and expected behavior.

## 6. Canonical source rules

`src/` is the only normal editable source root.

When `runtime/current.json` provides `source_path`, that exact file is the canonical editable lineage for that active module.

Source classifications must remain explicit. Examples:

- original/exact source,
- reconstructed source,
- functionally equivalent reconstruction,
- binary-patch lineage,
- exact source archived/recoverable.

Never relabel reconstructed code as original source. Never overwrite exact source with a reconstruction.

If an active module lacks a direct editable source file, first use its recorded restore/recovery/audit/reproducer metadata. Only search historical material as broadly as required to recover the lineage.

## 7. Metadata responsibility

Whenever a change invalidates runtime/baseline identity, the AI must update that metadata in the same candidate rather than leaving manual cleanup for later.

Potentially affected files include:

- `runtime/current.json`,
- `CURRENT.json`,
- relevant `baseline/<version>/` metadata,
- SHA256 manifests,
- source inventory/provenance docs,
- recovery/reproducer references,
- current-version documentation.

For high-frequency source-only experiments, do **not** manually recalculate source fingerprints on every attempt. Let candidate build metadata record the exact source compiled. Before stable promotion run:

```text
python tools/sync_source_metadata.py
python tools/sync_source_metadata.py --check
```

Do not update unrelated hashes or baseline records merely to make CI green. Fix the underlying inconsistency.

## 8. Verification and build protocol

Normal iteration gate:

```text
python tools/verify_current.py
```

Compact state inspection:

```text
python tools/ai_status.py
python tools/ai_status.py --json
```

Build one explicitly selected active module:

```text
python tools/build_active_module.py --name <runtime-dll-name>
```

Normal generic candidate route:

```text
python tools/build_changed_active.py --base <previous-git-sha>
```

This detects changed active `source_path` files, builds only those modules, and packages one candidate stack. Changes to the generic builder/runtime routing cause a full active-stack build audit.

Deep stable/recovery audit:

```text
python tools/verify_repo.py
```

A candidate is not ready for user testing until the fast gate passes and changed active modules build successfully. Stale source promotion fingerprints after an intentional source edit are warnings on `work`, not runtime-integrity failures.

A stable promotion requires synchronized source fingerprints and the deep audit when applicable.

If verification fails, inspect the failure, fix the actual repository inconsistency and rerun. Do not weaken checks simply to force a pass unless the check itself is demonstrably wrong.

## 9. High-frequency iteration policy

This project may undergo tens or hundreds of iterations. Optimize for low context cost and low repository entropy:

- use current machine-readable routing instead of repeatedly rediscovering the repo,
- keep commits focused and meaningfully named,
- prefer one logical multi-file commit over serial per-file commits,
- avoid duplicated living documentation,
- keep historical evidence out of the normal read path,
- prefer deterministic scripts over manual reconstruction steps,
- build only changed active modules during ordinary iterations,
- preserve stable rollback points,
- do not accumulate temporary debug files/logs in Git,
- do not create throwaway version-number churn for every test,
- do not run deep recovery audits on every work experiment when the fast gate is sufficient.

When several experiments are required, keep them on `work` as candidate commits until a tested stable result is chosen.

## 10. Packaging and delivery

When the user needs a runnable test package, the AI should prepare it rather than telling the user to assemble files manually.

For this project, when a package contains the active WoW executable, keep the `.exe` in the ZIP root next to the active DLLs unless a specific different layout is required.

Include only what the user needs to test plus concise instructions when necessary. Do not bury the active executable or DLL set inside unnecessary nested folders.

The generic candidate workflow should produce one complete ZIP and machine-readable candidate/build metadata so future AI does not need to reconstruct what was built from CI logs.

## 11. Communication with the user

The user should be able to work primarily by describing desired behavior and reporting test results.

Do not require the user to understand Git internals, repository layout or source provenance unless it is relevant to a decision.

After an implementation, report briefly:

- what changed,
- which module(s) changed,
- verification result,
- what exactly the user should test,
- whether `work` only or stable `main` was updated.

When debugging, distinguish clearly between verified facts, likely diagnosis and assumptions still requiring in-game confirmation.

## 12. Definition of done

For an experimental candidate:

- requested behavior is implemented,
- unrelated modules are untouched unless required,
- canonical source path/provenance is correct,
- runtime identity metadata remains consistent,
- rollback remains possible,
- `tools/verify_current.py` passes (candidate source-fingerprint warnings are acceptable after an intentional source edit),
- changed active modules build through their verified x86 recipes,
- candidate is committed to `work`,
- a runnable test package is prepared when needed,
- user receives a clear test instruction/artifact when needed.

For a stable release additionally:

- user has accepted the behavior or explicitly requested promotion,
- `tools/sync_source_metadata.py --check` passes,
- deep audit passes when applicable,
- `main` is updated,
- stable baseline/version metadata is updated if the runtime changed,
- `work` is returned to a clean synchronization point with `main` for the next iteration.
