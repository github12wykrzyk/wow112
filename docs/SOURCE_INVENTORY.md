# Active runtime source inventory

Canonical active runtime is defined by `runtime/current.json`. This document is a human-readable provenance map only; if it conflicts with runtime metadata, fix this document.

## Current V68 active modules

| Runtime module | Source state | Canonical editable / recovery location |
| --- | --- | --- |
| `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll` | BINARY-VERIFIED RECONSTRUCTION / exact binary-patch lineage | `src/PositionalSpoof/WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix_RECONSTRUCTED.c` |
| `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll` | EXACT ORIGINAL SOURCE | `src/StealthCDGuardian/WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c` |
| `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll` | FUNCTIONALLY EQUIVALENT RECONSTRUCTION | `src/SpeedFloor/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG_RECONSTRUCTED.c` |
| `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll` | EXACT ORIGINAL SOURCE | `src/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.c` |
| `WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll` | FUNCTIONALLY EQUIVALENT RECONSTRUCTION + exact v0.13 binary-patch lineage | `src/AutoLootPP/WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK_RECONSTRUCTED.c` |
| `WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll` | FUNCTIONALLY EQUIVALENT RECONSTRUCTION + exact v0.9 binary-patch lineage | `src/LongPickPocket/WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025_RECONSTRUCTED.c` |
| `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll` | NORMAL SOURCE | `src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c` |
| `WoWPlayerESP_v1_2_range_sweep.dll` | EXACT ORIGINAL SOURCE, DIRECT + LOSSLESS ARCHIVE BACKUP | `src/WoWPlayerESP/WoWPlayerESP_v1_2_range_sweep.c` |

## AI routing rule

For code changes, do not choose a source by filename recency. Read the matching entry from `runtime/current.json`:

- if `source_path` exists, edit that lineage;
- if only `source_archive`, `source_archive_prefix` or `source_restore_doc` exists, follow the recovery metadata first;
- if reconstructed and original/evidence files coexist, preserve provenance and do not silently relabel reconstruction as original source.

## Exact source hashes currently secured

### MovementCore

- source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`
- size: `107833` B
- runtime DLL SHA256: `044053a23720e5e6b7ec89e19c213dd937837cee92c2d93cfbdbaa5263021d8b`

### PickPocketSelectiveRange v10

- source SHA256: `80130b9cb988dc9c60345aa764f9465a1d6e515bcfd9ff5e2128bb865d91206a`
- size: `9319` B
- runtime DLL SHA256: `efea7ea55788abf8bf7b6302c5576590b386d3cb29f78639e596e3984fd6c7ba`

The older reconstructed v10 file remains in the same module directory as independent evidence, but the original file named in `runtime/current.json` is canonical.

### StealthCDGuardian v2

- source SHA256: `c90f160ee4ae837e70c09b24dad2383c9a73621fa7b40df88639de95544e78f4`
- size: `11487` B
- runtime DLL SHA256: `2bc2f9be3bca94bd0fc77e2c7c0f4fbfa3669cc03787f2cba4214f0acb2e567e`

### WoWPlayerESP v1.2

- source SHA256: `c7b64f2a979b533a360caca9033d9e92d61c88f820ecf495ca80851b8a8b9a63`
- size: `81294` B
- runtime DLL SHA256: `d0fd868b9ae61570da095b66d2fb59d446ef9d6dd238c9cfb74100e636b06cd5`
- restore tool: `tools/RESTORE_PLAYERESP_SOURCE.py`

## Recovery/evidence modules

- PositionalSpoof: `artifacts/PositionalSpoof/`
- SpeedFloor: `artifacts/SpeedFloor/`
- AutoLootPP: `artifacts/AutoLootPP/`
- LongPickPocket: `artifacts/LongPickPocket/`
- V68 MovementCore: `artifacts/V68/`

Read these directories only when the task needs reconstruction, binary lineage, audit or rollback. They are deliberately excluded from the normal AI read path.

## Legacy material

`source/V20_SOURCE_PARTS/` is incomplete historical MovementCore material. `src/history/` contains historical ancestors/evidence. Neither is a default development source.

## Repository rule

For every active module preserve:

1. exact runtime hash,
2. original source when available,
3. explicit reconstruction/binary-patch provenance when original source is unavailable,
4. source hash/size when known,
5. rollback evidence,
6. a canonical pointer in `runtime/current.json` rather than relying on naming conventions.
