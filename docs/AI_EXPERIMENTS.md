# AI experiment lifecycle and GitHub recovery

For ordinary non-promotion work, first verify `runtime/ai_startup_snapshot.json` against the five canonical startup-source Git blob identities at the same live branch HEAD; when valid, it satisfies startup context. Fall back to AGENTS.md, AI_START_HERE.md, AI_INDEX.json, CURRENT.json and runtime/current.json **in that order** for promotion, startup-contract edits, recovery/ambiguity, or any snapshot mismatch. For routing, read the generated compact `runtime/ai_experiment_index.json` next and inspect relevant live branch refs **before opening module source**. The authoritative evidence ledger remains `runtime/ai_experiments.json`; load it only when compact routing is insufficient or evidence must be changed. Neither file is live HEAD, accepted binary identity or gameplay proof.

## Route and create experiments

1. Honor a user-selected development branch (`pararell` means `parallel`). Otherwise inspect `runtime/ai_experiment_index.json` first (or run `python tools/ai_experiments.py route --module MODULE`) and check the named live feature/development refs before source analysis. `ambiguous` means inspect intended functionality, hooks and dependencies; never choose a winner arbitrarily. The compact index is generated with `python tools/ai_experiments.py index` and CI checks it with `index --check`; never edit it by hand.
2. Confirm the real GitHub branch HEAD, recent commits, `CURRENT.json`, `runtime/current.json`, canonical `source_path`, loader order and branch-specific ABI/hook registries. `runtime/parallel_dependency_registry.json` on parallel remains the detailed dependency evidence; the general ledger does not replace it.
3. Continue an existing experiment only when its mechanism and dependencies match. For independent work, create short-lived `feature/SHORT-PURPOSE` from an appropriate current verified base commit. Treat cooperating DLLs as one experiment. Do not create permanent per-DLL branches or move unrelated work between `parallel` and `work`.
4. Update the ledger with the goal, branch, modules, dependencies, resource ownership and actual test evidence. `observed_head` is a dated snapshot; refresh HEAD directly from GitHub before every write. `verified_commit` and `package` stay null until actual evidence exists.

## Verify, record tests and integrate

Before writing, read the current target HEAD/file hashes and determine whether the intended edit already landed. One logical iteration is one coherent commit; verify branch HEAD afterward. Run `verify_current.py`, `verify_runtime_artifacts.py`, `verify_verified_symbols.py` and the relevant branch-specific checks. The new AI experiment workflow validates registry logic and existing runtime metadata; it **does not build Windows binaries, finalize game ZIPs or certify gameplay**.

For a user-reported game test, record the exact tested commit with `python tools/ai_experiments.py record-test --experiment ID --kind game --result passed --commit FULL40SHA --date YYYY-MM-DD --evidence 'user report and tested artifact ID' --output runtime/ai_experiments.json`. Review and commit the ledger update. The command records evidence, not independent proof that the test succeeded. A successful module test does not accept all experiments in that branch.

Before integration, compare shared hook addresses, competing writers, public ABI, DLL load order, active runtime configuration and every required dependency. Curate **only** accepted changes and necessary dependencies onto an isolated integration/promotion branch. Run verification and package gates again against the resulting exact SHA. Stable promotion is still protected by `promote/...` plus the exact-SHA pre-promotion workflow; do not merge an exploratory branch wholesale into main. Infrastructure-only changes do not consume Vxx or modify runtime bytes.

Runnable test packages must be attributable to the branch, full commit, EXE and DLL identities, loader order, build sources and final package verification. If a branch's existing package metadata lacks one of these fields, extend that branch's package workflow before claiming full traceability.

## Recover after interruption

Re-read the target's current GitHub HEAD, relevant changed paths/commits and Actions tied to the **exact SHA**; inspect artifacts if a build was requested. If a write is present, continue from its confirmed state. Otherwise refresh blob hashes and apply only the missing change. Never retry a GitHub write blindly, force-push, reset unique commits, report a previous SHA's CI as current, or claim a playable artifact before FINAL_PACKAGE: PASS.

Current limitations: branch selection is deterministic advisory output and does not autonomously create refs; AI creates the selected branch through GitHub after checking the live base. Hook conflict checks cover only explicitly registered resources and cannot prove in-game compatibility. Existing historical experiments have unknown test outcomes unless a concrete report is attached.
