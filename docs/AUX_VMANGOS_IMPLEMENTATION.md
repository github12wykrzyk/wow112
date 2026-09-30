# Aux / AuctionSniper -> AuxVmangos vMaNGOS implementation note

## Realm evidence incorporated

The AuctionSniper diagnostic candidate on parallel produced repeated page-0 results with zero=50 and buyouts=0 at roughly 55k total auctions. It also showed multiple AUCTION_ITEM_LIST_UPDATE events for one logical query and approximately 94-125 ms client-observed query/result latency.

These observations are treated as gameplay evidence for the tested realm, not as generic guarantees for every vMaNGOS fork.

## Resulting design

1. Consume AUCTION_ITEM_LIST_UPDATE only while queryInFlight=true; count later events as extras.
2. Do not treat page 0 as "low buyout".
3. Binary-search pages for the first page containing buyout>0.
4. Scan configurable pages starting at that boundary.
5. Match watchlist rules on unit and total price.
6. Re-query/revalidate a candidate before any real PlaceAuctionBid.
7. Never reuse a stale list index across queries.
8. BUY_PENDING can become CONFIRMED only with positive evidence; timeout becomes UNKNOWN.
9. UNKNOWN temporarily blocks additional live buys and reserves the candidate signature against duplicate attempts.

## Relationship to AuctionSniper

AuctionSniper remains the first diagnostic probe and is not overwritten. AuxVmangos is an independent implementation used to test the stronger vMaNGOS-specific state machine.

## Relationship to AUX

AUX informed the behavioral audit (scanning, auction signatures, price-per-unit concepts), but its source is not vendored into this repository because no permissive source license was established.


## Unified market-bot architecture (0.6)

AuxVmangos is the single active AH automation engine. Watchlist sniper, candidate revalidation, guarded LIVE buy and full-market PriceDB snapshots share one query-in-flight gate and one CanSendAuctionQuery scheduler.

Whole-market scans use the same vMaNGOS ordering evidence as the sniper: locate/cache the first page containing positive buyouts, skip the bid-only prefix, then scan through the final page. A cached global boundary is verified before a subsequent full scan and falls back to a fresh binary search when stale.

AuctionSniper source remains in the repository as diagnostic/recovery evidence but is removed from the active parallel addon candidate for this experiment to avoid two addons competing for AUCTION_ITEM_LIST_UPDATE / QueryAuctionItems.
