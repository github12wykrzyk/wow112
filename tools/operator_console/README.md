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

## Tests

```powershell
python ci.py
python ci.py --artifact
```

The test suite includes a 50k-event store/performance test and reconnect/replay integration test. `build_artifact.py --sha <exact-sha>` creates a source/runtime bundle with SHA256 manifest.

## Non-goals

No login/world protocol, parser, invite, ritual, portal, trade, payment logic, headless client, arbitrary Lua, arbitrary packet send or economic mutation is implemented here. No files outside `tools/operator_console/**` are required.
