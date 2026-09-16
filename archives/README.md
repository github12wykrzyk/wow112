# Archives

This directory contains deprecated/intermediate connector-era archive experiments.

## AI rule

Do **not** scan or use `archives/` during normal development. Start from `AI_START_HERE.md`, `CURRENT.json` and `runtime/current.json` instead.

Do **not** use `archives/V68_FULL_NO_EXE_BUNDLE_B64/` or other V68 full-bundle chunk experiments as canonical V68 source/runtime.

Canonical current state is represented by:

- `CURRENT.json`
- `runtime/current.json`
- `baseline/<current>/`
- current SHA256 manifest
- `CURRENT_VERSION.md`

For V68-specific recovery evidence use:

- runtime delta: `artifacts/V68/runtime/`
- source recovery: `artifacts/V68/source/`

Verified V68 hashes:

- MovementCore DLL SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`
- runtime XZ SHA256: `b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a`
- v20 source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- source XZ SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`

## Retention

There is **no automatic numeric retention limit** for stable working baselines. Stable versions remain available for rollback/comparison. Archive experiments may be deleted only deliberately when they are duplicated, damaged or technically useless.

The authoritative retention policy is `docs/VERSION_RETENTION.md`.
