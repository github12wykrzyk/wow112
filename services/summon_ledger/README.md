# Summon Ledger V1

Independent, durable ledger for Summon Service V1 structured events. It does not send game packets, mutate WoW state, read secrets, or depend on `probes/Wow112HeadlessAndroid`, `tools/operator_console`, or `packaging`.

## Guarantees

- SQLite in WAL mode with `synchronous=FULL` and atomic `BEGIN IMMEDIATE` ingestion transactions.
- Idempotent event replay by `event_id`; a reused `event_id` with different content is a hard conflict.
- `request_id` / `correlation_id` linkage is protected. The same correlation cannot silently move to another request, and request identity fields cannot silently change.
- UTC is normalized to fixed-width ISO-8601 `...Z` timestamps.
- Out-of-order events are safe: request projections are rebuilt from event-time order after a batch is committed.
- Schema versioning is explicit through `schema_migrations`; SQL migrations are immutable numbered files.
- No secrets are stored by the ledger, command queue, or export manifest.
- Operator commands are durable **intents only**. This module never sends arbitrary Lua, arbitrary packets, or direct economic mutations.

## Event contract

Every input object must contain:

`schema_version`, `event_id`, `ts_utc`, `type`, `session_id`, `request_id`, `customer`, `destination`, `state`, `amount_copper`, `correlation_id`, `severity`, `metadata`.

Accepted V1 types:

`ServiceStarted`, `SessionReady`, `WhisperReceived`, `ParserDecision`, `RequestQueued`, `SummonStarted`, `SummonCompleted`, `SummonFailed`, `PaymentExpected`, `PaymentReceived`, `PaymentMissing`, `TradeUncertain`, `Reconnect`, `ServiceStopped`.

Request-scoped types require `request_id`. `PaymentExpected` and `PaymentReceived` require `amount_copper > 0`.

## Operator command contract

Exactly the three shared V1 commands are accepted:

- `Pause`
- `Resume`
- `ManualWhisper`

They are stored durably in `operator_commands` as idempotent command intents and must be consumed by a separate Summon Service runtime. Replaying the same `command_id` with the same payload is a no-op duplicate; reusing it with different content is a hard conflict. `ManualWhisper` requires `customer` and `message`. No arbitrary command, packet, Lua, or economic mutation surface exists here.

Examples:

```text
python -m services.summon_ledger --db summon.sqlite3 operator-command Pause --command-id pause-001
python -m services.summon_ledger --db summon.sqlite3 operator-command Resume --command-id resume-001
python -m services.summon_ledger --db summon.sqlite3 operator-command ManualWhisper --command-id mw-001 --customer PlayerName --message "summon ready"
python -m services.summon_ledger --db summon.sqlite3 operator-commands
python -m services.summon_ledger --db summon.sqlite3 operator-consume pause-001
```

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
python -m services.summon_ledger --db summon.sqlite3 cloud-export ./summon-cloud-export
```

For the operator question **"czy X zapłacił godzinę temu?"** use:

```text
python -m services.summon_ledger --db summon.sqlite3 find-player X --since 1h
```

The result includes payment timestamp, amount, `request_id`, `correlation_id`, destination and session.

## Cloud export

`cloud-export` creates a provider-neutral directory that can be uploaded unchanged to S3/R2/GCS/Azure Blob or another object store later. It performs no network access and needs no cloud credentials.

The bundle contains:

- `events.jsonl` — append-only source-of-truth events,
- `requests.jsonl` — rebuildable request projection,
- `operator_commands.jsonl` — durable operator command audit,
- `manifest.json` — export/schema versions, counts, `(ts_utc,event_id)` cursor and SHA-256 for every payload file.

This gives later cloud synchronization a stable checkpoint and integrity contract without changing the local ledger schema or exposing secrets.

## Tests and benchmark

```text
python -m unittest discover -s services/summon_ledger/tests -p "test_*.py" -v
python -m services.summon_ledger.benchmark --records 50000 --max-query-ms 1500
```

Coverage includes restart persistence, duplicate replay, conflicting duplicate `event_id`, out-of-order events, request/correlation identity conflicts, payment from about an hour ago, two payments from one player, unpaid, uncertain, failed summon, revenue windows/session, 50k records and indexed query performance, all three operator commands, command replay/conflict behavior, rejection of arbitrary commands, cloud-export integrity/checksums and CLI smoke coverage.
