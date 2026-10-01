# AH native receive hook audit — WoW 1.12.1 build 5875

## Scope

Target: WoW 1.12.1 build 5875, Windows x86. This audit identifies a passive receive observation point for Auction House list results. It does not claim gameplay success until the feature candidate is tested.

## Exact-build evidence

The inspected project handoff EXE SHA256 is:

`0d199a689fd38f460203bff85d4357c4b7ba409ab4de061f4e6efc69d23d4450`

Exact disassembly establishes:

- `0x00537A60`: NetClient handler registration. It writes handler to `this + 0x74 + opcode*4` and context to `this + 0xD64 + opcode*4`, then returns with `ret 0x0C`.
- `0x00537AA0`: main-thread opcode dispatcher. It reads the u16 opcode from the inbound CDataStore, obtains handler/context from those tables, calls the handler with context in ECX, opcode in EDX, and two stack arguments, then consumes the handler's `ret 8`.
- `0x005AB490`: exact bytes `A1 28 81 C2 00 C3`; returns the NetClient pointer stored at `0x00C28128`.
- Auction registration around `0x004CC114`: `push 0; mov edx,0x004CC7F0; mov ecx,0x025C; call 0x005AB650`. Therefore opcode `0x025C` is mapped to handler `0x004CC7F0` with null context.
- `0x004CC7F0`: Auction House list-result parser. It reads the first body u32 as result count, parses auction rows, reads the trailing total-auction count, and returns with `ret 8`.
- Inbound CDataStore getters use data pointer `+0x04`, window start `+0x08`, window size `+0x0C`, size `+0x10`, cursor `+0x14`.

The candidate validates exact code signatures for the NetClient getter, auction registration mapping and auction result handler before it writes a handler-table entry.

## External cross-check

Public reverse-engineering notes in `samwhosung/wow-1121-client-internals/docs/net.md` independently describe the same build-5875 receive architecture: main-thread receive pump, NetClient dispatcher `0x00537AA0`, handler tables `+0x74/+0xD64`, and CDataStore receive layout.

This public material is corroborating evidence only; the active addresses above are accepted because they were independently checked against the target EXE.

## Response correlation limitation

`SMSG_AUCTION_LIST_RESULT (0x025C)` contains auction count, auction entries and total auction count. It does **not** carry the request's `listfrom` / page identifier.

Therefore this receive hook can answer the immediate question:

- did the native auction-result handler run once per sent query?

It cannot, by itself, identify which requested page was missing if native responses are genuinely absent.

## V7 probe behavior

`WoWAHThrottleNative_5875_v7_RXPROBE.dll`:

- leaves the original handler/context intact conceptually and chains to the exact original handler;
- replaces only handler-table slot `0x025C`, only when the current handler is exactly `0x004CC7F0` and context is zero;
- counts native handler invocations during each 75/125 ms stage;
- sanity-checks the inbound first-body count as `<= 50`;
- never edits, suppresses or consumes an inbound packet;
- restores the handler slot only if it still owns that slot;
- aborts the benchmark instead of guessing if the slot is unexpected.

The test compares native `0x025C` calls against Lua `AUCTION_ITEM_LIST_UPDATE` counts. If native yield is 500/500 while Lua is lower, the prior apparent misses are event-observer misses rather than missing Auction House responses.
