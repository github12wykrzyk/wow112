# WoW112 Summon Operator Console — Service Adapter V1

Frontend and durable observability adapter for **headless Summon Service V1**. This implementation intentionally does not attach to open WoW clients and does not reproduce summon/payment business logic.

## Run with mock service

```powershell
cd tools\operator_console
python mock_service.py --port 58751 --interval 1
# second terminal
python service_adapter.py --service-port 58751 --listen-port 8765
# open http://127.0.0.1:8765/
```

Persistent history defaults to `~/.wow112/operator_console/events.sqlite3`. The GUI reconnects to the service automatically and requests replay after its last durable `event_id`.

## Operator surface

Overview shows service status, uptime, sessions, reconnects, queue context, revenue, unpaid and uncertain counts. Whispers and Whisper Debug show the canonical service parser decision. Queue, Summons and Payments are direct event projections. History/Search answers the operational question "did this player pay an hour ago?" from durable history. Debug/Events/Logs is bounded and redacted.

Commands are limited to `Pause`, `Resume`, and `ManualWhisper`. `ManualWhisper` requires explicit `session_id` and `customer`; no selected-row inference exists. Any uncertain transport send is hard-stopped with no automatic retry.

## Real Summon Service acceptance

`acceptance.py` is a passive acceptance probe for the real headless Summon Service V1. It sends only the replay handshake; it does **not** create a summon, whisper a player, trade, accept payment, or issue operator commands.

Run it while the real Summon Service is online and allow one normal customer request to complete:

```powershell
cd tools\operator_console
python acceptance.py --service-port 58751 --timeout 180 --json-out acceptance-result.json
```

To require a specific customer nick:

```powershell
python acceptance.py --service-port 58751 --customer ExactPlayerName --timeout 300 --json-out acceptance-result.json
```

A PASS requires:

- schema-v1 `hello_ack`,
- valid structured events with unique `event_id`,
- one complete request lifecycle: `WhisperReceived -> ParserDecision -> RequestQueued -> SummonStarted`,
- a terminal summon state (`SummonCompleted`, `SummonFailed`, or `TradeUncertain`),
- after `SummonCompleted`, `PaymentExpected` followed by `PaymentReceived`, `PaymentMissing`, or `TradeUncertain`,
- stable `session_id`, `customer`, `destination`, and `correlation_id` for the request,
- successful disconnect/reconnect using `resume_after_event_id` without duplicate replay.

Exit code is `0` only for PASS and `2` for incomplete/failed acceptance. The JSON output is suitable as durable test evidence.

## Tests

```powershell
python ci.py
python ci.py --artifact
```

The suite includes the 50k-event store/performance test, reconnect/replay integration tests, uncertain-send hard-stop regression, HTTP command validation, and the passive real-service acceptance probe exercised against the protocol-faithful mock service. `build_artifact.py --sha <exact-sha>` creates a source/runtime bundle with SHA256 manifest.

## Non-goals

No login/world protocol, parser, invite, ritual, portal, trade, payment logic, headless client, arbitrary Lua, arbitrary packet send or economic mutation is implemented here. Product implementation remains under `tools/operator_console/**`; the runtime task record exists only for repository control-plane enforcement.
