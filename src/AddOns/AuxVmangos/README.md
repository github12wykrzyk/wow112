# AuxVmangos 0.6 unified market bot

Independent Auction House scanner/sniper for World of Warcraft 1.12.1 (5875), designed around the observed upstream vMaNGOS auction implementation.

## Why this is separate from AUX

AUX was audited as a behavioral reference, but its published project is marked All Rights Reserved and its Vanilla GitHub tree does not provide a permissive source license. This module therefore does not vendor AUX source.

## vMaNGOS-specific behavior

Reference: vmangos/core development commit 464179081673cfd240f7ffe7f0daf96bca0b5a70.

The reference core keeps browse auctions in a buyout-keyed ordered multimap. On the tested realm, page 0 was observed to contain bid-only auctions (buyout = 0), so page 0 is not a useful "cheapest buyout" page.

AuxVmangos schedules each watchlist rule independently. It sends the rule name to QueryAuctionItems first, locates the buyout=0 to buyout>0 transition inside that filtered result set, then scans a configurable number of the cheapest matching pages. The discovered boundary is cached per rule. On the next cycle the addon verifies boundary-1 is still bid-only and boundary is still positive; a valid cache skips the full binary search, while a failed verification invalidates the cache and falls back to a full search.

Only one AUCTION_ITEM_LIST_UPDATE is consumed per query. A short post-result settle window absorbs delayed duplicate events before the next query is sent. Extra events are counted only when they occur near a result from our enabled scanner, so unrelated AH traffic no longer pollutes the counter.

## Purchase safety

Default is DRY-RUN. LIVE must be explicitly enabled with /avm live on. DRY-RUN evaluates and revalidates qualifying auctions even when the character cannot currently afford them; the log reports affordable=false and the missing amount. LIVE always re-checks current money immediately before PlaceAuctionBid and blocks the purchase when funds are insufficient.

Before a live purchase, the candidate is queried again by item name on its source page and adjacent filtered pages, then matched by an equivalent signature. The list index from the original result is never reused blindly.

A sent buyout enters BUY_PENDING. Exact money delta is used as positive confirmation evidence. Timeout is UNKNOWN, never success. During UNKNOWN_HOLD, new live purchases are paused to avoid duplicate purchases after delayed server/client state. LIVE has a session purchase limit (default 1); once the limit is confirmed, LIVE auto-disarms and scanning continues in dry-run.

## Commands

- /avm on
- /avm off
- /avm live on
- /avm live off
- /avm status
- /avm list
- /avm del N
- /avm pages N
- /avm budget 100g
- /avm maxbuys 1
- /avm add exact;Black Lotus;60g;120g;1;20
- /avm add partial;Lotus;60g;120g;1;20

Rule fields are: match type; item name; max unit price; max total price; min stack; max stack. maxTotal=0, maxStack=0 and budget=0 mean unlimited.

## Test order

1. Leave LIVE OFF.
2. Add one narrow rule.
3. Open AH and run /avm on.
4. Verify binary boundary convergence, extra-event count and DRYRUN candidates.
5. Only after diagnostic evidence is clean should LIVE be enabled.


## Unified MarketScan + PriceDB

The same serialized vMaNGOS query scheduler now owns both the watchlist/live-buy bot and whole-market buyout snapshots. MarketScan first finds or verifies the global buyout=0 -> buyout>0 boundary, then scans every positive-buyout page through the last page. Watchlist scanning is paused while MarketScan owns the scheduler.

PriceDB is stored in AVM_DB. Per item and per retained snapshot it records auction count, unit count, minimum, p25, median, p75, maximum, listing-average unit price, quantity-weighted unit price, and disappeared units relative to the prior snapshot. Disappeared units are explicitly a turnover proxy: an auction can disappear because it sold, expired, or was cancelled.

Commands:
- /avm market start
- /avm market stop
- /avm market status
- /avm market item Black Lotus
- /avm market auto 60
- /avm market retention 24
- /avm market clear

AutoMarket runs only while the Auction House is open. A market scan automatically disarms LIVE before taking ownership of the AH query scheduler.
