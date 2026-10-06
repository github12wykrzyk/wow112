# HANDOFF — TELE08 B WHISPER PARSER

## Branch and validated SHA

- Branch: `feature/tele08-b-whisper-parser-v1`
- Authoritative base: `04e8337fec7ba0d76c8267e03c1324f7039f2487`
- Validated parser/source SHA after rustfmt: `ef61231a16b367cd1a1c7153a8ab2576db6dae11`
- No merge into `main`, `parallel`, TELE07, or TELE06 branches was performed.

## Files

- `probes/Wow112HeadlessAndroid/src/lib.rs`
- `probes/Wow112HeadlessAndroid/src/tele08_whisper_parser.rs`
- `probes/Wow112HeadlessAndroid/src/tele08_whisper_parser_tests.rs`
- `.github/workflows/tele08_b_whisper_parser.yml`
- `runtime/parallel_tasks/tele08-b-whisper-parser-v1.json`
- `HANDOFF_TELE08_B_WHISPER_PARSER.md`

No TELE06A/06B/06C ritual, portal, click, movement, or existing `world_tele.rs` mutation path was changed.

## Public API

Primary API:

```rust
classify_whisper(
    observation: &WhisperObservation,
    config: &ParserConfig,
) -> WhisperClassification
```

Reusable types/helpers:

- `WhisperObservation`
- `WhisperClassification`
- `WhisperIntent`
- `DestinationKey`
- `DestinationAlias`
- `FuzzyRule`
- `ParserConfig`
- `ParserConfig::with_destination_alias(...)`
- `normalize_whisper_text(...)`
- `request_fingerprint(...)`
- `destination_alias_map(...)`

`request_fingerprint` is deterministic and intentionally excludes the observation timestamp so Track C can use it for duplicate suppression.

## Behavior implemented

- Intents: `SummonRequest`, `InviteRequest`, `PresenceReady`, `DestinationQuery`, `GenericPositive`, `CompetitionMessage`, `Irrelevant`, `Unknown`.
- Case/whitespace/harmless-punctuation normalization while preserving raw text and leading `+` semantics.
- Leading `+` is a positive request signal; incidental mid-sentence `+` is not.
- Explicit regressions include `+`, `+ hyjal`, `inv pls`, `invi`, `I need one`, `here`, `winterspring pls`.
- Default configured destinations are Hyjal, Winterspring, and Azshara.
- Destination aliases are injected through `ParserConfig`; this module is not the canonical destination registry.
- Feralas is not available by default; `do you have feralas?` is a `DestinationQuery` with no destination rather than fake availability.
- Hydraxian/Hydraxian Waterlords is not available by default and can be injected as legacy vocabulary.
- Bounded fuzzy handling covers `invi -> inv` with explicit evidence; broad fuzzy matching is intentionally avoided.
- Competition classification is configurable, returns evidence/reason, and performs no blacklist action.
- Low-confidence operational hints become `Unknown`, never silently `SummonRequest`.
- Unknown classifications preserve sender, raw text, normalized text, timestamp, destination/context signal, reason, and evidence for Track E reporting.

## Validation

Dedicated workflow: `TELE08 B whisper parser`.

Successful validation run: `37541260400`.

On the post-rustfmt workspace committed as `ef61231a16b367cd1a1c7153a8ab2576db6dae11`:

- `cargo fmt --manifest-path probes/Wow112HeadlessAndroid/Cargo.toml --all -- --check` — PASS
- `cargo check --manifest-path probes/Wow112HeadlessAndroid/Cargo.toml --lib` — PASS
- `cargo test --manifest-path probes/Wow112HeadlessAndroid/Cargo.toml --lib` — PASS

Test coverage includes 12 Rust test functions, a 62-case positive operational matrix, a 41-case negative/non-actionable matrix, typo and punctuation/case regressions, plus-policy boundaries, configurable/unknown destinations, competition rules, Unknown preservation, and deterministic fingerprints.

## TELE08 integration points

- Listener/decoder: construct `WhisperObservation` from the decoded whisper and call `classify_whisper`.
- Track D: inject canonical destination aliases into `ParserConfig`; do not copy the canonical registry into this module.
- Track C: consume intent/destination and `request_fingerprint` for queue admission and duplicate suppression.
- Track E: consume `Unknown` classifications and their raw/normalized text, timestamp, reason, and signals for unknown-whisper dump/reporting.
- Action layer: remains downstream. This module emits classification data only and cannot invite, summon, cast, click, move, mutate party state, persist queue state, or blacklist.

## Limitations

- No live WoW/server validation was performed or claimed; Track B is pure deterministic logic and contract-tested offline in CI.
- Parser config is currently an in-memory Rust structure without a serde dependency. External config serialization/loading should be owned by the integration/config layer if required.
- Competition detection is deliberately conservative and rule/pattern driven; later tuning should use Unknown dump evidence rather than broad fuzzy matching.
- The repository-wide canonical integration preflight is not the acceptance gate for this track because this task explicitly branches from the supplied TELE07 SHA and forbids merge/integration. Dedicated Track B Rust CI is the validation gate used here.
