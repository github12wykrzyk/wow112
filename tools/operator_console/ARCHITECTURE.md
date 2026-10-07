# Operator Console V1 architecture

## Boundary

Operator Console is a presentation/observability process. The trust boundary is explicit:

`existing WoW backend primitive -> backend adapter -> OperatorEvent -> OperatorEventBus -> state/history/UI`

and, for the small operator command surface:

`UI -> OperatorCommand -> bridge -> backend adapter -> existing authoritative primitive`

The GUI does not know login opcodes, world packet formats, AH packet formats, BUY selection rules, Vendor/DE economics, mailbox mutation semantics, auction mutation semantics, summon execution semantics or movement addresses.

## Core telemetry

`OperatorEvent` is the single normalized envelope. Identity is multi-client from day one: account, profile, character and session ID are independent fields. Correlation ID joins a user/player flow. Operation ID joins an economic lifecycle that remains owned by its backend/coordinator.

Severity: TRACE, DEBUG, INFO, WARN, ERROR.

Direction differentiates incoming, outgoing automation, outgoing manual and system events.

Structured parser diagnostics are data attached to an event. The state projector never re-runs or changes the parser decision.

## State store

`OperatorStateStore` is a read-only projector. UI panels query snapshots rather than parsing arbitrary log strings. Coordinator `Uncertain` is sticky: ordinary release/error events do not silently downgrade it. A backend must emit an authoritative reconciled/new state if this policy evolves.

## Persistence

`JsonlOperatorStore` is the V1 durable event source. It is append-only, bounded by rotation, and replayed at startup. This keeps recovery transparent and avoids coupling unrelated operator history to the AH market/history database.

The event stream is independently machine-readable and can be migrated to SQLite later without changing the event/state/command contracts.

## Transport

V1 defines an intentionally small file bridge because the authoritative components are currently split between x86 injected/native tooling, addons and standalone terminal processes. A backend adapter appends structured events to `backend-events.jsonl` and consumes typed commands from `operator-commands.jsonl`.

This bridge is not a protocol implementation. It transports domain events and operator intent only.

A future named-pipe transport can replace the file transport behind the same interfaces when all producer lifecycles support it.

## Command safety

The only backend command enum values are:

- SendWhisper
- ReplyToWhisper
- PauseAutomation
- ResumeAutomation

BUY/MAIL/CANCEL/POST are intentionally impossible to express in this interface. Any future economic operator action must use the shared mutation coordinator and receive a separate safety design review; it must not be added as a raw GUI primitive.

## Threading

Backend file notifications and persistence are outside the WinForms render path. `OperatorEventBus` accepts events from producer threads; UI updates are marshalled with `BeginInvoke`. Large history is capped in-memory at 50k events and event tables render a bounded tail.

## Security

Sanitization is applied at event ingress and debug-snapshot generation. Keys/text resembling passwords, tokens, secrets, Authorization or DPAPI material are redacted. No credential field exists in the event or command schemas.

## Integration targets discovered in canonical

- Windows native runtime is x86/build 5875.
- Existing GUI stack includes WinForms/C# updater and PowerShell WinForms utilities.
- Headless AH/world terminal is Rust under `probes/Wow112HeadlessAndroid`.
- Summon/native status already uses a local shared-memory coordinator (`Local\\WoW112_SummonAssist_<pid>`).
- SummonScout owns addon-side whisper/parser/summon/payment behavior.

Operator Console therefore remains a separate x64 process and adds adapters around those owners rather than moving their logic into the GUI.
