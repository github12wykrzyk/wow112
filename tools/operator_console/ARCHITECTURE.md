# WoW112 Summon Operator Console V1 architecture

## Scope and ownership

This application is the operator surface for the **summon service only**. Business/runtime ownership remains where it already exists:

`canonical SummonScout / SummonWorker / AutoSummonAssist / AutoLoginBridge -> thin telemetry/transport adapters -> OperatorEvent -> durable history/state/UI`

and for the only live operator command:

`UI -> typed whisper command -> existing native transport -> canonical WoW chat primitive`

The console does not own or reproduce login/world protocol, the SummonScout parser, summon targeting/casting, trade/payment detection, movement, AH, BUY, mailbox or auction lifecycle logic.

## Process architecture

WoW 1.12.1 build 5875 and the native companions remain PE32/x86. The console is a separate PE32+/x64 .NET Framework 4.8 WinForms process.

Cross-architecture communication uses named shared mappings already aligned with the WoW112 runtime model:

- `Local\WoW112_AutoLoginProfile_<pid>` — non-secret profile/relogin state;
- `Local\WoW112_SummonWorker_<pid>` — summon worker state;
- `Local\WoW112_SummonAssist_<pid>` — native summon-assist state;
- `Local\WoW112_OperatorBridge_<pid>` — summon-console transport/event ring.

The console discovers clients map-first. It does not depend on the executable being named `Wow.exe`, does not open process memory and does not decode game packets.

## Normalized event model

`OperatorEvent` is the single durable envelope. It carries:

- timestamp UTC;
- severity;
- category/event type/module;
- account/profile/character/session identity;
- message;
- correlation ID;
- direction;
- structured metadata.

The UI is a projection of events, not an alternate source of truth. `JsonlOperatorStore` persists normalized history and replays it at startup. Event history is rotated and bounded on disk; UI lists are separately bounded in memory/render size.

## Canonical whisper/parser path

Incoming whisper flow:

1. SummonScout receives `CHAT_MSG_WHISPER` through its normal event path.
2. `SummonScout_OperatorBridgeHot.lua` observes the same event.
3. The adapter calls the officially exported `W112_SUMMONSCOUT_API_V1.whisperInviteDecision`.
4. The result is copied into an Operator Bridge event slot.
5. The existing AutoLoginBridge/HOTPROBE drains Lua event globals through verified build-5875 `FrameScript_Execute` / `FrameScript_GetText` primitives.
6. `RuntimeAdapters.cs` projects the ring slot to `WhisperReceived` plus parser diagnostics.

There is no debug-upvalue parser discovery and no second keyword/intent parser in the console path.

## Manual whisper command path

Manual reply flow is deliberately narrow:

`WinForms -> ReplyToWhisper -> operator-commands.jsonl -> RuntimeAdapters -> shared-map command -> AutoLoginBridge/HOTPROBE -> W112_OPERATOR_BRIDGE_RECEIVE -> H.ManualChatLock -> SendChatMessage(..., "WHISPER", ...)`

The native V1 command protocol exposes one opcode only: whisper.

Dispatch confirmation and send confirmation are different states:

- Lua command ACK means the typed command was accepted for dispatch;
- `WhisperSent` is emitted only after a matching `CHAT_MSG_WHISPER_INFORM` arrives from WoW.

If native execution fails, Lua ACK is missing/mismatched, or no final inform is observed within 30 seconds, the event is uncertain and there is no automatic retry. This avoids duplicate manual chat.

## Operator Bridge V1 wire layout

The existing AutoLoginBridge is rebuilt with `WoWAutoLoginBridge_5875_OPERATORBRIDGE.inc`; there is no additional injected DLL name.

Shared mapping constants:

- magic `0x4F323157`;
- version `1`;
- header `556` bytes;
- event slot `896` bytes;
- ring count `16`;
- command opcode `1` = whisper.

Slots use commit-last sequence publication. Overflow is observable through drop counters. The same stable slot layout carries whisper and summon/payment telemetry kinds, so lifecycle expansion did not require an ABI change.

## Canonical summon lifecycle observation

The canonical core exports `W112_SUMMONSCOUT_STATE`. The bridge observes, but never mutates, authoritative fields including:

