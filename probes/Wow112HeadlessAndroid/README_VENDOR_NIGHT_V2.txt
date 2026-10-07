WoW112 AH - VENDOR ONLY / RESILIENT SUPERVISOR V2
2026-10-07

CANONICAL STATUS:
- This is the canonical unattended Vendor-only supervisor for the Windows AH engine.
- AH core/binary remains unchanged by this supervisor commit.
- DE hardening remains experimental on its separate branch and is NOT part of this canonical supervisor.

START:
  RUN_NIGHT_VENDOR_ONLY_RESILIENT_V2.bat

V2 SUPERVISOR SAFETY:
- Vendor route only: action=vendor-best.
- DE BUY hard-disabled redundantly with de_limit=0.
- exact auction_id mutation chain must match:
    SENT auction IDs == SERVER PASS auction IDs == CONFIRMED auction IDs
  Any mismatch => HARD STOP, no reconnect/retry.
- AH_MUTATION_UNCERTAIN => HARD STOP.
- any live route=de TRY => HARD STOP.
- exact tuple revalidation +/-5 pages remains in the shared BUY primitive.
- stale target => skip.
- no automatic retry after an ambiguous BUY send.

RESILIENCE:
- reconnect is owned by the outer supervisor; the Rust process gets reconnect_limit=1.
- safe failures use exponential backoff:
    10s, 20s, 40s, 80s, 160s, then max 180s (+ 0-5s jitter)
- backoff resets after a healthy PASS or NOOP.
- after a clean BUY cycle: default sleep 20s.
- after healthy NOOP: default sleep 45s.
- every reconnect starts a fresh login/session/full scan.
- heartbeat every 10 cycles.
- final status summarizes cycles / passes / noops / recoveries / confirmed buys.

DEFAULTS:
  StopAt=08:00
  VendorMinProfitCopper=100
  MaxSingleBuyoutCopper=150000
  PostBuySleepSeconds=20
  NoopSleepSeconds=45
  RecoveryBaseSeconds=10
  RecoveryMaxSeconds=180

VALIDATION BASIS:
- overnight Vendor-only soak: 117 cycles
- 16 confirmed Vendor purchases
- 16/16 SENT -> SERVER PASS -> CONFIRMED
- 0 AH_MUTATION_UNCERTAIN
- 0 live DE purchases
- supervisor recovered from repeated safe transport/server failures

CORE BINARY USED IN THE VALIDATED PACKAGE:
  SHA256 f1abcccd291f6c021bfa33434dca81082f1c0e46db07f37e1acaea2f89f22cc4

The compiled EXE is intentionally not duplicated by this supervisor source commit. Build/use the canonical AH core separately and place wow112-ah-windows.exe next to these run scripts.
