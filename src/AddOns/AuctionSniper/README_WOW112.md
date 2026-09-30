# AuctionSniper vMaNGOS V2 AutoBuy

Target: World of Warcraft 1.12.1 build 5875, Windows x86.

Upstream baseline:
- EinBaum/AuctionSniper
- commit d9d85807de9c82201e5e01c42ec5917c90257389
- MIT license retained as LICENSE.txt

Current project revision: V2 confirmed one-at-a-time AutoBuy on the validated
vMaNGOS cheap-buyout scanner.

## Scanner

- LowBuyout probes page 0, binary-searches the first page containing buyout > 0,
  then scans a 10-page cheap-buyout window.
- The boundary is cached. Normal refresh validates boundary-1 and boundary,
  avoiding a full binary search every cycle.
- One Auction House list query is considered in flight at a time.
- Duplicate AUCTION_ITEM_LIST_UPDATE events are ignored.
- Result diagnostics retain total/unit price ranges and order-violation counts.

## AutoBuy LIVE

AutoBuy is now a real buyout path and calls PlaceAuctionBid only when:
- AutoBuy LIVE is explicitly ON;
- the current result is a real scan result, not a boundary-search/verification
  page;
- no previous buy is pending;
- the item passes the existing AuctionSniper filters/watchlist;
- the purchase fits the remaining session budget and purchase-count limit.

Only one buy can be pending at a time.

A successful transaction is confirmed from the Vanilla 1.12 client message
ERR_AUCTION_BID_PLACED ("Bid accepted.") observed through CHAT_MSG_SYSTEM or
UI_INFO_MESSAGE. Known UI_ERROR_MESSAGE auction failures are recorded as
failed attempts.

After success or failure the exact source page is queried again before the
logical scanner advances, because vMaNGOS removes/changes auction indexes after
a transaction.

A five-second unresolved transaction timeout hard-stops AutoBuy instead of
blindly submitting another purchase.

## Migration safety

AutoBuy LIVE is forced OFF on every addon load. A SavedVariables value left ON
by an older dry-run build cannot silently become a live buyer after updating.

The user must explicitly click AutoBuy LIVE = ON after loading V2.

DryRun remains available through the old SlowBuy button, now labeled DryRun.
Manual Buy with AutoBuy LIVE OFF is also dry-run only.

## Session guards

Defaults:
- maximum confirmed spend: 50g
- maximum confirmed purchases: 20

Existing per-quality maximum-price filters remain active in addition to these
session guards.

Commands:
- /asbuy status
- /asbuy limits <gold> <count>
- /asbuy reset
- /asbuy off

A limit value of 0 means unlimited. /asbuy reset clears session spend/count only
when no buy is pending.

## Diagnostics

- /asdiag status
- /asdiag reset
- /asdiag verbose

Important log markers:
- [VM-RESULT], [VM-BOUNDARY], [VM-CACHE], [VM-STATE]
- [BUY-SENT] one request submitted
- [BUY-OK] server/client-confirmed accepted buy
- [BUY-FAIL] known rejection or timeout
- [BUY-RESCAN] post-transaction page refresh
- [BUY-STOP] safety stop

## Evidence

Validated target-realm scanner evidence is maintained in:
docs/AUCTIONSNIPER_VMANGOS_AUDIT.md

Transaction-message compatibility references:
- Blizzard WoW 1.12.1 GlobalStrings.lua:
  ERR_AUCTION_BID_PLACED = "Bid accepted."
  plus ERR_AUCTION_HIGHER_BID, ERR_AUCTION_BID_OWN,
  ERR_AUCTION_DATABASE_ERROR, ERR_ITEM_NOT_FOUND and ERR_NOT_ENOUGH_MONEY.
- Historical Auctioneer 3.9.0 for WoW 1.12.1 tracks accepted bids from
  CHAT_MSG_SYSTEM == ERR_AUCTION_BID_PLACED and failures from UI_ERROR_MESSAGE.

V2 transaction behavior still requires an in-game test on the target realm
before it is treated as gameplay-accepted.
