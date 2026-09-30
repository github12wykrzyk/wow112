# AuxVmangos 0.8.3 unified market bot + WATCH sniper

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
