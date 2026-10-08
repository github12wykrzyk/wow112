# Operator Console Service Adapter V1 architecture

## Ownership boundary

This branch deliberately moves the Operator Console away from open WoW clients. The topology is:

`Headless Summon Service V1 -> structured NDJSON event stream -> ServiceConnector -> SQLite event store -> HTTP projection -> browser UI`

and the only reverse path is:

`UI -> validated Pause | Resume | ManualWhisper -> ServiceConnector -> Headless Summon Service V1`

The console never logs in, parses whispers, invites, casts Ritual of Summoning, clicks portals, accepts trades, decides payment, or opens game-client memory. Those remain core service responsibilities.

## Durable history and dedupe

SQLite is the local durability boundary. `event_id` is unique. The last durably committed `event_id` is used as the reconnect cursor. The service replays after that cursor; duplicates are ignored transactionally.

The browser can disconnect/reload without affecting ingestion. A service IPC drop triggers connector reconnect without restarting the web UI. The store remains queryable while the service is down.

## UI projection

The UI renders eight operator surfaces: Overview, Whispers, Whisper Debug, Queue, Summons, Payments, History/Search, Debug/Events/Logs. Recent grids are bounded to 250 rows per snapshot. Full retained history is queried on demand by exact customer nick.

`UNCERTAIN` is a first-class red banner and KPI. Parser debug exposes raw/normalized/result/reason/metadata exactly from the event payload. There is no second parser in JavaScript or Python.

## Testing strategy

`mock_service.py` implements the service side of the contract, including cursor replay and command acknowledgements. Tests cover schema validation, forbidden commands, ManualWhisper identity requirements, redaction, persistent dedupe, reconnect replay, API behavior, and a 50k-event persistence/query performance gate.

The mock is not evidence of a real in-game summon or payment. Live-game evidence belongs to the headless Summon Service project after integration.
