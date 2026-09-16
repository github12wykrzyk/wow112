# Archives

This directory contains intermediate connector-era archive experiments.

## Important

Do **not** use `archives/V68_FULL_NO_EXE_BUNDLE_B64/` or other V68 full-bundle chunk experiments as the canonical V68 source.

Canonical V68 is represented as a verified delta against V67:

- runtime delta: `artifacts/V68/runtime/`
- source: `artifacts/V68/source/`
- baseline metadata: `baseline/V68/`
- current status: `CURRENT_VERSION.md`

Verified V68 hashes:

- MovementCore DLL SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`
- runtime XZ SHA256: `b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a`
- v20 source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- source XZ SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`

Repository retention policy: keep at most the latest 10 working versions. Archive experiments are not counted as working baselines.
