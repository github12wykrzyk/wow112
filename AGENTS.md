# AGENTS.md — AI AUTOPILOT CONTRACT

This repository is operated primarily by AI agents. Target is permanently **World of Warcraft 1.12.1 build 5875, Windows x86** unless the user explicitly requests otherwise.

## 1. Authority and branch model

- `main` = **canonical integration trunk and normal development authority**.
- `parallel` = **exact compatibility/delivery alias**; successful integration advances `main` and `parallel` atomically to the same SHA.
- `feature/**` = short-lived task branch from current `main`.
- `promote/**` = curated release snapshot.
- `work` = legacy compatibility/history only.
- `parallel-testpoint` = optional frozen user-test pointer.

Machine authority order when deeper evidence is actually needed:
`CURRENT.json` -> `runtime/current.json` -> exact source/provenance metadata -> rollback artifacts/history.

Historical `parallel_*` / `work_*` filenames are compatibility names, not branch authority.

## 2. GPT FAST EXECUTION — default

The default objective is **minimum wall-clock time in the ChatGPT interface**, not maximum narration.

For an ordinary understood task:

1. Resolve live `main` HEAD **once**.
2. Read `runtime/ai_startup_snapshot.json` **once** and trust the generated snapshot on canonical `main`.
3. Go directly to the named module/owner files.
4. Implement the smallest coherent change.
5. Run only routed validation/delivery.

Do **not** verify all five startup-source blob hashes on every ordinary task. Their hashes remain in the snapshot for CI/recovery; verify them only when editing startup authority, diagnosing a stale snapshot, recovering an ambiguous write, or preparing a release.

Do **not** read `runtime/ai_experiment_index.json` by default. It is optional historical/continuation routing evidence. Use it or `tools/ai_task_context_fast.py` only when the user explicitly wants to continue prior experimental work or ownership/current-task ambiguity is unresolved.

Do **not** enumerate all branches, scan history/archives, list all task records, or inspect successful CI logs on the normal success path.

### Chat/tool budget

- No progress chatter by default. Send a progress message only for a real blocker or when the user explicitly asks for updates.
- Never make GitHub/API calls solely to produce a ping.
- Cache file content/blob SHA/ref state within the turn; do not re-fetch unchanged state.
- Prefer direct known-path fetches over broad code search.
- Batch one logical multi-file iteration into one Git tree commit when git-data tools are available.
- The integration workflow already waits for exact-SHA downstream delivery. Chat should not repeatedly poll its sub-jobs.
- Inspect job steps/logs only after failure/cancellation/unexpected stall, or when the user explicitly asks for a check.
- A superseded same-feature run cancelled by `cancel-in-progress` is normal; diagnose only the newest exact feature SHA.

## 3. Analysis budget — implementation first

Default rule: **route, inspect the owner, implement, test**.

Broad archaeology is justified only by a concrete trigger such as:
- unknown mechanism owner,
- shared hook/ABI/load-order conflict,
- merge conflict,
- provenance/exact-byte mismatch,
- verifier/build/package failure,
- ambiguous active experiment that cannot be resolved from the current task,
- explicit user request for history/audit/research.

For a small addon/Lua fix, inspect only the affected addon and direct contract. For native/shared code, inspect the relevant ABI/hook/build recipe. For workflow/control-plane changes, inspect the touched policy and its regression tests.

## 4. Normal implementation lifecycle

1. Resolve current `main` SHA.
2. Create/reuse one `feature/<purpose>` from that SHA.
3. Own one `runtime/parallel_tasks/<task-id>.json`.
4. Implement one coherent change.
5. Run routed feature preflight against `main`.
6. Run exact feature-SHA profile gates only when required.
7. Start an **optimistic CAS integration attempt**: re-read live `main`, revalidate, merge locally, atomically push `main + parallel`.
8. If another integration wins the ref race, refetch/revalidate/retry; never force.
9. Dispatch only delivery selected by the path/risk router.
10. Delete the integrated feature branch after successful exact-SHA delivery.

Independent feature integrations may run concurrently. There is no serialized GitHub pending-slot queue.

## 5. Verification and delivery

`PREFLIGHT PASS` is not `TEST READY`.

- addon/module-local: targeted syntax/contract checks,
- native: relevant ABI/provenance/dependency checks + changed-module x86 build,
- ECONOMY/UPDATER/AUTOLOGINBRIDGE: exact declared profile gate,
- unknown/mixed/shared/native-core/workflow-control: fail closed to STANDARD,
- docs/task-record-only: no unrelated binary delivery.

Repository-wide audits are nightly/manual/PR/release work, not a prerequisite for every micro-iteration.

Only offer a runnable artifact when the exact integrated SHA has all required delivery/package gates.

## 6. Source, release and recovery

`src/` is the normal editable source root. Follow `runtime/current.json` provenance; never select source by filename similarity and never relabel reconstruction as original source.

Stable release work uses a curated `promote/<purpose>` exact SHA, pre-promotion verification, exact accepted bytes, and final package verification. `main` remains the integration trunk.

After an ambiguous ChatGPT/UI/network interruption, read the target ref and intended exact file/commit state once. Continue if the write exists; otherwise apply only the missing write. Never replay an uncertain write blindly.

## 7. Definition of done

Normal task: intended change integrated into canonical `main`, `parallel` equals the same SHA, required routed gates pass, and any promised artifact is verified.

Report only the useful result: what changed, exact integrated SHA when available, required CI/delivery result, and user test action when relevant.
