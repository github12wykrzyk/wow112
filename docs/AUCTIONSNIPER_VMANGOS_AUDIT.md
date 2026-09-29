# AuctionSniper / vMaNGOS audit for WoW 1.12.1 build 5875

## Source snapshots

- AuctionSniper upstream: https://github.com/EinBaum/AuctionSniper
  - commit: d9d85807de9c82201e5e01c42ec5917c90257389
  - license: MIT
- vMaNGOS reference: https://github.com/vmangos/core
  - development commit: 464179081673cfd240f7ffe7f0daf96bca0b5a70
- Client target: World of Warcraft 1.12.1 build 5875, Windows x86.

The realm is known to use vMaNGOS, but its exact fork/revision is not pinned yet.
Findings below are exact for the referenced upstream vMaNGOS snapshot and must be
confirmed in game before they are treated as exact behavior of the realm.

## Client -> server browse flow

AuctionSniper uses the stock Vanilla Lua API `QueryAuctionItems(...)`.
vMaNGOS handles the request in `WorldSession::HandleAuctionListItems`, creates
an `AuctionHouseClientQueryTask`, and builds the result in
`AuctionHouseObject::BuildListAuctionItems`.

vMaNGOS allows one outstanding AH list request per session:
`if (ReceivedAHListRequest()) return;`.
The async task clears that state before producing the response. A robust addon
should therefore model one query in flight rather than spam concurrent requests.

## Browse order: buyout price

vMaNGOS keeps a dedicated browse index:
`AuctionMultiMap OrderedAuctionMap;`

When an auction is added:
`OrderedAuctionMap.insert(std::pair<uint32, AuctionEntry*>(ah->buyout, ah));`

Consequences:
- browse results are ordered by buyout key;
- `buyout == 0` auctions sort before positive buyouts;
- LastPage is not a reliable "new auctions" page;
- the old CMaNGOS strategy based on increasing Auction ID must not be assumed
  for vMaNGOS.

For this core, price-oriented or item-specific scans are the natural starting
point.

## Five-minute same-IP anti-sniping lock

When a player lists an auction, the referenced vMaNGOS handler stores:
`AH->lockedIpAddress = GetRemoteAddress();`
`AH->depositTime = time(nullptr);`

`AuctionEntry::IsAvailableFor(Player*)` exposes a locked auction only to a
session whose remote IP matches the stored address.

`AuctionHouseObject::Update()` clears the lock after five minutes:
`if (entry->depositTime + 5*60 < curTime) entry->lockedIpAddress.clear();`

The source comment explicitly describes this as protection against AH sniping.

On the referenced core:
- a fresh listing is initially visible only from the seller's remote IP;
- other IPs see it only after the lock clears;
- multiple accounts sharing the same public IP can see each other's fresh
  listings during that window.

A realm fork can alter this behavior, so the exact delay must be measured on the
actual server.

## Bid / buyout authority

`PlaceAuctionBid(...)` reaches `WorldSession::HandleAuctionPlaceBid`.
The server validates the auction context and transaction, including existence,
ownership, same-account ownership, bid constraints and player money.

For a buyout the server updates money/bidder state, handles an existing bidder,
sends seller/winner mail, returns an auction command result, removes the auction
from active structures and deletes it from the DB.

The server is authoritative. Calling `PlaceAuctionBid` is only an attempt; the
addon must not count it as a confirmed purchase until confirmation is observed.

## Upstream AuctionSniper issues relevant to vMaNGOS

1. LastPage assumes fresh auctions are at the end of the list. This conflicts
   with vMaNGOS buyout-price ordering.
2. `math.floor(total / 50)` selects an empty page when total is an exact
   multiple of 50. For zero-based pages and total > 0 use
   `math.floor((total - 1) / 50)`.
3. `B_AS_LogBuyout` runs immediately after `PlaceAuctionBid`; it logs an
   attempted transaction as if it were a successful purchase.
4. The persisted `B_AS_GS["Items"]` GUI rows are initialized but are not
   consumed by `B_AS_CheckItem`.
5. The import dialog executes text with `RunScript(text)`; future project code
   should parse validated configuration instead.
