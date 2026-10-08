# Summon Service V1 — core architecture

## Authority and reuse

- Development base: exact `parallel` SHA `a5ee048c620c55542460d54d7750e81f0f8f8da4`.
- Live-tested authority: `d753829314db39e5cd9aad57ce1d46daaf4d55da`.
- Minimal stored-source provenance for TELE08/10 primitives: `b5c793d0a55915a9cfd3b08395ee16f7000e6352`.
- No whole-branch merge. Parser, queue and TELE10 payment code are reused as proven primitives.

## Service state machine

Service: `Starting -> Ready <-> Paused -> Draining -> Stopped`, with terminal safety state `BlockedUncertain`.

Request: `Queued -> Inviting -> RitualCommitted -> PortalCommitted -> AwaitingPayment -> Completed`.

Failure exits: active request may become `Failed` on a confirmed terminal failure or `BlockedUncertain` if the result of a mutation is not provable.

## Restart rules

- Queued requests are reconstructed from the durable snapshot.
- A request that had already reached `AwaitingPayment` is restored directly into payment-wait state. The summon is never replayed.
- A restart while `Inviting`, `RitualCommitted` or `PortalCommitted` blocks that request for reconciliation; no mutation is automatically replayed.
- TELE10's own persistent trade ledger remains authoritative for ACCEPT/settlement idempotency and unresolved trade mutations.

## Mutation safety

`SummonServiceCore` never performs packet mutation itself. Live adapters must commit the matching request phase before using the proven packet primitive and report any uncertain socket result back as `mark_uncertain`. The service then moves to `BlockedUncertain`, emits `TradeUncertain` with `retry_allowed=false`, and refuses to start another request.

The TELE10 payment primitive preserves its existing invariant: ACCEPT is committed in the ledger before socket I/O, an uncertain write is never retried automatically, and gold is booked only after server `TRADE_COMPLETE`.

## Structured events

Every event contains `schema_version`, `event_id`, `ts_utc`, `type`, `session_id`, `request_id`, `customer`, `destination`, `state`, `amount_copper`, `correlation_id`, `severity`, and `metadata`.

The core emits the required V1 event names: `ServiceStarted`, `SessionReady`, `WhisperReceived`, `ParserDecision`, `RequestQueued`, `SummonStarted`, `SummonCompleted`, `SummonFailed`, `PaymentExpected`, `PaymentReceived`, `PaymentMissing`, `TradeUncertain`, `Reconnect`, and `ServiceStopped`.

## Bounded memory

The in-memory event ring is capped (default 2048 events). Durable request history is capped (default 10,000 records); only terminal records are eligible for pruning. The canonical queue is rebuilt from the bounded durable request set after terminal completion, preventing the queue engine's historical request map from growing without bound during 24/7 operation.

## Operator commands

Core commands: `Pause`, `Resume`, `ManualWhisper`, plus internal `GracefulShutdown`. Pause prevents new activation without aborting an active request. Graceful shutdown drains the active request, then emits `ServiceStopped`.
