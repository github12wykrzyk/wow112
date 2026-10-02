# AuxVmangos 0.27.1 — reload path physically removed

The previous reload experiments are no longer merely disabled: their scheduler state, chat/console trigger, restore snapshot, OnUpdate handling and login/AH restore logic have been removed from active Lua. Continuous AVM automation can only continue in-process through the normal loop and AuxFastBridge headless restart/resume path. Legacy reload SavedVariables are cleared on load but cannot trigger anything.

# AuxVmangos 0.27 — automatic scans always headless

The reload-per-scan experiment is retired. Continuous AVM automation now stays in-process and relies on AuxFastBridge 3.0 to suppress **all automated AUX Search result rendering**, including restarts and resumes after guarded transactions. Automatic scans still feed every auction/page into vendor, disenchant, flip, revalidation and purchase logic, but they do not append rows to the visible AUX Search list and do not trigger upstream per-page `search.table:SetDatabase()` rebuild/sort work. Manual AUX Search remains normal and visible.

# AuxVmangos 0.26 — controlled reload after every full scan

Continuous AUX automation now defaults to a controlled `ReloadUI()` after each completed full scan, but only after all pending/unknown/revalidation/purchase state is fully idle. Before reload, session purchase/spend counters, per-item flip exposure, recent-auction guards, diagnostics counters, loop count, and the active AUX filter are snapshotted in `AVM_DB`. AuxFastBridge 2.9 temporarily detaches AUX's frame OnHide handler so the reload does not intentionally call `CloseAuctionHouse()`.

After the UI reload the AUX Search window is reopened automatically, the saved filter is restored, and a **normal fresh** Search starts. It is intentionally not a headless `execute(true)` repeat: every cycle behaves like a clean first scan and repopulates the visible AUX GUI, avoiding cumulative Search/UI/GC state while keeping the window usable. If the AH session cannot be resumed, retries fail closed and the addon asks for the Auction House to be reopened manually. `/avm reloadscan off` restores the existing in-process repeat fallback; `/avm reloadscan on` re-enables the default.

# AuxVmangos 0.17 — live market flip

Adds a conservative commodity flip route on top of the validated original AUX full-market scan.

The flip engine only considers non-grey stackable items (`max_stack > 1`). During the full AUX scan it builds a current order book per item ID and considers the cheapest unit-price auction as the entry candidate. The reference exit price excludes that auction and must have enough visible supply to cover `max(flipdepth, candidate stack count)` units.

Default valuation:
- `flipdepth = 5` units;
- target relist price = current depth floor minus 1 copper;
- AH cut = 5%;
- safety margin = 25%, so entry price must be <= 75% of net exit value;
- minimum expected profit = 10s;
- maximum purchase = 5g.

Before any LIVE flip purchase the addon re-queries that exact item by name across every result page, rebuilds the item order book, requires the original candidate auction to still exist, recalculates depth/net exit/margin, then performs one final exact-auction revalidation before `PlaceAuctionBid`. Any missing depth, moved auction, timeout, wallet/session-limit failure or changed margin fails closed.

Commands:
- `/avm auxarb flip on|off`
- `/avm auxarb flipmin 10s`
- `/avm auxarb flipmax 5g`
- `/avm auxarb flipdepth 5`
- `/avm auxarb flipcut 5`
- `/avm auxarb flipmargin 25`
- `/avm auxarb status`

Vendor and live-DE routes remain intact. Aux FAST Bridge 2.0 already preserves full-scan caches across guarded vendor pause/resume cycles.

---

# AuxVmangos 0.16 — live depth-3 disenchant arbitrage

Disenchant purchases no longer depend on AUX historical material prices. A completed original AUX full Search builds a current-scan order book for every Vanilla enchanting material. A material price is the third-cheapest unit level by default: the lowest BO/unit level at which cumulative visible supply reaches at least 3 units.

DE valuation is:

`net material price = live depth floor × (1 - AH cut)`

`DE net EV = Σ(probability × average drop quantity × net material price)`

A DE candidate must pass all gates: every possible material has the configured live depth, `net EV - buyout >= deMinProfit`, `buyout <= deMaxBuyout` when configured, and `buyout <= 75% of net EV` with the default 25% safety margin.

Before any LIVE DE purchase, AuxVmangos re-queries each possible resulting material by name, scans all result pages, rebuilds its depth floors from the fresh results, recomputes EV and the safety margin, then revalidates the exact item auction immediately before `PlaceAuctionBid`. Missing depth, timeout, changed profitability, a moved item, wallet/session limits, or UNKNOWN purchase confirmation all fail closed.

Defaults: `dedepth=3`, `decut=5`, `demargin=25`. Commands:
- `/avm auxarb dedepth 3`
- `/avm auxarb decut 5`
- `/avm auxarb demargin 25`
- existing `/avm auxarb demin ...` and `demax ...` remain active.

