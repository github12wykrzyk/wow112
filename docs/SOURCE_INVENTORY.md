# Active runtime source inventory

Stan repozytorium dla stabilnego baseline **V68** po odzyskaniu i weryfikacji kolejnych oryginalnych source.

## Exact / normal source secured

| Runtime module | Source status | Canonical storage |
| --- | --- | --- |
| `MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll` | NORMAL SOURCE | `src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c` |
| `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll` | EXACT ORIGINAL SOURCE | `source/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.c` |
| `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll` | EXACT ORIGINAL SOURCE | `source/WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c` |
| `WoWPlayerESP_v1_2_range_sweep.dll` | EXACT ORIGINAL SOURCE, LOSSLESS ARCHIVE | `artifacts/WoWPlayerESP_v1_2_range_sweep.c.xz.b64.part000..004` |

### WoWPlayerESP v1.2 verification

Canonical source name:
`WoWPlayerESP_v1_2_range_sweep.c`

Source SHA256:
`c7b64f2a979b533a360caca9033d9e92d61c88f820ecf495ca80851b8a8b9a63`

Source size:
`81294` bytes

Matching runtime DLL SHA256:
`d0fd868b9ae61570da095b66d2fb59d446ef9d6dd238c9cfb74100e636b06cd5`

Restore documentation:
`artifacts/WoWPlayerESP_v1_2_range_sweep.c.xz.b64.README`

Automatic restore + SHA256 verification:
`tools/RESTORE_PLAYERESP_SOURCE.py`

This is the original source recovered from project files and matched to the canonical V67/V68 source hash. It is not reconstructed/decompiled source.

### PickPocketSelectiveRange v10 verification

Original source SHA256:
`80130b9cb988dc9c60345aa764f9465a1d6e515bcfd9ff5e2128bb865d91206a`

Runtime DLL SHA256:
`efea7ea55788abf8bf7b6302c5576590b386d3cb29f78639e596e3984fd6c7ba`

The older reconstructed source under `src/PickPocketSelectiveRange/` remains useful as independent binary-verification evidence, but is no longer the canonical source now that the original file has been recovered.

### StealthCDGuardian v2 verification

Original source SHA256:
`c90f160ee4ae837e70c09b24dad2383c9a73621fa7b40df88639de95544e78f4`

Runtime DLL SHA256:
`2bc2f9be3bca94bd0fc77e2c7c0f4fbfa3669cc03787f2cba4214f0acb2e567e`

## Active modules still without final indexed original source

| Runtime module | Repository state | Best recovery evidence |
| --- | --- | --- |
| `WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | final runtime recovery + older full source lineage |
| `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll` | EXACT SOURCE EXISTENCE CONFIRMED, BYTES NOT YET INDEXED | V67 source manifest contains exact source SHA256; runtime recovery preserved |
| `WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | final runtime + patch audit + older full source |
| `WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll` | SOURCE INCOMPLETE / BINARY-PATCHED LINEAGE | final runtime + v0.8 rollback + older full source |

## Confirmed historical source lead: PickPocketSelectiveRange

Verified ancestor source from V39/V43 is retained as:

`src/history/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v8_10YD.c`

- size: `8658` B
- SHA256: `2d9e182f1a203f9a8b6247684edbe074f35dedf61f9795db40cfbbf1a50df0f4`

Patch notes:
`src/history/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v8_10YD_BINARY_PATCH_NOTES.txt`

## Recovery priority

1. `WoWNonPvPSpeedFloor v0.4` — exact source is confirmed by manifest; recover original bytes.
2. `WoWPositionalSpoof` — recover final StealthCDSafe/NoFailHook source lineage.
3. `WoWAutoLootPP` and `WoWLongPickPocket` — recover current source lineage from final binaries plus earlier sources and patch notes.

## Repository rule

For every active module:

1. preserve the exact runtime DLL or lossless recovery artifact,
2. preserve original source when available,
3. store source SHA256 and runtime SHA256,
4. explicitly distinguish ORIGINAL SOURCE from RECONSTRUCTED SOURCE,
5. retain older stable versions for rollback and comparison,
6. update `runtime/current.json` whenever source status changes.
