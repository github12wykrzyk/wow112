# SpeedFloor v0.4 source recovery

Target: **World of Warcraft 1.12.1 build 5875, Windows x86**.

## Classification

`FUNCTIONALLY EQUIVALENT RECONSTRUCTION`

This is **not** claimed to be the original source and is not classified as binary-verified source reconstruction.

Final runtime DLL:

- `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll`
- size: `10240` bytes
- SHA256: `39478169ac9e37d82ce45daa4fad997ae059c57c271fb14027aa3c1b302854db`

Recovered source:

- `src/SpeedFloor/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG_RECONSTRUCTED.c`
- size: `14417` bytes
- SHA256: `f1a446d0384f37888675f765327ab019a74ab9a9a9743ed95597b7bb24b4b69f`

## What was recovered from the final DLL

The reconstruction preserves the observed v0.4 runtime semantics and hardcoded WoW 5875 addresses:

- PE32/i386, image base `0x10000000`, no normal import directory.
- Dll entrypoint at RVA `0x1040`.
- Exports:
  - `_SpeedFloor_GetApplyCount@0` RVA `0x1020`
  - `_SpeedFloor_GetMethod@0` RVA `0x1030`
  - `_SpeedFloor_GetStatus@0` RVA `0x1010`
  - `_SpeedFloor_GetVersion@0` RVA `0x1000`
- version return: `0x00040000`.
- method return: `4` = `SAFE_DIRECT_RECALC_ONLY`.
- timer: `SetTimer(NULL, 0, 5, callback)` through WoW IAT slot `0x007FF4F4`.
- timer teardown through `KillTimer` slot `0x007FF4F8`.
- object manager pointer: `0x00B41414`.
- player lookup via current-player GUID at object-manager offsets `+0xC0/+0xC4`, first object `+0xAC`, object GUID `+0x30/+0x34`, next object `+0x3C`.
- PvP state function: `0x00605FF0` (`__thiscall`, player as `ECX`).
- stealth detection by scanning descriptor dwords `+0xBC .. +0x178` for IDs `0x6F8..0x6FB`, `0x2C3F`, `0x2C41`.
- current-speed field: player `+0xA2C`.
- run-speed field: player `+0xA34`.
- floor: IEEE-754 bits `0x40E33333` = about `7.10`.
- apply condition: run speed `> 0.01` and `< 7.10`; there is no PvP gate in v0.4.
- direct write only to run speed, followed by speed recalculation at `0x007C5C20` using `player + 0x9A8` as `ECX` and stack argument `0`.
- detailed `FLOOR_APPLY` logging limited to the first 192 applications.
- periodic `SPEED_HEALTH` log every 2000 ms.
- diagnostic file: `WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.log`.

## Rebuild check

The reconstructed source was compile-checked and linked as x86 with Clang 17 / LLD in MSVC ABI mode, freestanding and without default libraries.

The test rebuild is **not** byte-identical to the preserved final DLL, therefore it is not evidence for `BINARY-VERIFIED SOURCE RECONSTRUCTION`. However:

- the four exported names match,
- their export RVAs match the final DLL (`0x1000/0x1010/0x1020/0x1030`),
- the reconstructed `.data` section is byte-identical to the final DLL, including MSVC `_fltused = 0x9875` and the runtime state layout,
- the hardcoded WoW 5875 addresses and runtime control flow listed above are preserved.

For byte-level evidence and PE metadata see `artifacts/SpeedFloor/BINARY_REVERSE_AUDIT.txt`.
