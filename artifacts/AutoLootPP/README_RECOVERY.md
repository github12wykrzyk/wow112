# AutoLootPP v0.14 source recovery

Target: **World of Warcraft 1.12.1 build 5875, Windows x86**.

## Status

**FUNCTIONALLY EQUIVALENT RECONSTRUCTION**

The normal C source in this recovery set is reconstructed from the final v0.14 PE32/x86 machine code and the preserved v0.13 binary lineage. It is **not** claimed to be the original source file.

Final runtime DLL:

- `WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll`
- size: `20992` bytes
- SHA256: `05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845`

Reconstructed source:

- `src/AutoLootPP/WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK_RECONSTRUCTED.c`
- source SHA256 and size are recorded in `runtime/current.json`.

## Exact ONESHOT -> NOSKIP lineage

The repository already preserves the exact v0.13 DLL as XZ+Base64 parts under `artifacts/V67/runtime/`.

v0.13 SHA256:

`641b64187e387fabfea41426962734ff3c1e5d0c2bbc4652e7df823d51e20a73`

v0.13 and v0.14 have the same size and differ at only **three bytes**:

- file offset `0x00000F07`
- RVA `0x00001B07`
- VA `0x10001B07`
- v0.13: `0F 93 C4` = `setae ah`
- v0.14: `30 E4 90` = `xor ah,ah ; nop`

That branch used the global at `0x1000EAE4`, which is the Pick Pocket send-attempt counter. In source terms:

```c
/* v0.13 ONESHOT */
skip = (tracked_guid_hi == 0) || (pp_send_count >= 1);

/* v0.14 NOSKIP */
skip = (tracked_guid_hi == 0);
```

No other byte changed between the preserved v0.13 and supplied v0.14 DLLs.

## Exact binary reproducer

`artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py`

It validates the exact v0.13 input hash, applies the single 3-byte patch, and validates the exact v0.14 output hash. Recovery testing produced a byte-for-byte identical v0.14 DLL.

## Reconstructed C coverage

The source records the recovered WoW 5875 absolute addresses, importless PEB export resolution, loot-error hook, object traversal, 300 yd candidate scan, Humanoid/Undead filter, attackable gate, `LEVELGATE3`, compressed-GUID PP packet construction, retry tracking and the final `NOSKIP` branch.

The full-drain loot controller is represented as normal maintainable C from the recovered state machine and timing constants. Compiler layout is intentionally not presented as original-source evidence.

## Build check

Recovery compile/link check used an x86 Windows target and no CRT/default libraries:

```text
clang -target i686-pc-windows-msvc -fms-extensions -fno-builtin -c <source.c>
lld-link /dll /entry:DllMain@12 /machine:x86 /nodefaultlib <source.obj>
```

The linked check artifact is PE32/i386. It is only a source sanity check; the historical runtime DLL remains the canonical binary.

## Files

- reconstructed source: `src/AutoLootPP/..._RECONSTRUCTED.c`
- binary audit: `artifacts/AutoLootPP/BINARY_PATCH_AUDIT.txt`
- exact patcher: `artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py`
- this document: `artifacts/AutoLootPP/README_RECOVERY.md`
