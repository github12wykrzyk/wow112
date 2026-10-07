# WoW112 Summon Operator Console V1

A standalone Windows x64 control and observability UI for the WoW112 **summon service only**. It reuses the existing SummonScout parser/summon engine, AutoSummonAssist, SummonWorker and AutoLoginBridge runtime. It does not implement a second parser, a second summon engine, login/world protocol, AH, BUY, mail, auction lifecycle or movement.

## What V1 does

- discovers active WoW112 summon sessions from existing named mappings;
- shows world/session, whisper, summon and payment state per character;
- displays incoming whispers and the decision returned by the canonical SummonScout parser;
- lets the operator reply manually through the selected live summon session;
- marks a manual reply as sent only after WoW raises `CHAT_MSG_WHISPER_INFORM`;
- tracks summon lifecycle: queued, started, completed and failed;
- mirrors the existing trusted `SummonScoutDB.paymentLog` instead of detecting trade/gold independently;
- preserves summon/payment history locally across GUI restarts;
- imports trusted payment entries already present in SummonScoutDB when the bridge first sees them;
- exposes filtered events, logs and a sanitized debug snapshot.

## Delivery artifact

CI produces `WoW112-Operator-Console-V1-<SHA>`. The artifact contains:

- `WoW112-Operator-Console-V1.exe` — x64 .NET Framework 4.8 WinForms console;
- `runtime-overlay/WoWAutoLoginBridge_5875_v1.dll` — the existing x86 AutoLoginBridge/HOTPROBE rebuilt with the transport-only Operator Bridge include;
- `runtime-overlay/Interface/AddOns/SummonScout/SummonScout_OperatorBridgeHot.lua`;
- `runtime-overlay/Interface/AddOns/SummonScout/SummonScout.toc`;
- `manifest.json` and `SHA256SUMS.txt`;
- this README, architecture notes and config example.

## Installation / runtime overlay

The console EXE can live anywhere. The runtime overlay must be applied to the same WoW112 runtime that already loads the canonical modules:

1. Replace the runtime `WoWAutoLoginBridge_5875_v1.dll` with the artifact copy.
2. Copy the two SummonScout files from `runtime-overlay/Interface/AddOns/SummonScout/` into the matching game addon directory.
3. Start WoW clients normally through the existing loader.
4. Start `WoW112-Operator-Console-V1.exe`.

The bridge creates one mapping per live client: `Local\WoW112_OperatorBridge_<pid>`. The x64 console never opens WoW process memory and never constructs game packets.

## Manual whisper safety

Manual reply path:

`GUI -> typed ReplyToWhisper -> shared map -> existing AutoLoginBridge FrameScript executor -> SummonScout OperatorBridge -> H.ManualChatLock -> existing SendChatMessage(..., "WHISPER", ...)`

There are two acknowledgements:

1. **dispatch accepted** — Lua accepted the typed command;
2. **WhisperSent** — final confirmation only after matching `CHAT_MSG_WHISPER_INFORM`.

If execution/ACK is uncertain, or no final inform appears within 30 seconds, the console records an uncertain send and **does not auto-retry**. This avoids duplicate manual replies.

The native command protocol exposes only whisper dispatch. It has no BUY/CANCEL/POST/MAIL or arbitrary-Lua command.

## Canonical parser diagnostics

`SummonScout_OperatorBridgeHot.lua` calls the official `W112_SUMMONSCOUT_API_V1.whisperInviteDecision` exported by the canonical core. It does not rediscover parser closures and does not maintain a competing keyword/intent parser.

The Whispers/Whisper Debug views preserve the result, destination, reason and summon-request flag returned by that canonical decision path.

## Summon lifecycle

The bridge observes the exported `W112_SUMMONSCOUT_STATE` rather than implementing summon behavior. It records state transitions into bounded SavedVariables telemetry:

- `SummonScoutDB.operatorSummonLog` — persistent operator lifecycle mirror;
- `SummonScoutDB.operatorSummonSeq` — monotonic telemetry identity.

Events projected to the console are:

- `SummonQueued`;
- `SummonStarted`;
- `SummonCompleted`;
- `SummonFailed`.

`PaymentExpected` is a console state derived after a completed summon. It is not a claim that a fixed fee is due; V1 does not invent payment policy.

## Trusted payment history

The payment source of truth remains the existing trusted core ledger:

`SummonScoutDB.paymentLog[{ ts, player, copper }]`

The Operator Bridge mirrors new trusted entries into `SummonScoutDB.operatorPaymentLog` with a stable local ID and, when available, associates the most recent completed summon destination for that player. It never reads current wallet balance as payment and never implements a second trade detector.

The source Unix timestamp is preserved. Therefore a payment received an hour ago remains an event from an hour ago after console restart instead of being re-stamped as a new payment.

On the Windows side, `%LOCALAPPDATA%\WoW112\OperatorConsole\history\operator-events.jsonl` is append-only history with rotation. `%LOCALAPPDATA%\WoW112\OperatorConsole\bridge\summon-telemetry-seen.txt` prevents replayed SavedVariables telemetry from duplicating durable local history.

To check whether a player paid earlier, search the Events view for the player name or inspect `SUMMONS / PAYMENTS`. `PaymentReceived` shows the trusted amount and original event time.

## Data locations

- persistent normalized history: `%LOCALAPPDATA%\WoW112\OperatorConsole\history\operator-events.jsonl`;
- backend event stream: `%LOCALAPPDATA%\WoW112\OperatorConsole\bridge\backend-events.jsonl`;
- typed command outbox: `%LOCALAPPDATA%\WoW112\OperatorConsole\bridge\operator-commands.jsonl`;
- summon/payment replay dedupe: `%LOCALAPPDATA%\WoW112\OperatorConsole\bridge\summon-telemetry-seen.txt`.

History rotates at a bounded size. Clearing a grid in the UI does not delete durable history.

## Tests and evidence

The dedicated Windows CI gates:

- canonical repository invariants;
- summon bridge protocol/safety surface;
- x64 console compile and core tests;
- exact named-mapping whisper roundtrip;
- summon lifecycle/payment telemetry roundtrip including a synthetic payment timestamped one hour in the past;
- durable payment replay dedupe;
- x86 AutoLoginBridge build;
- runtime overlay staging;
- GUI render smoke;
- x64/x86 PE architecture and SHA256 manifest.

The IPC and GUI smokes are synthetic integration tests, **not a claim of a real in-game summon/payment run**. Real gameplay verification must be reported separately when performed against a live WoW 1.12.1 client/server.

## Security

Passwords, tokens, authorization material and DPAPI-like values are sanitized at event ingress/debug output. Credentials are not part of the OperatorEvent or OperatorCommand schemas. Account/profile identity uses existing non-secret runtime identity/fingerprint information.

The console is intentionally x64 while the game/runtime bridge remains x86; the named mapping is the architecture boundary.
