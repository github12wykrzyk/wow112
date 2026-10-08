# WoW112 Summon Operator — autonomous terminal live test

This package runs the proven TELE10 summon/payment path without visible WoW clients.

Run `RUN_LIVE_TEST.cmd`.

The runner starts four headless world sessions through `tele07_supervisor.exe`:
- CUSTOMER: default `octowar1 / Smokinpole`
- SLAVE1: `octowinter1 / Winterone`
- SLAVE2: `octowinter2 / Wintertwoo`
- SUMMONER: `taxi3 / Teletanaris`

The common WoW password is read from process environment `WOW112_PASSWORD`; if absent, the runner asks once with a masked prompt. It is not written to the wrapper report.

Default live scenario: one Winterspring summon and 40000 copper (4g) payment. The payer sends trade mutations once only. `UNCERTAIN` is a hard failure and is never retried automatically.

A run passes only when the supervisor exits successfully and the durable TELE10 JSON ledger contains the matching paid/overpaid summon record. The payer requires server `TRADE_COMPLETE`; socket write success alone is not payment proof.

Evidence is written under `results/LIVE_<timestamp>/`, including `FINAL_REPORT.json`, supervisor state, child logs and `tele10_payment_ledger.json`.

Examples:

```powershell
.\RUN_LIVE_TEST.cmd -Cycles 3
.\RUN_LIVE_TEST.cmd -CustomerAccount octowar1 -CustomerCharacter Smokinpole -SummonerCharacter Teletanaris -PayCopper 40000
```

Source reuse: TELE10 headless summon/trade/payment stored source from `feature/tele10-headless-trade-payment-ledger-v1f@b5c793d0a55915a9cfd3b08395ee16f7000e6352`.
