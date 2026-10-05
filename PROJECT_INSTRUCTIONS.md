# Project instructions — WoW112 AI-first workflow

Project scope is permanently **World of Warcraft 1.12.1 build 5875, Windows x86**.

`AGENTS.md` is authoritative. This file is deliberately compact.

## Canonical routing

- `main` is the only normal integration/development trunk.
- `parallel` is an exact delivery compatibility alias maintained atomically with `main`.
- `feature/**` branches are short-lived task branches based on current `main`.
- `promote/**` branches are curated release snapshots.
- `work` is legacy compatibility/history only.
- `parallel-testpoint` is an optional frozen user-test pointer, not a development branch.

Do not infer authority from legacy filenames such as `parallel_*`, `work_*` or `runtime/parallel_*`.

## Startup and execution

Ordinary task:

```text
resolve main HEAD
-> verify runtime/ai_startup_snapshot.json
-> read runtime/ai_experiment_index.json
-> inspect owner files only
-> implement on feature/<purpose>
-> targeted preflight
-> canonical queue integration
-> routed exact-SHA delivery
```

Use the full startup sequence only for stale/unverifiable snapshot, startup-contract edits, release work, ambiguous writes or unresolved authority.

Do not enumerate all feature branches, scan history/archives, read the full experiment ledger or inspect successful CI logs on the normal success path.

## Concurrency

Independent feature coding/preflight may run concurrently. Only final canonical trunk movement is serialized.

Each new feature owns one `runtime/parallel_tasks/<task-id>.json` coordination record. Shared resources are a signal for ordered integration/arbitration, not a reason to globally lock development.

Global lease reconciliation is diagnostic/manual; leases are not required in the normal hot path.

## Verification

Use routed checks based on changed paths and risk. Unknown/mixed/shared runtime changes fail closed to STANDARD. Profile-contained changes run only their required profile gates. Docs/task-record-only changes do not pay for unrelated binary builds.

Deep repository, full AI registry and broad ABI audits are scheduled/manual/PR/release checks.

Never weaken a verifier to obtain PASS.

## Stable byte identity

Stable/release packaging is performed from a curated `promote/**` exact SHA and uses exact accepted bytes via `tools/package_exact_current.py` plus `tools/verify_candidate_package.py`.

`main` remains the canonical integration trunk; stable identity is baseline/artifact metadata.