Vendor arbitrage is otherwise unchanged; quality-0 grey items remain excluded.

Poor-quality (grey) items are excluded from vendor arbitrage. Serrated Petal (item 18223) showed a large mismatch between embedded Vanilla vendor data and the current realm's actual vendor payout, so grey junk is no longer considered for vendor-profit purchases.

The validated original AUX Search path is now the primary full-market transport. On WoW 1.12.1 build 5875 the exact client query cooldown is reduced to 25 ms by the native companion, while original AUX remains response-correlated one request at a time.

## Original AUX arbitrage loop

For an ordinary unfiltered AUX Search, AuxVmangos evaluates every auction after original AUX has processed it into history:

1. vendor profit uses original AUX learned merchant-sell values first, then the embedded Vanilla 1.12 vendor table;
2. disenchant profit uses original AUX `aux.core.disenchant.value`, pricing expected materials from AUX history/market values;
3. the best qualifying opportunity on the current page becomes a candidate;
4. LIVE pauses original AUX only at the page boundary;
5. the exact auction is re-queried on the unfiltered source page (plus adjacent pages if required);
6. identity, profitability, wallet, purchase-count and session-budget limits are revalidated immediately before buy;
7. money-delta confirmation remains authoritative; UNKNOWN still fail-closes further purchases;
8. after confirmation, race, block or timeout, AUX resumes from its saved Search continuation.

The v1 loop buys at most the best qualifying candidate from a scanned page before resuming at the next page. Seller names are intentionally ignored.

Defaults:
- AUX arbitrage valuation ON;
- AUX arbitrage LIVE OFF on every login/reload/AH close;
- vendor min profit 5s, max buyout 1g;
- disenchant min profit 5s, max buyout 1g;
- session purchase limit 1 unless changed with `/avm maxbuys N`;
- session budget unlimited unless set with `/avm budget ...`.

Commands:
- `/avm auxarb status`
- `/avm auxarb on|off`
- `/avm auxarb live on|off`
- `/avm auxarb demin 5s`
- `/avm auxarb demax 1g`
- vendor thresholds: `/avm vendor minprofit 5s`, `/avm vendor maxbuyout 1g`
- shared guards: `/avm maxbuys N`, `/avm budget 100g`

Disenchant valuation requires AUX history for the resulting dust/essence/shard. If AUX has no value for one of the possible materials, the auction is skipped rather than guessed.

---

# AuxVmangos 0.11 unified market bot + vendor FAST SEEK arbitrage

Independent Auction House scanner/sniper for World of Warcraft 1.12.1 build 5875, designed for the observed vMaNGOS auction behavior.

AuxVmangos is the **single AH query owner** in the Parallel candidate. AuctionSniper remains in repository history/source for rollback evidence but is intentionally not packaged beside AuxVmangos, because two independent consumers of `AUCTION_ITEM_LIST_UPDATE` would race each other.

## Why WATCH mode changed in 0.8

vMaNGOS browse results are ordered by **total buyout**, not by price per item. A fixed window of the first few positive-buyout pages is therefore not sufficient to find the best unit-price stack: a larger stack can have a higher total buyout while still being much cheaper per unit.

0.8 keeps the validated filtered buyout-boundary cache, but after the first positive-buyout page is known it scans **every positive page for that rule**, up to a hard configurable cap. It remembers the best qualifying offer by:
1. lowest buyout / stack count;
2. lower total buyout as tie-breaker.

Only after the full rule scan completes does the addon revalidate the selected auction and, in LIVE mode, consider buying it.

Default hard cap: 100 pages per rule (5000 rows). `/avm pages N` now controls this WATCH page cap.

## Persistent WATCH GUI

Open the Auction House and press **AVM WATCH**, or use:

`/avm gui`

The panel exposes 16 persistent rule slots:

- **ON** — rule enabled.
- **Item** — server query text.
- **Partial** — OFF means exact local item-name match; ON means substring match.
- **Max/unit** — required maximum copper/silver/gold price per item.
- **Max total** — optional whole-auction ceiling; 0 means unlimited.
- **Min** — minimum stack size.
- **Max** — maximum stack size; 0 means unlimited.

Money fields accept values such as `4g50s`, `18s`, `25c`, or a plain integer in copper.

Editing any rule immediately disarms LIVE. If an AH result was already in flight, that result is consumed but ignored as stale before scanning restarts with the new rule set.

Existing slash commands remain supported and use the same persistent rule table.

## Rule routing

Empty/disabled/invalid slots are skipped. A rule is scan-active only when:
- ON is enabled;
- Item is non-empty;
- Max/unit is greater than zero.

LIVE cannot be armed without at least one active rule.

The GUI and slash commands share the same SavedVariables table `AVM_DB.rules`.

