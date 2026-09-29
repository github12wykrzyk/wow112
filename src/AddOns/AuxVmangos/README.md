# AuxVmangos

Independent Auction House scanner/sniper for World of Warcraft 1.12.1 (5875), designed around the observed upstream vMaNGOS auction implementation.

## Why this is separate from AUX

AUX was audited as a behavioral reference, but its published project is marked All Rights Reserved and its Vanilla GitHub tree does not provide a permissive source license. This module therefore does not vendor AUX source.

## vMaNGOS-specific behavior

Reference: vmangos/core development commit 464179081673cfd240f7ffe7f0daf96bca0b5a70.

The reference core keeps browse auctions in a buyout-keyed ordered multimap. On the tested realm, page 0 was observed to contain bid-only auctions (buyout = 0), so page 0 is not a useful "cheapest buyout" page.

AuxVmangos first locates the transition from buyout=0 to buyout>0 by binary-searching auction pages, then scans a configurable number of pages from that boundary.

Only one AUCTION_ITEM_LIST_UPDATE is consumed per query. Extra client events after the query has already been consumed are counted and ignored.

## Purchase safety

Default is DRY-RUN. LIVE must be explicitly enabled with /avm live on.

Before a live purchase, the candidate is queried again by item name and matched by an equivalent signature. The list index from the original browse result is never reused blindly.

A sent buyout enters BUY_PENDING. Exact money delta is used as positive confirmation evidence. Timeout is UNKNOWN, never success. During UNKNOWN_HOLD, new live purchases are paused to avoid duplicate purchases after delayed server/client state.

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
- /avm add exact;Black Lotus;60g;120g;1;20
- /avm add partial;Lotus;60g;120g;1;20

Rule fields are: match type; item name; max unit price; max total price; min stack; max stack. maxTotal=0, maxStack=0 and budget=0 mean unlimited.

## Test order

1. Leave LIVE OFF.
2. Add one narrow rule.
3. Open AH and run /avm on.
4. Verify binary boundary convergence, extra-event count and DRYRUN candidates.
5. Only after diagnostic evidence is clean should LIVE be enabled.
