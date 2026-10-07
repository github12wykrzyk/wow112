# AH Vendor/DE + canonical history integration

Status: integration candidate. Formal canonical AH branch remains `dev/windows-ah-canonical` until explicit promotion. This document records the contract implemented on `feature/ah-history-vendor-de-integration`.

## Non-negotiable safety boundary

History is observational. It may fail, lag, be incomplete, or be absent without opening a BUY path. BUY still requires the existing LIVE gate and exact auction revalidation. An uncertain mutation is never automatically retried. `WOW112_SHARED_HISTORY_SHADOW_CSV` is read only for comparison logs; it does not feed route selection, risk gates, queue ordering, purchase limits, or the mutation primitive.

## One-session capture

The Vendor/DE process uses its existing authenticated world session. No history login is created.

The same `SMSG_AUCTION_LIST_RESULT` response is observed before the unified scanner deduplicates auction IDs. Three scopes are stored separately:

- `full_market`: pages from `poc08-unified-full-ah`.
- `targeted_item`: named DE-material queries.
- `revalidation_window`: exact/fresh target checks immediately before a potential mutation.

Page writes go through a bounded non-blocking queue to a writer thread. Queue saturation or storage failure marks/disables capture and is logged, but does not return an error into the trading scan. Finalization waits only for a bounded acknowledgement; interrupted `.partial` segments remain recoverable by the existing history recovery tooling.

## Market identity v2

Each new capture carries:

- `server_id`: `WOW112_SERVER_ID` when set, otherwise the auth endpoint used by the session;
- `realm_id`: authenticated numeric realm id plus realm name;
- `ah_pool`: `WOW112_AH_POOL_ID` when set, otherwise the observed auction-house id;
- `market_epoch`: `WOW112_MARKET_EPOCH`;
- `identity_status`: `verified` only when `WOW112_MARKET_IDENTITY_VERIFIED=YES` and the required identity fields are present.

This is deliberately fail-closed. An unknown epoch or unverified identity keeps the scan diagnostic-only; the code does not guess that two sessions belong to the same market epoch.

## Versioned quality rule

`ah-quality-v2.0` derives quality from the canonical `events/scans/observations` SQLite tables and writes only projections (`market_identity_v2`, `scan_quality_v2`). It does not create a competing history store.

A scan is not decision-eligible when, among other inherited reasons, it is incomplete, partial-scope, has incomplete/unverified market identity, has conflicting auction identity, has a suffix-to-prefix pagination overlap, or has no terminal page. Historical views are cutoff-aware: scans ending after the evaluated decision time are invisible.

## Preserved full-scan replay: facts

Replay of preserved scan `1791374096233346900-8236` produced:

- 1,154 pages;
- 57,656 raw observations;
- 57,160 unique auction IDs;
- 496 duplicate observations;
- 496 duplicated auction IDs, each observed twice;
- 229 adjacent page boundaries with overlap;
- all 496 duplicates occur across adjacent pages;
- on all 229 overlapping boundaries the repeated auctions are exactly a suffix of page N and the prefix of page N+1;
- server total: first 57,548, last 57,656, minimum 57,548, maximum 57,700;
- terminal page: 6 records;
- no duplicate changed its checked auction identity fields.

Therefore `ah-quality-v2.0` classifies this scan as `diagnostic_only`, including `pagination_suffix_prefix_overlap` and the pre-existing identity deficiencies.

## Interpretation: fact vs hypothesis

Fact: page boundaries moved during the scan. Fact: deduplicating the 496 repeated rows yields 57,160 unique auctions but does not prove the market was completely observed. Fact: total-count drift alone is insufficient because overlaps also occur at transitions where the advertised total does not explain the exact boundary movement.

Hypothesis: insertions, removals, sales, cancellations, and/or server-side reordering during a roughly five-minute scan caused the moving windows. The preserved data cannot identify which mechanism caused each shift and cannot infer the exact number of auctions missed. Disappearance from later observations is not treated as proof of sale.

## Shared DE history view and shadow comparison

`history_quality_v2.py` builds a cutoff-safe view from quality-v2 eligible full-market scans, with observation time, age/freshness, observed listings and units, price-depth percentiles, scan coverage, confidence, and source identity provenance.

`export_de_shadow_csv.py` filters that canonical projection to the 24 Vanilla disenchant materials and exports `item_id,unit_copper,view_id,cutoff_ms,ruleset`. The unified engine can read it through `WOW112_SHARED_HISTORY_SHADOW_CSV` and logs, per DE-valued item:

- current `safe_de_ev`;
- history-backed DE EV using the same outcome model;
- delta;
- source `view_id`;
- `decision_unchanged=YES`.

The history-backed value is not used for BUY in this stage.

## Offline generation

Evaluate all scans and quality:

```text
python src/AhHistoryTerminal/history_quality_v2.py evaluate <history.sqlite>
```

Export a time-safe DE shadow projection:

```text
python src/AhHistoryTerminal/export_de_shadow_csv.py <history.sqlite> <market_id> <output.csv> --cutoff-ms <decision_time_ms>
```

For a terminal run that should capture history, set a stable writable `WOW112_AH_HISTORY_CAPTURE_DIR`. To make new full-market scans eligible rather than diagnostic-only, configure and verify the real market epoch and identity (`WOW112_MARKET_EPOCH`, optional stable `WOW112_SERVER_ID` / `WOW112_AH_POOL_ID`, then `WOW112_MARKET_IDENTITY_VERIFIED=YES`). For shadow comparison set `WOW112_SHARED_HISTORY_SHADOW_CSV` to an exported file. None of these variables enables LIVE BUY.

## Promotion blockers

History must remain shadow-only until enough verified, quality-v2 eligible scans exist to quantify stability across time; material-view confidence/age thresholds are calibrated on real data; seller/variant identity is deliberately resolved; replay/backtests show no future leakage and acceptable false-positive economics; and a separate reviewed change explicitly changes decision logic. No such promotion is part of this integration stage.
