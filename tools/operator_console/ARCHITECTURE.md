# Operator Console V1 architecture

## Boundary

Operator Console is a presentation/observability process. The trust boundary is explicit:

`existing WoW backend primitive -> backend adapter -> OperatorEvent -> OperatorEventBus -> state/history/UI`

and, for operator commands:

`UI -> typed OperatorCommand -> transport adapter -> existing authoritative primitive`

The GUI does not know login opcodes, world packet formats, AH packet formats, BUY selection rules, Vendor/DE economics, mailbox mutation semantics, auction mutation semantics, summon execution semantics or movement addresses.

## Core telemetry

`OperatorEvent` is the single normalized envelope. Identity is multi-client from day one: account, profile, character and session ID are independent fields. Correlation ID joins a player/operator flow. Operation ID joins an economic lifecycle that remains owned by its backend/coordinator.

Severity: TRACE, DEBUG, INFO, WARN, ERROR.

Direction differentiates incoming, outgoing automation, outgoing manual and system events.

Structured parser diagnostics are data attached to an event. The state projector never re-runs or changes the parser decision.

## State store

`OperatorStateStore` is a read-only projector. UI panels query snapshots rather than parsing arbitrary log strings. Coordinator `Uncertain` is sticky: ordinary release/error events do not silently downgrade it. A backend must emit an authoritative reconciled/new state if this policy evolves.

## Persistence

`JsonlOperatorStore` is the V1 durable event source. It is append-only, bounded by rotation, and replayed at startup. This keeps recovery transparent and avoids coupling unrelated operator history to the AH market/history database.

The event stream is independently machine-readable and can be migrated to SQLite later without changing the event/state/command contracts.

## Runtime observation

The x64 process reuses existing x86 named mappings instead of opening WoW memory or decoding game packets:

- `Local\\WoW112_AutoLoginProfile_<pid>`
- `Local\\WoW112_SummonWorker_<pid>`
- `Local\\WoW112_SummonAssist_<pid>`
- `Local\\WoW112_OperatorBridge_<pid>`

Session IDs are PID-bound (`wow-pid-<pid>`). Account/profile identity is represented by the existing non-secret AutoLogin profile fingerprint; credentials never cross into Operator Console.

## Live whisper path

Incoming/outgoing whisper integration deliberately reuses the canonical owners:

1. `SummonScout_OperatorBridgeHot.lua` is loaded by SummonScout after the existing whisper-confirm/manual-chat module.
2. `CHAT_MSG_WHISPER` is observed, then the existing core `whisperInviteDecision` function is called through the same upvalue-discovery pattern already used by canonical unknown-whisper telemetry. The Operator Bridge records that result; it does not implement a second parser.
3. Lua exposes a bounded event queue. The already loaded `WoWAutoLoginBridge_5875_v1_HOTPROBE.c` drains it through the verified build-5875 `FrameScript_Execute` / `FrameScript_GetText` primitives.
4. Native code publishes the events to the per-PID `WoW112_OperatorBridge` shared mapping. A 16-slot commit-last ring prevents partial slots from being treated as complete events; explicit drop counters expose overflow.
5. `OperatorRuntimeBridge.cs` converts ring entries into normal `OperatorEvent` JSONL records consumed by the GUI.

There is no new login/world/chat packet implementation and no new injected DLL name. The existing AutoLoginBridge companion is rebuilt with a transport-only include.

## Manual whisper path and ACK semantics

Manual reply is deliberately multi-stage:

`GUI -> operator-commands.jsonl -> OperatorRuntimeBridge.cs -> shared map command -> existing AutoLoginBridge/HOTPROBE -> W112_OPERATOR_BRIDGE_RECEIVE -> H.ManualChatLock -> SendChatMessage(..., "WHISPER", ...)`

The native command surface has one opcode only: manual whisper.

A Lua return/ACK means only **dispatch accepted**. It does not produce `WhisperSent`. Final `WhisperSent` is emitted only after WoW raises `CHAT_MSG_WHISPER_INFORM` for the matching player/text/correlation flow.

If native execution fails, the Lua ACK is missing/mismatched, or the command times out, the result becomes **UNCERTAIN** and no automatic retry is attempted. An accepted dispatch without `CHAT_MSG_WHISPER_INFORM` becomes `WhisperSendUnconfirmed`, not a false success.

## Command safety

The general Operator Core enum includes non-economic controls, but the native WoW bridge intentionally exposes only whisper dispatch. BUY/MAIL/CANCEL/POST are impossible to encode in `WoW112_OperatorBridge` V1.

Any future economic operator action must use the shared mutation coordinator and receive a separate safety design review. Raw GUI/native mutation opcodes are forbidden.

## Threading and performance

Bridge polling, backend JSONL ingestion and persistence stay outside the WinForms render path. `OperatorEventBus` accepts events from producer threads; UI updates are marshalled with `BeginInvoke`. Large history is capped in-memory at 50k events and event tables render a bounded tail.

The whisper native bridge polls at 100 ms and drains up to eight queued Lua events per tick. It does not hook chat functions or run a second parser.

## Security

Sanitization is applied at event ingress and debug-snapshot generation. Keys/text resembling passwords, tokens, secrets, Authorization or DPAPI material are redacted. No credential field exists in the event or command schemas.

Manual whisper input is length-bounded and hex-encoded before native code constructs the Lua invocation. Literal `|` is rejected because WoW chat treats it as an escape introducer. The bridge never accepts arbitrary Lua from Operator Console.

## Build architecture

- WoW runtime and AutoLoginBridge remain PE32/x86.
- Operator Console is a separate PE32+/x64 .NET Framework 4.8 WinForms process.
- CI builds and hashes both artifacts on the same exact feature SHA.
- The delivery artifact contains the x64 console plus `runtime-overlay/` with the rebuilt x86 AutoLoginBridge and exact SummonScout bridge/TOC files.
- `operator_bridge_build.json` records native and Lua source hashes and safety properties.
