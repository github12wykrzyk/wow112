V68 CANONICAL STORAGE = DELTA AGAINST V67

Do NOT use the old full-bundle chunks under archives/ as the source of truth.
They were an intermediate connector workaround and are deprecated.

Canonical V68 runtime delta:
artifacts/V68/runtime/
- MovementCore_V68.dll.xz.b64.part000..003
- README_RESTORE.md

Canonical V68 source:
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

V68 reconstruction rule:
V68 = V67 runtime + replace only MovementCore with the verified V68 DLL above.
The active EXE and the other 7 active DLLs are unchanged from V67.

Repository retention policy: keep at most the latest 10 working versions.
