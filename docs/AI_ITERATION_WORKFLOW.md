# AI iteration workflow

## Objective

Optimize the repository for tens or hundreds of short development loops without losing a known-good rollback state.

## Branch model

- `main` — accepted stable state only.
- `work` — current candidate state being edited/tested.
- archive branches — exceptional preservation points only; they are not normal development branches.

Before starting a new candidate, `main` must be an ancestor of `work`. Normally `work` is reset/fast-forwarded to current `main` immediately after a stable promotion.

## Iteration lifecycle

### 1. Route, do not rediscover

Read:

1. `AI_INDEX.json`
2. `CURRENT.json`
3. `runtime/current.json`

Then open only the relevant module source and its local README/audit if needed. Repository-wide searching is a fallback, not the default.

### 2. Modify the smallest surface

Prefer one functional change per commit. Do not rewrite stable unrelated modules just to normalize style.

If a runtime module has `source_path`, that exact path is the editable lineage for the current state. Other files with similar names can be recovery evidence or reconstructions and must not silently replace it.

### 3. Keep candidate metadata internally consistent

When canonical source bytes change, update the source hash/size metadata that points to them. When a runtime DLL/EXE changes, update its runtime hash and the appropriate SHA256 manifest. Do not claim a rebuilt binary is byte-identical unless verified.

### 4. Fast verify

Run:

```bash
python tools/verify_current.py
```

This gate is version-agnostic and follows `CURRENT.json` / `runtime/current.json`.

Optional compact context for AI/human review:

```bash
python tools/ai_status.py
python tools/ai_status.py --json
```

### 5. Test on `work`

A passing verifier means repository metadata is coherent; it does not prove the in-game behavior. User testing remains the acceptance step for runtime behavior.

Failed candidates remain in Git history and may be amended/reverted, but are not promoted to `main`.

### 6. Promote a working state

After acceptance:

- assign the next stable baseline (`V69`, `V70`, ...),
- create/update `baseline/<version>/`,
- create the version SHA256 manifest,
- update `CURRENT.json`, `runtime/current.json`, `CURRENT_VERSION.md` and changelog,
- preserve the previous baseline unchanged,
- run `python tools/verify_current.py`,
- run the relevant deep recovery/baseline checks,
- update `main`,
- synchronize `work` to the new `main`.

## Version-number policy

A stable version number represents a useful rollback point. It is not necessary to consume a new version number for every experimental source edit or every chat turn.

Examples:

- five attempts to fix one AutoPP behavior can all live on `work` while V68 stays stable;
- once attempt 5 is accepted, the accepted state can become V69;
- the next unrelated accepted feature can become V70.

## Directory policy

- `src/` — first place AI should look for editable code.
- `runtime/` — active stack metadata.
- `baseline/` — stable rollback metadata, never a scratch area.
- `artifacts/` — recovery/audit/reproducer evidence; read on demand.
- `archives/` — deprecated/intermediate material; avoid in normal development.
- `source/` — legacy/historical material only.

## Commit-message convention

Use a functional subject, for example:

```text
AutoPP: avoid selector skip after failed loot
MovementCore: retry rear-only LOS candidate
Repo: add version-agnostic AI verification
```

Avoid subjects that only say `update`, `new version` or `V69` without describing the change.

## Rules for long AI sessions

- Never rely on chat memory as the sole record of the active runtime.
- Never infer the current module from the newest-looking filename.
- Re-read `CURRENT.json` and `runtime/current.json` after another agent/user changes the repository.
- Prefer deterministic scripts and manifests over prose claims.
- Preserve provenance: original source, reconstructed source and binary-patched descendants are different evidence classes.
