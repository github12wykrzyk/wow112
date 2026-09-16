# Development workflow

The detailed high-frequency AI loop is documented in `docs/AI_ITERATION_WORKFLOW.md`. This file defines the repository-level contract.

## Branches

- `main` — last accepted stable state.
- `work` — current development candidate.

`work` must contain current `main` before a new iteration. GitHub Actions checks this relationship on pushes to `work` so long-lived divergence does not silently accumulate.

## Normal candidate flow

1. Synchronize `work` to current `main`.
2. Read `AI_START_HERE.md`, `CURRENT.json` and `runtime/current.json`.
3. Modify the smallest relevant module surface.
4. Keep current-branch metadata internally consistent.
5. Run `python tools/verify_current.py`.
6. Commit the candidate to `work`.
7. Test in the actual WoW 1.12.1 build 5875 environment.
8. Repeat on `work` until the candidate is accepted.

A candidate does not need a new stable baseline number for every failed/experimental attempt.

## Stable promotion

When a candidate is accepted:

1. assign the next baseline (`V69`, `V70`, ...),
2. create the new `baseline/<version>/` metadata,
3. create/update the SHA256 manifest for that stable version,
4. update `CURRENT.json`, `runtime/current.json`, `CURRENT_VERSION.md` and changelog,
5. preserve the previous baseline unchanged,
6. run `python tools/verify_current.py`,
7. run applicable deep recovery/baseline checks (`python tools/verify_repo.py` plus module-specific restore/audit tools when relevant),
8. promote to `main`,
9. synchronize `work` to the new `main`.

## Verification split

### Fast/current gate

`tools/verify_current.py` is version-agnostic. It follows pointers in `CURRENT.json` and `runtime/current.json` and checks:

- WoW 1.12.1 / build 5875 / x86 invariants,
- AI routing contract,
- current baseline/runtime agreement,
- DLL list order,
- SHA256 manifest agreement,
- direct canonical EXE hash/size,
- canonical source existence and source hashes/sizes when recorded,
- canonical source paths under `src/`,
- referenced recovery/audit/reproducer files,
- absence of tracked `.log`, `.dmp` and `.mdmp` files.

### Deep baseline/recovery gate

`tools/verify_repo.py` preserves deeper V68-era recovery checks, including MovementCore recovery archive verification. Deep checks are valuable when auditing/promoting a stable baseline, but should not be the only mechanism used for daily iteration because they can be baseline-specific.

## Source rules

`runtime/current.json` is authoritative for source provenance. New canonical source paths belong under `src/<Module>/`.

`source/` is retained as legacy/history only. `source/V20_SOURCE_PARTS/` remains explicitly non-canonical.

`.gitattributes` keeps deterministic source/metadata line endings so hashes do not depend on Windows `core.autocrlf` behavior.

## Binary-change rule

For a DLL/EXE change preserve:

- previous stable rollback,
- new runtime SHA256,
- functional description,
- source/diff or explicit reconstruction/binary-patch lineage,
- rollback method,
- exactness claim only at the level actually verified.
