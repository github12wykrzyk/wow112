# Aux FAST Bridge

This addon preserves the original `aux-addon-vanilla` GUI and scan state machine while replacing its fragile list-response pacing on this WoW 1.12.1 / vMaNGOS target.

Version 1.2 correlates every original AUX list query with the verified native `SMSG_AUCTION_LIST_RESULT` (0x025C) handler exposed by `WoWAHThrottleNative_5875_v8_FASTMARKET.dll`. The next AUX page is accepted only after a newer real network response has populated the stock client auction list.

This matters because one genuine auction response can generate many `AUCTION_ITEM_LIST_UPDATE` events while owner data resolves. Treating those duplicate UI events as independent page responses can advance AUX too early and then fall into its 5-second retry timeout. The bridge therefore keeps the UI events for diagnostics but does not use them as page-correlation evidence.

The stock `CanSendAuctionQuery` gate is bypassed only while an original AUX scan owns the query channel and AuxVmangos is idle. If the native callback is unavailable for 1.5 seconds, the bridge falls back to upstream AUX waiting semantics rather than sending overlapping queries.

The original Aux source is not vendored here. The Parallel addon packager fetches the exact upstream commit declared in `runtime/parallel_candidate.json`.

Current pinned upstream:
- repository: `shirsig/aux-addon-vanilla`
- commit: `6b56d0fec36eb2c4465b73727223aeaf547da6d7`

`/auxfast` reports query count, native responses, matched responses, fallback timeouts, UI-event count and gate bypasses. In a healthy scan, `queries`, `native` and `matched` should advance together while `uiEvents` may be much larger.
