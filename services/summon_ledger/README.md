# Summon Ledger V1

Independent, durable ledger for Summon Service V1 structured events. It does not send game packets, mutate WoW state, read secrets, or depend on `probes/Wow112HeadlessAndroid`, `tools/operator_console`, or `packaging`.

## Guarantees

- SQLite in WAL mode with `synchronous=FULL` and atomic `BEGIN IMMEDIATE` ingestion transactions.
- Idempotent event replay by `event_id`; a reused `event_id` with different content is a hard conflict.
- `request_id` / `correlation_id` linkage is protected. The same correlation cannot silently move to another request, and request identity fields cannot silently change.
- UTC is normalized to fixed-width ISO-8601 `...Z` timestamps.
- Out-of-order events are safe: request projections are rebuilt from event-time order after a batch is committed.
- Schema versioning is explicit through `schema_migrations`; SQL migrations are immutable numbered files.
- No secrets are stored by the schema.

## Event contract

Every input object must contain:

`schema_version`, `event_id`, `ts_utc`, `type`, `session_id`, `request_id`, `customer`, `destination`, `state`, `amount_copper`, `correlation_id`, `severity`, `metadata`.

Accepted V1 types:

`ServiceStarted`, `SessionReady`, `WhisperReceived`, `ParserDecision`, `RequestQueued`, `SummonStarted`, `SummonCompleted`, `SummonFailed`, `PaymentExpected`, `PaymentReceived`, `PaymentMissing`, `TradeUncertain`, `Reconnect`, `ServiceStopped`.

Request-scoped types require `request_id`. `PaymentExpected` and `PaymentReceived` require `amount_copper > 0`.

## CLI

Run from repository root:

```text
python -m services.summon_ledger --db summon.sqlite3 ingest events.jsonl
python -m services.summon_ledger --db summon.sqlite3 find-player PlayerName
python -m services.summon_ledger --db summon.sqlite3 find-player PlayerName --since 1h
python -m services.summon_ledger --db summon.sqlite3 request req-123
python -m services.summon_ledger --db summon.sqlite3 payments --since 1h
python -m services.summon_ledger --db summon.sqlite3 payments --since 1h --player PlayerName
python -m services.summon_ledger --db summon.sqlite3 revenue --today
python -m services.summon_ledger --db summon.sqlite3 revenue --since 1h
python -m services.summon_ledger --db summon.sqlite3 revenue --session session-123
python -m services.summon_ledger --db summon.sqlite3 unpaid
python -m services.summon_ledger --db summon.sqlite3 uncertain
python -m services.summon_ledger --db summon.sqlite3 stats
```

For the operator question **"czy X zapłacił godzinę temu?"** use:

```text
python -m services.summon_ledger --db summon.sqlite3 find-player X --since 1h
```

The result includes payment timestamp, amount, `request_id`, `correlation_id`, destination and session.

## Tests and benchmark

```text
python -m unittest discover -s services/summon_ledger/tests -p "test_*.py" -v
python -m services.summon_ledger.benchmark --records 50000 --max-query-ms 1500
```

Coverage includes restart persistence, duplicate replay, conflicting duplicate `event_id`, out-of-order events, request/correlation identity conflicts, payment from about an hour ago, two payments from one player, unpaid, uncertain, failed summon, revenue windows/session, 50k records and indexed query performance.

## Cloud export path

The append-only `events` table is the portable source of truth. A future exporter can stream by `(ingested_at_utc, event_id)` or SQLite backup without changing the on-disk event contract. The `requests` table is a rebuildable local projection, not an external source of truth.
