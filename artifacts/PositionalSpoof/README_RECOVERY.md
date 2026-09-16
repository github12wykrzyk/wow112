# WoWPositionalSpoof v0.36 final source recovery

Target runtime:
`WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll`

Runtime SHA256:
`deab16a21ab201e8edc4d8a245a739a6b879e57f7c11efe922451ee0eea9823b`

## Status

**BINARY-VERIFIED SOURCE RECONSTRUCTION**

This is not labeled `original_source`. The exact complete source ancestor is:
`WoWPositionalSpoof_v0_36_NoPP_SmartEnergy700_SmoothStealth_GateGCDFix.c`.
The later WotFRetry5 / StealthCDSafe / NoFailHook runtime was produced by surgical binary patches. Those patches were recovered by byte-diffing preserved DLL lineage.

Reconstructed source SHA256:
`bf4e738330d936c1af62db606a21d3e53bedc0b84d5b7864dc655369c127bbe2`

Reconstructed source size:
`53725` bytes

Compressed source archive:
`artifacts/PositionalSpoof/WoWPositionalSpoof_v0_36_FINAL_RECONSTRUCTED.c.xz.b64`

Restore with Python 3:

```python
from pathlib import Path
import base64, lzma, hashlib

p = Path('artifacts/PositionalSpoof/WoWPositionalSpoof_v0_36_FINAL_RECONSTRUCTED.c.xz.b64')
out = Path('WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix_RECONSTRUCTED.c')
data = lzma.decompress(base64.b64decode(p.read_bytes()))
out.write_bytes(data)
assert len(data) == 53725
assert hashlib.sha256(data).hexdigest() == 'bf4e738330d936c1af62db606a21d3e53bedc0b84d5b7864dc655369c127bbe2'
print(out)
```

## Binary lineage proof

Preserved pre-WotF runtime:
`6185a3a2eae62fe99a6a33e7699ba9e4aeb47ed0b6e9497502b639ecb9d0cf46`

Preserved WotFRetry5 runtime:
`767130d6f02ea26664d116fad34c6b1c0ea52b53bbbef821e4e35b93be0c93f5`

WotFRetry5 differs from pre-WotF by only 9 bytes. Final differs from WotFRetry5 by only 21 bytes. `FINAL_BINARY_PATCH_AUDIT.txt` maps every changed byte run to the source-level behavior.

`patch_WotFRetry5_to_final.py` deterministically transforms the preserved WotFRetry5 DLL into a byte-identical final DLL and verifies the final SHA256.

The reconstructed `.c` was compile-checked as i686 MSVC-style C. Compiler/linker differences mean a modern clang-cl rebuild is not expected to be byte-identical to the historical MSVC-produced runtime.