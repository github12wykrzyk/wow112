# TELE10 payer trade scam-guard root cause

Live E2E evidence on 2026-10-08 showed that summon, portal and teleport completed, gold was visible to the summoner, but the payer's immediate `CMSG_ACCEPT_TRADE` never produced partner acceptance.

vMaNGOS `TradeHandler.cpp` applies a scam-prevention delay after a trade modification. `HandleAcceptTradeOpcode` returns `TRADE_STATUS_BACK_TO_TRADE` without accepting while the delay is active. The configured delay is 200 ms, but the implementation compares against `time_t`/`difftime`, so the effective safe boundary is the next wall-clock second.

The autonomous payer therefore waits for the server `BACK_TO_TRADE` acknowledgement after `CMSG_SET_TRADE_GOLD`, then waits until at least 1250 ms have elapsed since the gold write before sending the single `CMSG_ACCEPT_TRADE` mutation. There is still no retry after an uncertain economic send.
