# AI START HERE

This repository is optimized for fast repeated AI-assisted development of **World of Warcraft 1.12.1 build 5875, Windows x86**.

`AGENTS.md` is authoritative. The central rule is:

> **`main` is the one canonical integration/development trunk. `parallel` is an exact compatibility/delivery alias, not a second development world.**

## Fast startup

For ordinary work:

1. resolve live `main` HEAD once,
2. verify `runtime/ai_startup_snapshot.json` against the five startup-source Git blob identities from that same HEAD,
3. read `runtime/ai_experiment_index.json`,
4. open only the affected module/owner files,
5. optionally run:

```text
python tools/ai_task_context.py --branch main --module MODULE
```

Do not scan all branches, history, archives, the full experiment ledger or successful CI logs unless a concrete unresolved risk requires it.

Fallback read order for startup-contract edits, release work, ambiguous writes, stale snapshot or unresolved authority:

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`
6. only the evidence needed for the unresolved issue.

## Branches

- `main` — canonical integration trunk and source of normal development truth.
- `parallel` — atomically synchronized exact delivery alias.
- `feature/**` — short-lived task branches from current `main`.
- `promote/**` — curated release/stable-candidate snapshots.
- `work` — legacy compatibility/history only.
- `parallel-testpoint` — optional frozen user-test pointer, not a development trunk.

Stable state is represented by baseline/runtime metadata and exact accepted artifacts, not by treating `main` as stable-only.

Historical `parallel_*` / `work_*` filenames are compatibility names and do not imply independent branch authority.

## Default task path

```text
main HEAD
-> compact routing/task context
-> owner files only
-> feature/<purpose>
-> smallest implementation
-> routed preflight
-> exact feature-SHA profile gates if required
-> serialized revalidation/integration into main
-> atomic main + parallel update
-> risk/path-routed exact-SHA delivery
-> delete integrated feature branch
```

`PREFLIGHT PASS` is not `TEST READY`. Only the required exact integrated-SHA delivery gates and package verification can make a runnable candidate ready.

## Analysis discipline

Broaden beyond owner files only when there is a concrete reason: shared hook/ABI conflict, unknown owner, merge conflict, provenance mismatch, verifier/build failure, ambiguous experiment routing, or an explicit audit/history request.

The full experiment ledger (`runtime/ai_experiments.json`) is evidence/detail fallback. The compact generated index is the routing default.

## Verification

Normal micro-iterations use the routed feature preflight and only the checks selected for their changed paths/risk.

Repository-wide verification is intentionally outside the hot path:
- deep repository audit: nightly/manual/PR,
- full AI registry suite: nightly/manual/PR,
- broad native ABI audit: scheduled/manual,
- stable release gates: `promote/**` + explicit stable build.

Do not reintroduce these heavy checks into every feature.

## Release path

A release is a curated `promote/<purpose>` snapshot based on current `main`.

Require `Pre-promote stable` PASS on the exact promote SHA, then run `Build stable candidate` explicitly on that same curated release SHA. Stable packaging uses exact accepted bytes through `tools/package_exact_current.py` and `tools/verify_candidate_package.py`.

`main` remains the canonical integration trunk before and after release.

## Ready-to-test

A TEST artifact is ready only when:
- feature preflight passed,
- the feature was integrated into canonical `main`,
- `parallel` equals the same integrated SHA,
- all required routed delivery profiles passed on that exact SHA,
- final runnable package verification passed when a game ZIP is required.

For full rules see `AGENTS.md`.
