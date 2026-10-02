# Project instructions — WoW112 AI-first workflow

Project scope is permanently **World of Warcraft 1.12.1 build 5875, Windows x86**.

This document is intentionally short. `AGENTS.md` is the authoritative operating contract; do not maintain a competing copy of the workflow here.

## Mandatory startup

Read:

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`

Then open only the files needed for the requested module.

## Canonical state

- `CURRENT.json` — baseline, branches, canonical tool/data pointers.
- `runtime/current.json` — exact active runtime and source provenance.
- `src/` — normal editable source root.
- baseline/manifests — stable rollback identity.
- `artifacts/runtime_cache/<sha256>.dll.xz` — exact-byte stable recovery cache.
- `source/`, `archives/`, `src/history/` — legacy/history only.

Machine-readable routing wins over stale prose.

## Branch contract

- `main` = accepted stable.
- `work` = existing development; `parallel` = independent alternative development.
- `feature/**` = short-lived isolated experiments based on the correct live SHA.
- `promote/**` = curated stable candidate only.

Route new requests through `runtime/ai_experiments.json`, `tools/ai_experiments.py` and live GitHub module/branch inspection. Respect explicit `parallel`; do not transfer unaccepted state between branches. See `docs/AI_EXPERIMENTS.md`.

Do not push an unverified promotion directly to `main`. The exact `promote/**` SHA must first pass `.github/workflows/pre_promote_stable.yml`.

## Stable byte identity

A stable package is assembled from exact accepted runtime bytes and verified against `runtime/current.json`. It is not defined by a fresh source rebuild.

Use:
- `tools/package_exact_current.py`
- `tools/verify_candidate_package.py`

## Verification

Routine:
`python tools/verify_current.py`

Stable promotion additionally:
`python tools/sync_source_metadata.py --check`
`python tools/verify_runtime_artifacts.py`
`python tools/verify_verified_symbols.py`
`python tools/verify_repo.py`

Never weaken a verifier merely to obtain PASS.

## Operational latency

Minimize time from an accepted change request to a verified test artifact. Use batch exact-SHA workflow checks, avoid per-job/per-step success polling, inspect logs only to diagnose failures, and let independent gates run concurrently. For a small already-understood one-module fix, 4–6 minutes is the operational target when runner capacity permits. Never skip or weaken verification to meet the target; `AGENTS.md` section 14 is authoritative.
