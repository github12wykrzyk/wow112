# StealthCDGuardian v2 source recovery

Status: **RECONSTRUCTED + STATIC/BINARY VERIFIED** for the active V68 runtime DLL.

Reference runtime:

- `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll`
- SHA256: `2bc2f9be3bca94bd0fc77e2c7c0f4fbfa3669cc03787f2cba4214f0acb2e567e`

Recovered source:

- `WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG_RECONSTRUCTED.c`
- source SHA256: `fe74f51c8abffa13418672fd044f65bf1d523bd66f5b813a02762fbd550d01f6`

## Verification level

The exact final DLL was restored from the repository recovery artifact and disassembled. The reconstructed source was then rebuilt with clang-cl/lld-link 17 for i686/Windows without CRT dependencies.

The rebuilt DLL is **not byte-identical as a whole**: compiler layout of the logger/timer callback differs and the rebuilt `.text` is larger. Therefore this file is deliberately not presented as the original authoring source.

The important binary invariants do match the reference:

- PE32 x86, image base `0x10000000`, entrypoint RVA `0x1060`;
- the same six exports with the same RVAs `0x1000..0x1050`;
- hook site `0x006E12C0` and original continuation `0x006E12C6`;
- original six-byte prologue `55 8B EC 8B 45 14`;
- Stealth detection `(spellId & ~3) == 1784`, covering spell IDs `1784..1787`;
- recovery forced to `5000 ms` and category recovery capped to `5000 ms`;
- `50 ms` `SetTimer` watchdog;
- `2000 ms` unsafe-lost logging throttle;
- foreign `E9` hook chaining and safe repair rules;
- identical exported counters/status model;
- the same Win32 IAT slots, log event names, log format, and FrameScript chat notification.

The reconstructed hook itself compiles to the same instruction-level logic as the reference. Absolute addresses of reconstructed globals differ because compiler data layout is different.

## Build used for validation

```text
clang-cl 17 --target=i686-pc-windows-msvc /c /O2 /GS- /GR- /Zl
lld-link 17 /dll /machine:x86 /entry:DllMain /subsystem:windows,5.01 /nodefaultlib /dynamicbase /nxcompat /safeseh:no /base:0x10000000
```

Use the reference DLL as the runtime rollback artifact. Treat this source as the editable reconstruction for future development, with `source_origin = reconstructed_from_binary` recorded in `runtime/current.json`.