- `summonPending`;
- `summonActiveName`;
- `summonActiveStarted`;
- `summonActiveRequestSeq`;
- `lastSummonError`.

From state transitions it records a bounded durable operator mirror in SavedVariables:

- `SummonScoutDB.operatorSummonLog`;
- `SummonScoutDB.operatorSummonSeq`.

The event kinds are:

- `4` -> `SummonQueued`;
- `5` -> `SummonStarted`;
- `6` -> `SummonCompleted`;
- `7` -> `SummonFailed`.

This is observability, not a second summon engine. The canonical core remains responsible for queueing, native request sequencing, Ritual start/stop/failure handling, watchdogs and completion.

## Trusted payment observation

The payment source of truth is the existing canonical trusted ledger:

`SummonScoutDB.paymentLog[{ ts, player, copper }]`

The operator adapter does not inspect wallet delta and does not implement trade acceptance or payment inference. It mirrors newly observed trusted rows into:

- `SummonScoutDB.operatorPaymentLog`;
- `SummonScoutDB.operatorPaymentSeq`.

Each mirror row receives a stable telemetry ID. When possible, the adapter associates the most recent completed summon destination for the same player. Event kind `8` becomes `PaymentReceived` in the Windows console.

The original payment Unix timestamp is carried over the ring and restored by `SummonLifecycleAdapter.cs`, so replaying an older trusted payment preserves the real historical time instead of creating a false new payment.

After `SummonCompleted`, the Windows state projector emits `PaymentExpected` as an operational state. V1 deliberately does not invent a fee or unpaid timeout policy.

## Durable replay and dedupe

Summon/payment operator mirrors survive addon reload/logout through `SummonScoutDB`. This lets a newly started console import already-known trusted history.

The Windows adapter stores emitted correlation keys in:

`%LOCALAPPDATA%\WoW112\OperatorConsole\bridge\summon-telemetry-seen.txt`

This prevents replayed SavedVariables entries from duplicating local normalized JSONL history across GUI/runtime restarts.

The normalized history itself is:

`%LOCALAPPDATA%\WoW112\OperatorConsole\history\operator-events.jsonl`

## C# runtime split

`RuntimeAdapters.cs` owns:

- map-first session discovery;
- existing AutoLogin/SummonWorker/SummonAssist telemetry;
- whisper ring projection;
- typed manual-whisper dispatch;
- native/Lua ACK and final outgoing confirmation state.

`SummonLifecycleAdapter.cs` is intentionally read-only and owns:

- event kinds 4..9;
- summon lifecycle projection;
- trusted payment projection;
- historical source timestamps;
- persistent replay dedupe;
- final manual-whisper timeout telemetry (`WhisperSendUncertain`).

CI asserts the lifecycle adapter contains only `FILE_MAP_READ` access and no shared-map write primitives.

## State/UI

The summon-only session projector tracks:

- World;
- Whispers;
- Summon;
- Payment;
- summon queue depth;
- current task / last event / last error.

Primary UI surfaces are:

- Overview;
- Whispers;
- Whisper Debug;
- Summons / Payments;
- Events;
- Debug;
- Logs.

There is intentionally no AH/mail/mutation tab or command surface.

## Security

The event bus and debug snapshot redact password/token/secret/Authorization/DPAPI-like material. Credentials are absent from OperatorEvent and OperatorCommand schemas.

Manual player/text fields are bounded. Native code hex-encodes them before constructing the fixed Lua invocation. Arbitrary Lua cannot be supplied by the GUI. Literal WoW chat escape introducer `|` is rejected by the Lua bridge.

## Verification model

The dedicated Windows CI checks:

- canonical repository invariants;
- protocol constants and absence of economic opcodes;
- official canonical parser/state use and absence of debug-upvalue discovery;
- x64 compilation/core tests;
- synthetic named-mapping whisper roundtrip;
- synthetic summon lifecycle/payment roundtrip;
- preservation of a historical payment timestamp;
- payment replay dedupe;
- x86 AutoLoginBridge build;
- runtime overlay staging;
- GUI render smoke;
- PE architecture and SHA256 manifest.

Synthetic IPC tests prove the cross-process contract and projection logic; they do not constitute a real in-game summon/payment test. Live-game evidence is tracked separately and must not be inferred from CI success.
