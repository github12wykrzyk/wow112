# Final Acceptance Status

The Operator Console implementation is repository-complete. A separate passive probe exists for the only evidence that cannot be manufactured in CI: a real reachable Summon Service producing a complete live request.

## Repository acceptance — PASS

The product branch was validated through a synthetic final-validation branch that contains the exact Operator Console product tree, the independently verified canonical delivery-route test compatibility repair, and a repo-level wrapper that executes `tools/operator_console/ci.py`.

Evidence:

- validation branch: `feature/summon-console-final-validation`
- validation HEAD: `e38870ec3b9b4c64a0cce4db10c1ccd124d8f595`
- GitHub Actions run: `37749062554`
- repo suite: `150/150` PASS
- operator-console full-suite wrapper: PASS
- routed repository gates: PASS
- `PARALLEL_FEATURE_PREFLIGHT: PASS`
- integration job: skipped

The Operator Console suite covers contract validation, persistence, dedupe, replay/reconnect, 50k-event performance, HTTP command validation, uncertain-send hard-stop behavior, and the passive real-service acceptance probe against the protocol-faithful mock service.

## Live service acceptance

Run against an actually reachable headless Summon Service V1:

```powershell
cd tools\operator_console
python acceptance.py --service-port 58751 --timeout 180 --json-out acceptance-result.json
```

Optional exact customer requirement:

```powershell
python acceptance.py --service-port 58751 --customer ExactPlayerName --timeout 300 --json-out acceptance-result.json
```

The probe is passive. It sends only the schema-v1 hello/replay handshake and never creates a summon, whispers a player, trades, accepts payment, or retries a command. A live PASS requires one normal real-service request to progress through parser, queue, summon, and terminal payment/uncertain state with stable identity/correlation fields and clean cursor replay.

## Evidence boundary

Repository/mock acceptance is complete and automated. A real live PASS requires an actually reachable Summon Service producing real events. Until `acceptance-result.json` from that runtime reports `acceptance_pass: true`, live in-game E2E is correctly recorded as not yet observed rather than guessed. This does not leave an implementation gap in Operator Console; it is an external-runtime evidence requirement.
