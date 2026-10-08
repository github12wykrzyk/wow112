# AH Market Maker V1

Branch: `feature/ah-market-maker-v1`
Base: `feature/ah-auction-lifecycle-v1`.

## Goal

For each owned auction, compare exact copper-per-unit price against the live external market and choose one of four outcomes:

- `Keep` — already competitive or not actionable.
- `BlockedFloor` — lowering price would cross a configured safety floor.
- `Undercut` — guarded cancel/recover/split/repost at the largest integer unit price strictly below the current external floor (effectively `lowest rational unit buyout - 1 copper` where possible).
- `ClearThenRelist` — buy a small, shallow cheap prefix only when the acquired stock itself is profitable after AH cut and hard spend/unit/ROI/jump limits, then re-scan before any next clear buy and before relisting.

The engine ignores the user's own auctions when determining external competition and never cancels an auction with an active bid. Global AH count drift is diagnostic only; CLEAR requires two complete consecutive scans that produce the same item-local economic decision before each BUY.

## Execution

`WOW112_LIFECYCLE_ACTION=marketmaker`

Default `WOW112_MM_MODE=audit` performs no mutation. Live requires both:

- `WOW112_LIFECYCLE_CONFIRM=YES`
- `WOW112_MM_CONFIRM=YES`

Live execution reuses:

- canonical guarded BUY primitive,
- Lifecycle owner list / buybox identity,
- guarded CANCEL,
- guarded MAIL TAKE,
- guarded POST,
- the same host-local durable mutation coordinator.

A clear BUY is preceded by two complete item-local confirmation scans and followed by fresh rescans before a next BUY. A repricing chain is:

`fresh depth -> guarded CANCEL -> unique return mail -> TAKE ITEM -> split stack to isolated units -> fresh depth -> POST units`

No automatic retry is allowed after an uncertain mutation send.

## Core settings

| Variable | Default | Meaning |
|---|---:|---|
| `WOW112_MM_MODE` | `audit` | `audit` or `live` |
| `WOW112_MM_MAX_PAGES` | 4096 | full-market scan cap |
| `WOW112_MM_MAX_ACTIONS` | 10 | bounded live decisions per run |
| `WOW112_MM_MAX_CLEAR_BUYS` | 5 | max sequential clear buys in one clear chain |
| `WOW112_MM_MAX_CLEAR_SPEND` | 10000c | max planned clear spend |
| `WOW112_MM_MAX_CLEAR_UNITS` | 5 | max cheap units in clear prefix |
| `WOW112_MM_CLEAR_MIN_PROFIT` | 100c | minimum acquired-stock profit after AH cut |
| `WOW112_MM_CLEAR_MIN_ROI_BPS` | 1000 | minimum clear ROI, 10% |
| `WOW112_MM_CLEAR_MIN_JUMP_BPS` | 1000 | minimum recovered price-level jump, 10% |
| `WOW112_MM_AH_CUT_BPS` | 500 | 5% AH cut used in clear economics |
| `WOW112_MM_DEFAULT_FLOOR_UNIT` | 1c | absolute unit floor fallback |
| `WOW112_MM_FLOORS` | empty | explicit item floors, e.g. `10940:350;16202:12000` |
| `WOW112_MM_MIN_PRICE_BPS_OF_OWN` | 0 | optional legacy guard relative to current owned unit price; `0` disables it |
| `WOW112_MM_MAX_POST_UNITS` | 20 | hard single-unit repost limit per recovered stack |
| `WOW112_MM_MINUTES` | 120 | 120 / 480 / 1440 |

## Safety notes

- Ordinary repricing no longer inherits an implicit 80%/95% floor from the stale owned listing. Explicit/economic floors remain authoritative; the old-price percentage guard is opt-in only.
- Market clearing does not require the entire 50k+ AH total to remain unchanged. Instead, before every CLEAR BUY, two complete consecutive scans must yield the exact same decision for that specific item's depth.
- Each actual BUY is still freshly validated by the canonical BUY primitive after the item-local confirmation.
- After every clear BUY, the next decision is rebuilt from new scans and cumulative spend/unit limits continue from the already used budget.
- The policy does not count hypothetical profit on already-owned stock when deciding whether to clear; purchased stock must be profitable on its own after AH cut.
- Repricing recomputes external price after cancel/mail/split before POST.
- A malformed unrelated compressed object update is logged and skipped rather than permanently poisoning inventory state. MAIL/SPLIT/POST still require exact fresh GUID/owner/stack deltas, so missing evidence fails closed.
- If a returned/purchased mail attachment merges into an existing inventory stack and an exact physical source slot cannot be proven, V1 stops rather than splitting or posting the wrong stack.
- V1 live market-making is restricted to plain item signatures (`[0,0,0]`).
- `UNCERTAIN` remains a hard stop. Restart does not erase `.pending`.

## Validation sequence

1. policy unit tests,
2. canonical integration / BUY-body preservation tests,
3. canonical V4 generator replay,
4. Windows i686 `cargo check` + `cargo test`,
5. Windows PE build artifact,
6. live `audit`,
7. one controlled undercut canary,
8. one controlled shallow-clear canary,
9. repeated run only after reconciliation is clean.
