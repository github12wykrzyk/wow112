# AuctionSniper vMaNGOS diagnostic baseline

Target: World of Warcraft 1.12.1 build 5875, Windows x86.

Upstream baseline:
- EinBaum/AuctionSniper
- commit d9d85807de9c82201e5e01c42ec5917c90257389
- MIT license retained as LICENSE.txt

Current project revision: V1 diagnostic / dry-run.

## Safety

This revision does not call PlaceAuctionBid anywhere in AuctionSniper.lua.
It cannot spend gold through its own automation path. Blizzard's normal Auction
House buttons remain untouched.

## vMaNGOS behavior

- LowBuyout replaces the old LastPage strategy and scans page 0.
- With LowBuyout OFF and FixedPage OFF, pages are cycled using correct zero-based
  pagination: floor((total - 1) / 50).
- Only one query is considered in flight at a time.
- A 12 second watchdog records a timeout and releases the local state if the
  expected list update never arrives.
- Results record total buyout and buyout-per-unit ranges, no-buyout rows, query
  latency and whether positive buyouts violate ascending order.
- CHAT_MSG_SYSTEM, UI_INFO_MESSAGE and UI_ERROR_MESSAGE are logged while AH is
  open so the exact 5875 transaction-result channel can be confirmed before V2.

## Existing GUI semantics in V1

- AutoScan: continuously submits diagnostic queries when CanSendAuctionQuery()
  permits it.
- LowBuyout: page 0 only.
- FixedPage: selected page only.
- LowBuyout OFF + FixedPage OFF: cycle all result pages.
- AutoBuy: DRY RUN only; evaluates and logs every candidate in a fresh result.
- SlowBuy: DRY RUN only; logs at most the first candidate in a fresh result.
- Manual Buy: DRY RUN only.

No candidate is submitted to the server.

## Diagnostics

Chat command:

- /asdiag status
- /asdiag reset
- /asdiag verbose

Verbose toggles per-auction result logging. Normal mode logs one compact summary
per AH result.

Persistent log markers:
- [VM-RESULT] query/page/latency/ranges/order diagnostics
- [VM-ITEM] individual row when verbose is enabled
- [DRYRUN] candidate matching current filters/watchlist
- [VM-EVENT] raw AH-adjacent client message event
- [VM-TIMEOUT] local query watchdog fired

## Watchlist

The engine supports B_AS_VM_Watchlist in AuctionSniper_Settings.lua. It is empty
by default for the first realm test. When populated by a later project commit,
entries support:
- name
- partial
- maxUnitPrice (copper)
- minStack
- maxTotalPrice (copper)
- enabled

When a watchlist exists, queries rotate by item name and page through all
matching results before moving to the next watch item.

## Evidence used

Server reference:
- vmangos/core development
- commit 464179081673cfd240f7ffe7f0daf96bca0b5a70

Client UI reference:
- MOUZU/Blizzard-WoW-Interface 1.12.1 default Auction UI
- Blizzard default UI calls PlaceAuctionBid normally and updates browse results
  from AUCTION_ITEM_LIST_UPDATE.

Historical Vanilla addon reference:
- Auctioneer 3.9.0 for WoW 1.12.1
- BidManager treats CHAT_MSG_SYSTEM == ERR_AUCTION_BID_PLACED as accepted and
  maps UI_ERROR_MESSAGE values such as ERR_ITEM_NOT_FOUND,
  ERR_NOT_ENOUGH_MONEY, ERR_AUCTION_BID_OWN and ERR_AUCTION_HIGHER_BID to
  failed pending bids.

V1 still records the raw messages rather than trusting those historical
assumptions for this realm.

Detailed server audit: docs/AUCTIONSNIPER_VMANGOS_AUDIT.md
