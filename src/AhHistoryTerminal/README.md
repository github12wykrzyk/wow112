# AH History Terminal V0

An independently executable, read-only terminal collector and local SQLite
worker. Uses the canonical Rust auth/world/read-only auction discovery chain.
The crate does not include the BUY module or any BUY entrypoint.

This is a tested first prototype, not a deployed central database or a complete
implementation of the V1 architecture. Live server scanning is unverified.

## Build and autonomous offline test

From repository root:

```sh
cargo build --locked --release --manifest-path src/AhHistoryTerminal/Cargo.toml
python src/AhHistoryTerminal/test_autonomous.py src/AhHistoryTerminal/test-results
```

The test starts a loopback fixture server, launches the compiled Rust terminal,
feeds 60,000 auctions using canonical 64-byte record offsets, imports the actual
capture into SQLite, checks duplicate/conflict handling, bundle restoration,
hash corruption, page truncation, count=0, process kill/recovery, cutoff/market
isolation, import transaction crash and multiple observers. Fixture framing is
test-only; it does not validate SRP, encrypted world transport or live pagination.
Fixture observations use an isolated `fixture:` market namespace.

Linux binary: `src/AhHistoryTerminal/target/release/wow112-ah-history`.
Windows binary has `.exe`; CI also builds and runs the suite on Windows x86.
Only completed CI reports are evidence for their respective platform.

## Capture live

Configure the existing account/character near an auctioneer using environment
variables; keep passwords and the HMAC secret outside Git. Required variables:

- `WOW112_ACCOUNT`, `WOW112_PASSWORD`, `WOW112_CHARACTER`
- `WOW112_MARKET_ID` (stable server/realm/pool/epoch identity; no `fixture:` prefix)
- `WOW112_PRODUCER_ID`
- `WOW112_OWNER_HMAC_KEY` (at least 32 bytes; consistent per market)

Optional connection overrides are `WOW112_AUTH_ADDR`, `WOW112_WORLD_ADDR`,
`WOW112_REALM_INDEX` (default 1), and `WOW112_AH_FULL_SCAN_MAX_PAGES`
(default 2048, maximum 4096). The wire build and world build are inherited from
the canonical modules; they are not changed by this collector.

```sh
src/AhHistoryTerminal/target/release/wow112-ah-history live capture
python src/AhHistoryTerminal/history_worker.py ingest history.sqlite capture/SCAN.ndjson
python src/AhHistoryTerminal/history_worker.py view history.sqlite MARKET_ID
python src/AhHistoryTerminal/history_worker.py export history.sqlite bundles
python src/AhHistoryTerminal/history_worker.py restore restored.sqlite bundles/BUNDLE_HASH
```

One invocation authenticates, opens AH, captures one full listing and exits.
It performs no purchases, vendor/de actions or item query valuation. Full pages
are retained, including no-buyout and expensive listings. It serializes queries;
on timeout it stops rather than guessing response/page correlation.

## Recovery and limits

Capture uses a `.partial` file until its closing ScanFinished record is synced
and atomically renamed. Normal failure closes a diagnostic-only aborted scan;
hard process kill leaves `.partial` for explicit worker recovery:

```sh
python src/AhHistoryTerminal/history_worker.py recover capture/SCAN.ndjson.partial
```

The worker validates the entire segment before its import transaction.
Duplicate segment IDs are no-op; changed payloads under an existing ID fail.
Partial scopes, incomplete/truncated runs, identity conflicts and mismatched
observed/advertised counts cannot feed full-market statistics. The V0 count
rule is deliberately strict pending live pagination calibration. Views preserve
observation times and do not claim actual sales or calibrated liquidation prices.

V0 limitations: page capture is synchronous with a buffered local file, rather
than the final asynchronous bounded spool; bundles are capped at 128 MiB raw;
there is no cloud ingest, GitHub publisher/outbox, automatic retention, periodic
scheduler, item variant valuation or DE decision integration. Variant fields are
explicitly unknown. No active PriceBook/BUY behavior is altered. Bundle files
contain pseudonymized market observations; no raw network payload is persisted.
Existing inherited auth diagnostics can contain account/character metadata;
do not publish live diagnostic logs as data bundles.

Publisher integration and live validation are separate next stages. This module
is additive under `src/`; canonical terminal sources are consumed without edits.
