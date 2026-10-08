# Summon Terminal Soak V1

Scope: terminal/headless only. This harness must not use WoW GUI, AddOns or Lua.

Base policy: the branch is created only from current `parallel`. The live-tested branch `feature/summon-operator-terminal-livetest` and exact SHA `d753829314db39e5cd9aad57ce1d46daaf4d55da` are evidence/reference only and are never merged or cherry-picked by this harness.

## Entrypoint

From `tools\summon_terminal_soak`:

```bat
RUN_SUMMON_SOAK.cmd
RUN_SUMMON_SOAK.cmd --cycles 20
RUN_SUMMON_SOAK.cmd --cycles 50
RUN_SUMMON_SOAK.cmd --faults
RUN_SUMMON_SOAK.cmd --whispers
RUN_SUMMON_SOAK.cmd --payments
```

Quality-only structural validation:

```bat
RUN_SUMMON_SOAK.cmd --quality-only
```

Each invocation creates `runs/<timestamp>/` with:

- `summary.json`
- `summary.md`
- `events.jsonl`
- `failures.json`
- `timings.json`
- `customer.log`
- `summoner.log`
- `clicker1.log`
- `clicker2.log`
- `payer.log`
- `exact_sha_manifest.json`

## Canonical primitive gate

The requested real wire-path suite requires TELE07/08/10 primitives to exist on the current parallel-derived checkout. The harness deliberately reports `BLOCKED` instead of importing those primitives from the historical live-tested branch.

Required primitives include the supervisor, production whisper parser/request queue/full-roundtrip roles, TELE10 trade/payment/payer/receiver/ledger roles, plus the existing canonical headless login/world and portal primitives.

Synthetic/quality PASS is never equivalent to LIVE PASS.

## Deterministic reconnect recovery

The TELE07 supervisor may replay a logical summon cycle only for one proven-safe case: the CUSTOMER reconnects after `PASS_RITUAL_STARTED` but before receiving `SMSG_SUMMON_REQUEST` (`0x02AB`) and before any payment state is entered. The replay is bounded by the existing restart budget, recycles every role with fresh one-shot guards, and is recorded as a recovery in supervisor evidence.

Any mutation-uncertain marker, active-role uncertain exit/stale condition, or payment/trade uncertainty remains fail-closed with no automatic replay.

## Security

Credentials are never fixtures or report data. LIVE orchestration consumes `WOW112_PASSWORD` from process memory/environment; the password is not written to evidence or logs.