## Purchase safety

Default mode is DRY-RUN. LIVE is session-only and is forced OFF on addon load/reload, AH close, `/avm off`, rule edits, and reset.

For each rule:
1. find or verify the first positive-buyout page;
2. scan all positive pages (bounded by WATCH page cap);
3. remember global best unit-price candidate;
4. emit `WATCH_BEST`;
5. re-query the source page plus adjacent filtered pages;
6. require the same exact auction signature, including item-link key when available;
7. only then may the single guarded `PlaceAuctionBid` path run.

If the best offer moved/disappeared before revalidation, `WATCH_RACE` is logged and no buy is sent.

DRY-RUN revalidates the best candidate, emits `DRYRUN_BEST`, then rotates to the next active rule.

LIVE additionally:
- excludes candidates that currently exceed wallet or remaining session budget during best-offer selection;
- rechecks wallet immediately before purchase;
- allows only one buy transaction pending;
- uses exact money delta as positive confirmation evidence;
- treats timeout as UNKNOWN, never success;
- pauses further live purchases during UNKNOWN_HOLD;
- respects session spend and purchase-count limits;
- auto-disarms when the confirmed purchase-count limit is reached.

## MarketScan / PriceDB

The same serialized scheduler owns whole-market scans. MarketScan pauses WATCH scanning while it owns the AH query channel.

Whole-market snapshots keep per-item:
- auction count;
- unit count;
- min / p25 / median / p75 / max unit price;
- listing-average and quantity-weighted unit price;
- net decrease in listed units versus prior snapshot.

Net decrease is a turnover proxy, not proof of executed sales; listings may also expire or be cancelled.

AutoMarket has retry backoff after failures and LIVE is blocked while MarketScan owns or requests the scheduler.

## Commands

Scanner / WATCH:
- `/avm on`
- `/avm off`
- `/avm live on`
- `/avm live off`
- `/avm status`
- `/avm gui`
- `/avm list`
- `/avm del N`
- `/avm pages N` (WATCH full-scan page cap, 1..100)
- `/avm budget 100g`
- `/avm maxbuys 1`
- `/avm add exact;Black Lotus;60g;120g;1;20`
- `/avm add partial;Lotus;60g;120g;1;20`

Market data:
- `/avm market start`
- `/avm market stop`
- `/avm market status`
- `/avm market item Black Lotus`
- `/avm market auto 60`
- `/avm market retention 24`
- `/avm market clear`

## 0.8 diagnostics

New counters/status fields:
- `watchPages`
- `watchBest`
- `watchCaps`
- `watchRaces`
- active rule count, slot, current scan page and pages scanned.

Important log markers:
- `WATCH rule=...` — full positive-page scan starts.
- `WATCH_BEST` — best unit-price candidate after the full rule scan.
- `DRYRUN_BEST` — revalidated dry-run result.
- `WATCH_RACE` — candidate changed before revalidation; no buy sent.
- `WATCH_CAP` — query exceeded configured page cap.
- `BUY_SENT`, `CONFIRMED`, `UNKNOWN` — guarded V2 transaction state.

## Recommended test order

1. Leave LIVE OFF.
2. Open WATCH and configure exactly one narrow rule.
3. Use a known item such as Black Lotus with a conservative Max/unit.
4. Enable Scanner.
5. Confirm pages progress across the entire filtered result set and one `WATCH_BEST` appears only after the final page.
6. Confirm `DRYRUN_BEST` matches the best unit-price offer.
7. Only then set `/avm maxbuys 1`, a small budget, and arm LIVE for one controlled purchase.

## vMaNGOS reference

Server reference used by the project:
`vmangos/core` development commit `464179081673cfd240f7ffe7f0daf96bca0b5a70`.

Current repository/runtime evidence and exact in-game tests remain authoritative over assumptions from other WoW versions.


## WATCH UI commit hardening (0.8.1)

Gameplay evidence showed the WATCH panel displaying a 3g Max/unit and 3g Max total while the running scanner status still carried a best candidate around 3g98s. The engine-side candidate filter already rejects unit/total prices above the committed rule, so the UI commit path is hardened:

- each row callback captures an explicit stable rowIndex;
- text edits commit immediately to AVM_DB instead of depending only on Enter/focus loss;
- programmatic refresh is guarded so SetText does not recursively rewrite rules;
- status displays the committed Max/unit and Max total currently used by the scanner.

Any rule edit continues to disarm LIVE and invalidate/restart stale WATCH work.


## LIVE no-op rule commit fix (0.8.2)

A gameplay LIVE test produced DRYRUN_BEST after LIVE had been armed. The WATCH editor commits fields both while typing and again on focus loss. SetRule previously treated every commit as a real rule edit, even when every normalized field value was unchanged, and avm_rule_changed intentionally disarms LIVE.

