# LongPickPocket v1.0 source recovery

Target runtime is **World of Warcraft 1.12.1 build 5875, Windows x86**.

## Status

Final binary:
`WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll`

SHA256:
`dc4a8d85b850728f39e07a04c49a7f7b60e72b8ec2fdebb94b86dad3a47474d2`

The maintainable C file in `src/LongPickPocket/` is classified as:

**FUNCTIONALLY EQUIVALENT RECONSTRUCTION**

It is not the lost original source. The source was reconstructed from the
final machine code, known WoW 5875 hook layout, preserved runtime logs and
exact binary ancestors.

## Exact binary lineage

The repo/project preserves the exact v0.9 binary:

`WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll`

SHA256:
`764605590462e4161b4c4badb37db990a33a8ae0037e730e03db78233d2c3717`

v0.9 and final v1.0 differ by **only six bytes**. At file offset `0x1497`,
VA `0x10002097`, the v0.9 conditional branch:

`0F 83 CF 01 00 00`

is replaced by six NOP bytes in v1.0. That branch was the `distance <= 4.5 yd`
normal-range fallback. Removing it makes close and far valid Pick Pocket casts
use the same spoof/facing path. The 0.25 yd HARDLOS distance and the 0.1 yd
safety gate are unchanged.

`artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py`
reproduces the user-supplied v1.0 **byte-for-byte** from exact v0.9.

The older v0.8 ancestor is also known exactly. v0.8 -> v0.9 changes only the
spoof distance from 3.00 yd to 0.25 yd plus its diagnostic text (five bytes in
total). See `BINARY_PATCH_AUDIT.txt` for offsets and hashes.

## Source semantics

The reconstruction keeps the build-5875 design observed in the final binary:
ClientServices send interception, movement packet rewrite, Pick Pocket spell
failure restore, loot-response hold, wallet snapshot/confirmation, 120 ms
money retry, held release replay, and synchronous movement restoration.

No Retail/TBC/Wrath API is used. This is a hardcoded WoW 1.12.1 build 5875 x86
module.

## Verification

The reconstructed C was compiled and fully linked locally as an importless
PE32/i386 DLL using clang's i686 MSVC target and `lld-link /nodefaultlib`.
The rebuilt DLL is a semantic build check, not an exact historical binary
rebuild.
