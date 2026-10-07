# WoW112 Operator Console V1

Operator Console is a separate Windows x64 observability and operator UI for WoW112 automation. It does **not** implement login, world/AH protocol, BUY logic, Vendor/DE economics, mail/lifecycle mutations, summon logic, movement, or a second whisper parser.

## Run

1. Extract the `WoW112-Operator-Console-V1-<SHA>` CI artifact.
2. Start `WoW112-Operator-Console-V1.exe`.
3. Persistent data is stored under `%LOCALAPPDATA%\WoW112\OperatorConsole`.
4. `--demo` injects synthetic events for UI-only validation. Synthetic mode is never the production backend.

The console is x64 by design. Existing WoW 1.12.1/native modules remain x86. Process architecture is decoupled by the Operator Bridge contract.

## Event source

The neutral V1 bridge directory is `%LOCALAPPDATA%\WoW112\OperatorConsole\bridge`:

- `backend-events.jsonl` — append-only structured events emitted by backend adapters.
- `operator-commands.jsonl` — append-only typed operator commands consumed by backend adapters.

The GUI never creates raw WoW packets. Backend adapters must translate `ReplyToWhisper`/`SendWhisper` through the already-authoritative whisper-send primitive for that backend.

Every event supports timestamp, severity, category, account/profile, character, session ID, module, event type, message, structured metadata, correlation ID, optional operation ID and direction.

## History and logs

`%LOCALAPPDATA%\WoW112\OperatorConsole\history\operator-events.jsonl` is the durable source of truth for console history. Files rotate at a bounded size and old rotations are capped. Clearing the Events view never deletes history.

The history is replayed on console startup into the read-only state projector, so conversations, session state, summon/payment events, errors and mutation outcomes survive a GUI restart.

## Manual whisper

The Whispers tab groups events by player. Enter sends; Shift+Enter inserts a newline in the editor. A manual reply is serialized as a typed `ReplyToWhisper` command targeted at an explicit session/account/profile/character. The console records only `OperatorCommandQueued` until the backend emits the authoritative outgoing `WhisperSent` event; it does not pretend that queuing equals sending.

Manual chat is communication, not an economic mutation. The OperatorCommand enum intentionally exposes no BUY/MAIL/CANCEL/POST operations.

## Backend disconnect diagnosis

Check, in order:

1. Overview → session Connected/World status and Last activity.
2. Events → `Disconnected`, `ReconnectStarted`, `ReconnectSucceeded`, Warning/Error.
3. Debug → current state snapshot and recent warning/error chain.
4. `%LOCALAPPDATA%\WoW112\OperatorConsole\bridge\backend-events.jsonl` for adapter output.
5. The backend-specific logs. Operator Console does not retry an uncertain economic send.

## Debug snapshot

Debug → **Copy debug snapshot** copies a bounded state/error report to the clipboard. Password/token/secret/Authorization/DPAPI-like values are redacted both when events enter the bus and when a snapshot is generated.

## Read-only vs commands

Read-only in V1 UI:

- login/world/reconnect status,
- parser diagnostics,
- summon/payment history,
- AH scans/buy telemetry,
- mail/cancel/post lifecycle telemetry,
- mutation coordinator state.

Command-capable surface:

- `SendWhisper`,
- `ReplyToWhisper`,
- `PauseAutomation`,
- `ResumeAutomation`.

There are deliberately no economic mutation commands. UNCERTAIN coordinator state is projected as a hard-stop status and is never cleared by restarting the GUI.

## Files in the delivery artifact

- `WoW112-Operator-Console-V1.exe`
- `config.example.json`
- `README.md`
- `ARCHITECTURE.md`
- `manifest.json`
- `SHA256SUMS.txt`

.NET Framework 4.8 is used because the existing WoW112 Windows tooling already builds on the Windows 2022 image and uses WinForms. The console itself is compiled AMD64/x64; it has no reason to inherit the game's x86 address space.
