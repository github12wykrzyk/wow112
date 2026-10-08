# Final Acceptance Status

This feature is repository-complete when the operator-console suite passes and the passive real-service probe can observe one complete live Summon Service request.

## Repository acceptance

Run:

```powershell
cd tools\operator_console
python ci.py
```

The suite covers contract validation, persistence, dedupe, replay/reconnect, 50k-event performance, HTTP command validation, uncertain-send hard-stop behavior, and the passive real-service acceptance probe against the protocol-faithful mock service.

## Live service acceptance

Run:

```powershell
python acceptance.py --service-port 58751 --timeout 180 --json-out acceptance-result.json
```

The probe is passive. It sends only the schema-v1 hello/replay handshake and never creates a summon, whispers a player, trades, accepts payment, or retries a command. A live PASS requires one normal real-service request to progress through parser, queue, summon, and terminal payment/uncertain state with stable identity/correlation fields and clean cursor replay.

## Evidence boundary

Repository/mock acceptance is automated. A real live PASS cannot be manufactured without an actually reachable Summon Service producing real events. Until `acceptance-result.json` from that runtime reports `acceptance_pass: true`, live in-game E2E remains unproven even though the adapter implementation itself is complete.
