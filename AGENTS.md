# AGENTS.md — AI AUTOPILOT CONTRACT

This repository is operated primarily by AI agents. The human user describes desired behavior and tests verified artifacts; AI owns routine GitHub edits, branch housekeeping, verification, packaging and rollback.

Target is permanently **World of Warcraft 1.12.1 build 5875, Windows x86** unless the user explicitly requests a comparison.

## 1. Canonical authority

Use this order of authority:

1. live GitHub `main` HEAD — canonical integration state,
2. `CURRENT.json` — canonical routing/tool pointers and stable baseline metadata,
3. `runtime/current.json` — exact active EXE/DLL identities and source provenance,
4. `src/<Module>/...` — normal editable source when referenced by runtime metadata,
5. exact-SHA candidate/package metadata,
6. baseline/manifests and `artifacts/runtime_cache/` — rollback and exact-byte recovery,
7. archives/history/legacy `source/` — recovery evidence only.

If prose conflicts with live `main` plus machine-readable metadata, live `main` and machine-readable metadata win; repair the prose.

## 2. Branch model — one development world

- `main` = **canonical integration trunk and normal development authority**. It may be in candidate state.
- `parallel` = exact compatibility/delivery alias. The queue moves `main` and `parallel` atomically to the same integrated SHA. Do not treat it as an independent development world.
- `feature/**` = short-lived branch for one isolated task, normally created from current `main`.
- `promote/**` = curated release/stable-candidate snapshot used only for release gates.
- `work` = legacy compatibility/history branch. Do not route ordinary new work there.
- `parallel-testpoint` = optional frozen user-test delivery pointer. It is not a development trunk.
- Stable state is a **baseline/artifact property**, not a permanent branch role.

Files/tools with historical names such as `parallel_*`, `work_*`, `runtime/parallel_*` remain valid compatibility interfaces. Their names do not override the branch model above.

Never ask the user to merge, rebase, synchronize or clean routine branch state manually.

## 3. Startup fast path — default

For an ordinary task:

1. Resolve current live `main` HEAD once.
2. Read `runtime/ai_startup_snapshot.json`.
3. Verify its five `source_files[*].git_blob_sha1` values against Git tree metadata from that same `main` HEAD.
4. If valid, read `runtime/ai_experiment_index.json` and only the affected module/owner files.
5. Use `python tools/ai_task_context.py --branch main --module MODULE` when useful.
6. Start implementation from that bounded context.

Do **not** enumerate all branches, scan commit history, read the full experiment ledger, inspect archives, or fetch broad CI logs on the normal success path.

