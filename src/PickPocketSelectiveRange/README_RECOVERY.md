# PickPocketSelectiveRange v10 source recovery

Status: **RECONSTRUCTED + BINARY VERIFIED** for the active V68/V67 runtime DLL.

Reference runtime:

- `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll`
- SHA256: `efea7ea55788abf8bf7b6302c5576590b386d3cb29f78639e596e3984fd6c7ba`

Recovered source:

- `PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD_RECONSTRUCTED.c`
- source SHA256: `1ef439064a2184eae79013780a2e99ac6bbc592c2ab641a45b6a0097fe7b8b8e`

## Verification

The final DLL was restored byte-exact from the repository recovery artifact and disassembled. The v10 source was reconstructed using the final binary plus the verified v8 source lineage.

Rebuild toolchain used for verification:

```text
clang-cl 17.0.0 --target=i686-pc-windows-msvc /c /O2 /GS- /GR- /Zl
lld-link 17.0.0 /dll /machine:x86 /entry:DllMain /subsystem:windows,5.01 /nodefaultlib /dynamicbase /nxcompat:no /safeseh:no /base:0x10000000
```

Results:

- rebuilt `.text` SHA256: `468eac8d53f7662279803167b702b5b7144d03248458de784413863622d7e96f`
- reference `.text` SHA256: `468eac8d53f7662279803167b702b5b7144d03248458de784413863622d7e96f`
- `.text` byte differences: **0 / 1634 bytes**
- when linked under the exact original DLL filename with matching PE flags, the complete 4096-byte DLL differs from the reference in only **3 bytes**, all inside the PE COFF timestamp field; the remaining **4093 bytes are identical**.

Therefore the executable behavior generated from this reconstructed C is verified against the final runtime binary, not merely inferred from names or historical notes.

## Recovered behavior

- shared combat range floor: `9.0f`
- Pick Pocket ID `921 / 0x399`: max range forced to `300.0f`
- Pick Lock ID `1804 / 0x70C`: max range forced to `300.0f`
- 11 direct callsites to resolver `0x006E3480` are wrapped
- unload restores all callsites and the original shared floor `300.0f`
- exported counters/status match the reference DLL
