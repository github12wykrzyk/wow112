# Aux FAST Bridge

This addon is a small integration layer for the original `aux-addon-vanilla` frontend.

It does not replace Aux's GUI or scan state machine. During an Aux list scan it only
bypasses the stock client-side `CanSendAuctionQuery` wait; Aux still sends the next
query only after it has accepted the previous `AUCTION_ITEM_LIST_UPDATE`.

The original Aux source is not vendored here. The Parallel addon packager fetches
the exact upstream commit declared in `runtime/parallel_candidate.json`.

Current pinned upstream:
- repository: `shirsig/aux-addon-vanilla`
- commit: `6b56d0fec36eb2c4465b73727223aeaf547da6d7`

`/auxfast` prints the active-scan state and response counters.