Fall back to the full startup sequence only when the snapshot is missing/stale/unverifiable, startup authority files are being edited, a release/promotion is being prepared, a previous write is ambiguous, or ownership/authority cannot be resolved:

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`
6. only evidence needed for the unresolved risk.

## 4. Analysis budget — implementation first

Default rule: **route, inspect the owner, implement, test**.

Broad archaeology is justified only by a concrete trigger such as:

- unknown mechanism owner,
- shared hook/ABI/load-order conflict,
- merge conflict,
- provenance or exact-byte mismatch,
- verifier/build/package failure,
- ambiguous active experiment that the compact index cannot resolve,
- explicit user request for history/audit/research.

Do not broaden analysis merely because more repository history exists.

For a small understood addon/Lua fix, inspect only the relevant addon files and direct dependency/contract files. For native/shared changes, inspect the hook/ABI/build recipe needed to make the change safely. For workflow/control-plane changes, inspect the touched contracts and tests.

## 5. Normal implementation lifecycle

For ordinary new work:

1. resolve current `main` SHA,
2. create/reuse the matching short-lived `feature/<purpose>` branch from that SHA,
3. own exactly one `runtime/parallel_tasks/<task-id>.json` task record,
4. make the smallest coherent change,
5. run the routed feature preflight against `main`,
6. run exact feature-SHA profile gates only when declared/required,
7. let the serialized queue revalidate against current `main`,
8. integrate with one merge commit,
9. atomically move `main` and `parallel` to the same integrated SHA,
10. dispatch only the exact-SHA delivery profiles selected by the risk/path router,
11. delete the integrated feature branch after successful delivery.

The hot path is targeted. Repository-wide audits are nightly/manual/PR/release work, not a prerequisite for every micro-iteration.

One logical multi-file iteration should be one Git tree commit when git-data tools are available:
`create_blob -> create_tree -> create_commit -> update_ref`.

## 6. Verification and delivery

Do not equate `PREFLIGHT PASS` with `TEST READY`.

Required checks are determined by changed paths and risk:

- addon/module-local changes: targeted Lua/contract tests,
- native changes: relevant ABI/provenance/dependency checks plus changed-module x86 build,
- ECONOMY/UPDATER/AUTOLOGINBRIDGE changes: their exact profile gate,
- uncovered/shared/native-core/workflow-control changes: fail closed to STANDARD,
- docs/task-record-only changes: no unnecessary binary delivery.

The post-integration router is fail-closed: unknown or mixed runtime changes require STANDARD.

Only offer a runnable artifact when its exact integrated SHA has all required delivery gates and final package verification. Fetch jobs/steps/logs only on failure, cancellation, unexpected stall, or when a specific gate needs diagnosis.

Heavy repository checks (`verify_repo.py`, full AI registry suite, deep baseline/recovery audit, broad ABI audit) run nightly/manual/PR/release and must not be reintroduced into every feature hot path.

## 7. Source and provenance rules

`src/` is the normal editable source root.

When `runtime/current.json` names `source_path`, edit that lineage. Never choose source by filename similarity.

Keep provenance explicit:
- original/exact source,
- reconstructed source,
- functionally equivalent reconstruction,
- binary-patch lineage,
- exact archived/recoverable source.

Never relabel reconstruction as original source. Do not weaken verifiers to make CI green.

## 8. Stable/release flow

`main` remains the canonical integration trunk; a stable release does **not** require redefining `main` as a stable-only branch.

For a stable/release candidate:

1. start from current `main`,
2. curate only accepted runtime/source/metadata into `promote/<purpose>`,
3. set stable metadata consistently,
4. synchronize source fingerprints,
5. require `.github/workflows/pre_promote_stable.yml` PASS on the exact promote SHA,
6. require exact-byte stable packaging and final package verification,
7. run `Build stable candidate` explicitly on that exact curated release SHA,
8. preserve/update stable baseline metadata and rollback artifacts only after acceptance.

Stable packages use exact accepted runtime bytes via `tools/package_exact_current.py`; a fresh rebuild is not a stable identity substitute. If accepted release metadata must return to the trunk, integrate that metadata through the normal feature/main queue.

## 9. Recovery after interruption

A ChatGPT/UI/network failure is not evidence that a GitHub operation failed.

After an ambiguous operation:

1. read the current target ref and exact relevant file/commit state,
2. check Actions for the intended exact SHA,
3. if the write exists, continue from it,
4. if absent, refresh current hashes and apply only the missing change,
5. never replay an uncertain write blindly or claim a different SHA's CI as current.

Do not continuously poll successful CI. Progress updates should correspond to durable state transitions, not extra API traffic.

## 10. Repository hygiene

Do not commit generated `build/`, `dist/`, runtime debug logs/dumps, `.wow112_debug`, updater local state or unrelated artifacts.

Historical material stays out of the normal read path. Prefer deterministic scripts and machine-readable metadata over duplicated prose.

## 11. External research

Public technical research is allowed when local evidence is insufficient and can materially improve the solution. Treat external claims/code as hypotheses until validated against WoW 1.12.1 build 5875 / Windows x86 and current repository evidence.

Research is not mandatory for trivial already-proven edits and must not become a substitute for implementation.

## 12. Communication and definition of done

Report briefly:
- what changed,
- affected module/infrastructure surface,
- exact integrated SHA when available,
- required CI/delivery result,
- artifact/test action only when relevant.

A normal task is done when the intended change is integrated into canonical `main`, `parallel` matches that exact SHA, required routed gates pass, and any promised runnable artifact is verified. A release task is done only after the exact curated release SHA passes its release gates and exact-byte packaging.
