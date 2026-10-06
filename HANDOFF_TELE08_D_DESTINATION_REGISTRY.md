# HANDOFF — TELE08 D Destination Registry

## Status

- Track: D — destination registry + availability / shard policy
- Branch: `feature/tele08-d-destination-registry-v1`
- Authoritative branch point: `04e8337fec7ba0d76c8267e03c1324f7039f2487`
- Validated implementation SHA: `7b0c9ad3b1de9111af6901cc9dfa26be412e4805`
- Validation workflow: `TELE08 D destination registry`, run `37540942716`
- Validation result: rustfmt PASS, `cargo check --lib` PASS, `cargo test --lib` PASS (13 passed, 0 failed)
- Merge status: NOT MERGED. This branch is intentionally isolated.

## Files

- `probes/Wow112HeadlessAndroid/src/lib.rs`
  - exports `destination_registry`
- `probes/Wow112HeadlessAndroid/src/destination_registry.rs`
  - canonical destination/team schema
  - deterministic alias resolver
  - availability and shard policy
  - typed state-change event
  - alternatives/status APIs
  - config validation and atomic in-memory reload boundary
  - unit/contract tests
- `probes/Wow112HeadlessAndroid/config/tele08_destinations.example.json`
  - human-editable seed registry
- `probes/Wow112HeadlessAndroid/Cargo.toml`
  - adds `serde` + `serde_json`
- `.github/workflows/build_tele08_d_destination_registry.yml`
  - Track-D-only rustfmt gate plus library check/test

No TELE06 ritual, portal, click, movement core, TELE07 supervisor, login/session runtime, queue runtime or whisper runtime was integrated or modified by Track D.

## Schema

### `DestinationId`

Typed canonical destination identifier. Current seeded IDs:

- `azshara`
- `hyjal`
- `winterspring`

### `DestinationDefinition`

Fields:

- `id: DestinationId`
- `display_name: String`
- `aliases: Vec<String>`
- `enabled: bool`
- `execution_team: String`
- `required_clickers: usize`
- `shard_policy: Option<ShardPolicy>`
- `price: Option<PriceMetadata>`
- `metadata: BTreeMap<String, String>`

### `ExecutionTeam`

Fields:

- `id`
- `resource_key`
- typed summoner `RoleAssignment`
- clicker `RoleAssignment[]`

Role assignment supports optional character metadata and an `exclusive` flag. Config validation rejects conflicting exclusive character assignment.

### `ShardPolicy`

Fields:

- `disable_below`
- `reenable_at`
- `allow_unknown`

`reenable_at` implements hysteresis. Validation rejects `reenable_at < disable_below`. A shard policy with `disable_below=0` is rejected; omit the policy when no shard threshold is wanted.

### Availability

Typed states:

- `Enabled`
- `DisabledManual`
- `DisabledLowShards`
- `DisabledUnhealthyTeam`
- `DisabledMaintenance`
- `Unknown`

Every decision also carries a typed `AvailabilityReason`.

### Runtime observation input

`DestinationObservation` contains:

- `shard_count: Option<u32>`
- `manual_override: ManualOverride`
- `team_health: TeamHealth`

Precedence is fail-closed:

1. manual `ForceOff`
2. maintenance override
3. destination config disabled
4. unhealthy/unknown team health
5. shard policy

Manual OFF therefore wins over positive shard/team observations.

## Seeded data

The example registry seeds exactly:

1. Azshara
2. Hyjal
3. Winterspring

Legacy vocabulary is represented as aliases of Azshara, including:

- `hydraxian`
- `hydraxian waterlords`
- `waterlords`
- `waterlord`

`Feralas` is deliberately not configured and resolves to Unknown/None.

The seed does not invent live shard counts, prices, account credentials or concrete character assignments. Price is optional. Character assignments are `null` placeholders pending authoritative runtime wiring.

Each destination currently declares two required clicker roles and a stable resource key:

- `summon/azshara`
- `summon/hyjal`
- `summon/winterspring`

## Alias API

`DestinationRegistry::resolve_destination(input)` is deterministic, case-insensitive and punctuation-friendly by normalizing to lowercase alphanumeric characters.

Examples covered by tests:

