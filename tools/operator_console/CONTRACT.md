# Summon Service V1 — Operator Console contract

Transport is newline-delimited UTF-8 JSON over a local TCP stream. The service is authoritative; the console is a durable observer plus a narrow operator-command client.

## Event envelope

Every service event contains exactly the common fields required by the handoff: `schema_version`, `event_id`, `ts_utc`, `type`, `session_id`, `request_id`, `customer`, `destination`, `state`, `amount_copper`, `correlation_id`, `severity`, `metadata`.

Supported event types: `ServiceStarted`, `SessionReady`, `WhisperReceived`, `ParserDecision`, `RequestQueued`, `SummonStarted`, `SummonCompleted`, `SummonFailed`, `PaymentExpected`, `PaymentReceived`, `PaymentMissing`, `TradeUncertain`, `Reconnect`, `ServiceStopped`.

The console validates the envelope and stores accepted events unchanged except secret-key redaction inside metadata. Parser fields are displayed, not reinterpreted.

## Replay / reconnect

On every TCP connection the console sends:

```json
{"kind":"hello","schema_version":1,"consumer":"operator-console-service-adapter-v1","resume_after_event_id":"<last durable id>"}
```

The service replies with `hello_ack`, then replays all retained events after that stable `event_id` before switching to live delivery. Replayed overlap is safe because `event_id` is a unique key in the console SQLite store. This is the contract that prevents a temporary IPC outage from becoming a history hole.

If the service cannot find the cursor in its retained replay window, it must replay the whole retained window. Dedupe makes this safe; it is preferable to silent loss.

## Commands

Only three command types exist: `Pause`, `Resume`, `ManualWhisper`.

`ManualWhisper` requires an explicit `session_id`, explicit `customer`, and non-empty single-line `text`. The console does not infer either identity from the currently selected table row.

There are no arbitrary Lua, packet-send, summon, trade, payment, AH, BUY, CANCEL, POST or MAIL commands.

No command is automatically retried after a transport error. If `sendall()` fails, the UI reports the send result as uncertain because the service may have received a prefix or full frame before disconnect.

## Security and bounds

Event and command frames are capped at 1 MiB / 8 KiB respectively. Strings and metadata are bounded. Secret-like metadata keys (`password`, `token`, `secret`, `Authorization`, `DPAPI`, credentials/API keys) are redacted before persistence and debug presentation. HTTP binds to `127.0.0.1` by default.