6. `B_AS_SCAN_RANDOM` is declared but is not used by the normal AutoScan path.
7. Price caps operate on total auction buyout and virtual item quality rather
   than explicit per-unit rules.

## Recommended project state machine

Future iterations should converge on:
`IDLE -> QUERY_SENT -> LIST_RECEIVED -> FILTER -> CANDIDATE -> BUY_SENT -> PENDING -> CONFIRMED/FAILED -> RESCAN`

Design rules:
- one list query in flight per session;
- no continuing over stale list indices after a successful buyout;
- separate seen / attempted / confirmed / failed counters;
- ignore `buyout == 0` in buyout strategies;
- calculate unit price from buyout and stack count;
- exact/partial per-item rules with explicit max unit price;
- optional max total price, stack constraints and session spend limit;
- diagnostic mode that never submits `PlaceAuctionBid`.

## First realm validation

Before speed tuning, collect evidence for:
1. observed page order for known buyout values;
2. placement of no-buyout auctions;
3. actual client/server query cadence;
4. visibility delay for a listing created from a different public IP;
5. visibility from another account behind the same public IP;
6. observable confirmation/failure signals after `PlaceAuctionBid`;
7. race behavior when another buyer wins between list result and buy request.

## Integration status

Feature preflight passed on exact SHA
`078d97eac2b794c0d94aff389931ae606653cb48` (run `36639456139`).
This audited tree is eligible for integration into `parallel`. A runnable
updater candidate is valid only after the exact integrated parallel SHA passes
the full candidate/package/provenance gates. Gameplay remains unverified.


## Vanilla 1.12 client-result evidence

Blizzard's default 1.12.1 Auction UI calls `PlaceAuctionBid` directly and
refreshes browse state from `AUCTION_ITEM_LIST_UPDATE`; it does not expose a
dedicated AuctionUI Lua callback for the server command result.

Historical Auctioneer 3.9.0 code targeting WoW 1.12.1 tracks pending bids using:
- `CHAT_MSG_SYSTEM` with `ERR_AUCTION_BID_PLACED` as accepted;
- `UI_ERROR_MESSAGE` for failures such as `ERR_ITEM_NOT_FOUND`,
  `ERR_NOT_ENOUGH_MONEY`, `ERR_AUCTION_BID_OWN` and
  `ERR_AUCTION_HIGHER_BID`.

This is strong compatibility evidence, but V1 intentionally logs the raw
`CHAT_MSG_SYSTEM`, `UI_INFO_MESSAGE` and `UI_ERROR_MESSAGE` channels on the
actual 5875 client before V2 relies on any one of them for confirmed purchases.

## V1 diagnostic implementation

The first project revision after the upstream import is intentionally hard
dry-run:
- no `PlaceAuctionBid` call exists in the addon automation code;
- old LastPage behavior is replaced by LowBuyout/page-0 mode;
- all-pages mode uses correct zero-based last-page calculation;
- one local query-in-flight state is enforced with a timeout watchdog;
- result summaries measure latency, zero-buyout rows, total/unit price ranges
  and ascending-buyout order violations;
- watchlist-aware item-name queries and unit-price candidate filtering are
  implemented but the default watchlist is empty;
- candidate evaluation logs `[DRYRUN]` only.

This V1 is intended to establish realm evidence before enabling AutoBuy.


## Realm evidence: first V1 dry-run test

Exact tested Parallel candidate:
`8ceebf93d30e1728948a3d71d3296295b8306fba`.

The user-provided in-game screenshot showed roughly 55.5k visible auctions and
page 0 repeatedly returned 50/50 rows with `buyout == 0`. Query-result latency
was approximately 0.094-0.125 seconds. The same query sequence number was also
logged more than once, showing that this client/server combination can emit
extra `AUCTION_ITEM_LIST_UPDATE` notifications around one request.

V1.1 therefore:
- does not treat page 0 as the cheapest purchasable page;
- binary-searches the transition from bid-only rows to positive buyouts;
- scans a bounded 10-page cheap-buyout window from that boundary;
- re-discovers the boundary after each window;
- uses a 200 ms post-result guard and ignores list-update events received when
  no addon query is in flight.

Auto-buy remains hard-disabled; this revision still contains no
`PlaceAuctionBid` call in the automation code.