- `HYJAL` -> `hyjal`
- `Hydraxian Waterlords!!!` -> `azshara`
- `winter-spring` -> `winterspring`
- `feralas` -> unresolved

Ambiguous normalized aliases are rejected during validation rather than guessed at runtime.

## Availability / shard policy API

Pure policy function:

```rust
evaluate_availability(
    definition: &DestinationDefinition,
    observation: DestinationObservation,
    previous: Option<Availability>,
) -> AvailabilityDecision
```

Important behavior:

- no shard policy + healthy team -> Enabled
- configured shard policy + unknown shard count -> Unknown unless `allow_unknown=true`
- observed count below `disable_below` -> DisabledLowShards
- after low-shard disable, destination remains disabled until count reaches `reenable_at`
- replenishment can therefore automatically transition back to Enabled
- team Unhealthy -> DisabledUnhealthyTeam
- team Unknown -> Unknown
- manual ForceOff -> DisabledManual
- maintenance override -> DisabledMaintenance

`DestinationRegistry::set_observation(...)` returns `Option<DestinationStateChanged>` when the availability enum changes.

## Alternatives / status API

Available for Track E / response-engine consumption:

- `available_destinations()`
- `unavailable_destination_reason(id)`
- `alternatives_for(requested, limit)`
- `destination_status_snapshot()`

Ordering is deterministic because canonical runtime maps are ordered. Alternatives exclude unavailable destinations and the requested destination itself.

This module returns typed data only. It does not generate customer-facing English response text.

## Team/resource API

For Track C consumption:

- `destination(id)`
- `execution_team(id)`
- `resource_key(id)`

The registry validates referenced team existence, non-empty resource keys, nonzero clicker requirements and sufficient clicker roles.

## Reload boundary

Supported boundary:

`parse/load -> validate -> replace in-memory registry`

APIs:

- `reload_json(...)`
- `reload_config(...)`

Replacement fields are constructed and validated before current state is assigned. Invalid JSON/config therefore returns an error without destroying the current valid registry. Existing observations are carried forward only for destination IDs still present in the new valid config.

No filesystem watcher is implemented.

## Validation coverage

Validation rejects:

- duplicate destination IDs
- duplicate execution team IDs
- duplicate team resource keys
- ambiguous aliases after normalization
- missing execution teams
- empty/invalid destination or team IDs
- empty display names
- zero clicker requirements
- clicker requirement greater than exposed team clicker roles
- nonsensical shard thresholds
- empty role/character assignments
- conflicting exclusive character assignments

## Tests

CI validation at `7b0c9ad3b1de9111af6901cc9dfa26be412e4805`:

- rustfmt: PASS
- `cargo check --lib`: PASS
- `cargo test --lib`: PASS
- tests: 13 passed / 0 failed

Test coverage includes:

- seeded destinations
- aliases/case/punctuation
- ambiguous alias rejection
- Feralas unknown
- manual off
- low shards off
- hysteresis + threshold recovery
- unknown shards fail-closed
- unhealthy team
- recovery to enabled with state-change event
- unavailable alternatives exclusion
- deterministic ordering
- invalid reload preserving previous valid state
- invalid thresholds/clicker requirements
- conflicting exclusive role assignment

## TELE08 integration points

### Track B

Consume `resolve_destination(...)` and canonical `DestinationId`. Track B should not maintain a second destination alias dictionary once integrated.

### Track C

Consume `DestinationId`, `execution_team(...)` and `resource_key(...)` for queue/resource ownership. Do not infer execution resources from display names or log text.

### Track E

Consume availability/reason and alternatives APIs. Track E owns customer-facing response text; Track D deliberately does not generate it.

### Shared event direction

Track D provides typed `DestinationStateChanged { destination, old, new, reason }`, designed to map directly into the shared TELE08 event contract.

## Limitations / explicit non-claims

- No WoW login/runtime mutation.
- No whisper sending.
- No queue execution.
- No ritual/click execution.
- No inventory scraping.
- No filesystem watcher.
- **No shard auto-detection.** Shard count is an external observation supplied through `DestinationObservation`; Track D only evaluates the policy.
- No live price discovery; price metadata is optional only.
- No concrete character-to-destination assignments were invented in the seed config.
- No merge into TELE07 or another branch has been performed.
