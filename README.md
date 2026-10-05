# wow112

AI-first repository for **World of Warcraft 1.12.1 build 5875, Windows x86**.

## Start here

Normal AI startup is intentionally small:

1. live `main` HEAD,
2. verified `runtime/ai_startup_snapshot.json`,
3. `runtime/ai_experiment_index.json`,
4. only the affected module/owner files.

Use the full five-file authority sequence (`AGENTS.md`, `AI_START_HERE.md`, `AI_INDEX.json`, `CURRENT.json`, `runtime/current.json`) only when the snapshot is stale/unverifiable, startup authority is being edited, a release is being prepared, or repository state is ambiguous.

## Branch model

- `main` — canonical integration/development trunk.
- `parallel` — exact compatibility/delivery alias synchronized atomically with `main`.
- `feature/**` — short-lived task branches.
- `promote/**` — curated release snapshots.
- `work` — legacy compatibility/history.
- `parallel-testpoint` — optional frozen user-test pointer.

Stable state is baseline/artifact metadata, not a permanent branch role.

## Normal workflow

```text
main -> feature -> targeted preflight -> canonical integration ->
atomic main+parallel -> routed exact-SHA delivery -> user test
```

Heavy repository-wide audits are scheduled/manual/PR/release checks, not part of every microfix.

## Canonical layout

- `CURRENT.json` — routing/tool pointers and stable baseline metadata.
- `runtime/current.json` — exact active EXE/DLL stack and provenance.
- `src/` — canonical editable source root.
- `runtime/parallel_tasks/` — short-lived task coordination metadata.
- `baseline/`, `manifests/`, `artifacts/runtime_cache/` — stable rollback/exact-byte evidence.
- `archives/`, `src/history/`, `source/` — historical/recovery material; do not scan by default.

Historical filenames containing `parallel` or `work` may remain for compatibility; they do not define branch authority.

Full contract: `AGENTS.md`.