0.8.2 makes semantically identical SetRule calls a no-op. Real rule changes still disarm LIVE and restart/invalidate stale WATCH work. Clicking LIVE after finishing an edit therefore cannot be cancelled by a redundant focus-loss commit of the same values.


## Max-stack=1 early stop (0.8.3)

For vMaNGOS filtered browse results, total buyout is ordered ascending. When a WATCH rule has Max stack exactly 1, every qualifying auction has unit price equal to total buyout. Once a qualifying candidate has been found on a scanned page, no later page can contain a cheaper qualifying unit-price offer.

0.8.3 therefore finalizes WATCH_BEST immediately after the first page containing a qualifying candidate for Max=1 rules. It still revalidates the selected auction before DRY-RUN/LIVE BUY. Rules allowing stacks larger than 1 keep the full positive-page scan because a higher-total larger stack can still have a lower unit price.

Diagnostic:
- WATCH_EARLY_STOP ... reason=maxStack1
- /avm status counter watchEarly


## Vendor Arbitrage V1 (0.9)

Vendor Arbitrage is a single-scheduler mode inside AuxVmangos. It scans the cheapest global positive-buyout pages on vMaNGOS and compares each auction buyout to the Vanilla vendor sell value for the exact item id.

Defaults:
- DRY-RUN: LIVE is automatically disarmed when VENDOR starts.
- minimum expected vendor profit: 5s
- maximum auction buyout: 1g
- pages per cycle: 10
- existing session budget and maxbuys still apply.

Commands:
- /avm vendor start
- /avm vendor stop
- /avm vendor status
- /avm vendor minprofit 5s
- /avm vendor maxbuyout 1g
- /avm vendor pages 10
- /avm live on

A qualifying opportunity is reported as VENDOR_BEST and then revalidated before VENDOR_DRYRUN or BUY_SENT. LIVE uses the same confirmed money-delta transaction state that already passed gameplay testing for WATCH. Expected vendor profit is based on the embedded Vanilla 1.12 vendor-value table; custom realm price overrides are not yet learned in V1.


## Vendor HOT + SWEEP (0.10)

Vendor Arbitrage no longer rechecks only the same cheapest pages forever.

Each verified boundary cycle now has two segments:
- HOT: the first 10 positive-buyout pages by default. This revisits the freshest/cheapest market area every cycle.
- SWEEP: a persistent 25-page chunk after HOT. The SWEEP cursor is stored in SavedVariables and advances between cycles instead of returning to the first page.

After a SWEEP chunk, the bot returns to HOT, re-verifies the cached positive-buyout boundary, then resumes the next SWEEP chunk. This gives frequent cheap-page coverage while progressively exploring the deeper AH.

The existing maxBuyout is still a hard risk bound. Because vMaNGOS pages are ordered by total buyout, if the minimum positive buyout on a page is already above maxBuyout, VENDOR_PRICE_CEILING stops deeper work for that pass: later pages cannot qualify.

Defaults:
- HOT pages: 10
- SWEEP chunk: 25
- minimum vendor profit: 5s
- max buyout: 1g
- LIVE still starts OFF and reuses the guarded revalidation/purchase transaction.

Commands:
- /avm vendor hotpages 10
- /avm vendor sweeppages 25
- /avm vendor sweepreset
- /avm vendor status

Diagnostics:
- VENDOR HOT pages=A-B
- VENDOR SWEEP pages=A-B pass=N
- VENDOR_PRICE_CEILING ...
- VENDOR_BEST segment=HOT|SWEEP ...
- VENDOR_HOT_NONE / VENDOR_SWEEP_NONE


## Vendor FAST SEEK + report diagnostics (0.11)

0.10 proved that progressive linear SWEEP works, but gameplay evidence showed page ~71 still around ~2s total buyout. Walking hundreds of pages to reach tens of silver or gold is therefore too slow for a money-first workflow.

0.11 keeps the HOT pages and replaces the active linear SWEEP path with FAST SEEK:
- build a price ladder bounded by maxBuyout (5s, 10s, 25s, 50s, 1g, 2g, 5g, 10g as applicable);
- binary-search the vMaNGOS total-buyout ordered page range for each target;
- scan only a small radius around the located page (default +/-1 page);
- re-use the unchanged Vendor V1 candidate, revalidation, budget, maxbuys and guarded LIVE transaction path;
- return to HOT after the seek ladder completes.

Diagnostics are retained in a bounded SavedVariables ring (80 AVM messages plus a compact current-state table). The updater report can include this snapshot. WoW writes SavedVariables on UI reload/logout/client exit, so a report sent while the game is still running may show the most recent flushed snapshot rather than the current in-memory tick.

Commands:
- /avm vendor seekradius 1
- /avm vendor targets

Legacy sweeppages/sweepreset commands remain harmless but report that FAST SEEK is active.
