V68 CANONICAL STORAGE / RECONSTRUCTION

Do NOT use the old full-bundle chunks under archives/ as the source of truth.
They were an intermediate connector workaround and are deprecated.

CURRENT SOURCE OF TRUTH
- CURRENT.json
- runtime/current.json
- baseline/V68/dlls.txt
- manifests/SHA256SUMS_V68.txt
- CURRENT_VERSION.md

ACTIVE EXE
The patched V68/V67 client EXE is stored directly in repository root:
WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe
SHA256:
b24ebfe0a9fa49ba051911a904fc1dcb531d7c3908a35e77a84376d96b476f27

MOVEMENTCORE V68 DELTA
Canonical V68 MovementCore runtime delta:
artifacts/V68/runtime/
- MovementCore_V68.dll.xz.b64.part000..003
- README_RESTORE.md

Canonical V68 MovementCore source:
artifacts/V68/source/
- WoWMovementCore_v20.c.xz.b64.part000..003
- README_RESTORE.md

Verified hashes:
- Restored V68 MovementCore DLL SHA256:
  044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b
- Runtime XZ SHA256:
  b676a359abc681009bdbe5a1dddad851eef8e914343f0d2338838e6e2743726a
- Restored v20 source SHA256:
  764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888
- Source XZ SHA256:
  ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48

Verification performed against the local V68 build:
- xz -9 output matches repository XZ hashes exactly,
- all 4 runtime Base64 part Git blob SHAs match,
- all 4 source Base64 part Git blob SHAs match.

PROMOTED CURRENT PP RUNTIME
The original V68 release relationship was V67 + replacement of MovementCore only.
The CURRENT active V68 stack additionally promotes two deterministic descendants
whose exact binary ancestors remain preserved under artifacts/V67/runtime/:

1. AutoLootPP v0.13 -> v0.14 NOSKIP
   - final: WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll
   - SHA256: 05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845
   - reproducer: artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py
   - audit/docs: artifacts/AutoLootPP/

2. LongPickPocket v0.9 -> v1.0 ALLRANGE_360FACING
   - final: WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll
   - SHA256: dc4a8d85b850728f39e07a04c49a7f7b60e72b8ec2fdebb94b86dad3a47474d2
   - reproducer: artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py
   - audit/docs: artifacts/LongPickPocket/

Therefore do not infer the current active stack from the historical V67->V68
MovementCore delta alone. Always use runtime/current.json and baseline/V68/dlls.txt.

Repository retention policy: keep stable working versions available for rollback
and comparison; do not automatically delete older baselines.
