# TELE08 C Request Manager + Queue Engine — Handoff

## Branch and exact implementation

- Repository: `github12wykrzyk/wow112`
- Branch: `feature/tele08-c-request-queue-v1`
- Authoritative base branch: `feature/tele07-stationary-supervisor-v1`
- Authoritative base SHA: `04e8337fec7ba0d76c8267e03c1324f7039f2487`
- Green implementation SHA: `a8f1398729a9d339aa4b14165c1cf766d06365fc`
- Dedicated validation workflow run: `37541031967`
- Validation: `cargo fmt --check`, `cargo check --all-targets`, `cargo test --all-targets` all PASS
- Contract tests: 22 passed, 0 failed

The handoff commit itself is metadata-only and therefore necessarily has a different SHA than the green implementation commit named above. No merge was performed.

## Files added by the implementation

- `.github/workflows/tele08_c_request_queue.yml`
- `probes/Wow112HeadlessAndroid/tele08_request_queue/Cargo.toml`
- `probes/Wow112HeadlessAndroid/tele08_request_queue/src/lib.rs`
- `probes/Wow112HeadlessAndroid/tele08_request_queue/tests/queue_contract.rs`

The engine is an isolated Rust library crate with no external dependencies and no compile/runtime coupling to TELE06/TELE07 WoW packet, ritual, portal, click, movement, socket or credential code.

## Public data contract

### Input

```rust
SummonRequest {
    request_id: String,
    player: String,
    destination: String,
    received_at: Timestamp,
    metadata: BTreeMap<String, String>,
}
```

`Timestamp` is currently a caller-provided `u64`. The caller must use one consistent time unit for `received_at`, dedup window, expiry and command timestamps.

### Lifecycle

```text
Received -> Queued -> Active -> Completed
                     |      
                     +-> Failed -> Queued       (RetryableSafe only)
                     +-> Failed                 (Terminal)
                     +-> BlockedReconciliation  (UncertainDoNotReplay)

Queued -> Cancelled
Queued -> Expired
```

`BlockedReconciliation` is fail-closed and is never automatically replayed.

### Failure disposition

```rust
FailureDisposition::RetryableSafe
FailureDisposition::Terminal
FailureDisposition::UncertainDoNotReplay
```

Semantics:

- `RetryableSafe`: releases the active resource and requeues the same request at the front of its destination queue. It does **not** auto-activate; the orchestrator must explicitly call `activate_next` again.
- `Terminal`: releases the active resource and leaves the request terminal in `Failed`.
- `UncertainDoNotReplay`: releases the active resource and moves the request to `BlockedReconciliation`; it never auto-requeues or auto-reactivates.

## Queue/resource rules implemented

- FIFO is preserved inside each destination queue.
- `ResourceKey` separates destination identity from exclusive execution-team identity.
- Multiple destinations may map to one exclusive resource/team.
- One destination may map to multiple resource/teams.
- At most one active job may occupy a given exclusive resource.
- Cross-destination selection for a shared resource is deterministic: destination queue heads are compared by `(received_at, sequence, request_id)`.
- Same player + destination inside the configured dedup window is suppressed and refreshes `last_seen_at` while preserving the original request identity and queue position.
- The same player may hold distinct requests for different destinations.
- An exact reused `request_id` with a conflicting player or destination is rejected fail-closed.
- Unknown/unconfigured destinations are rejected fail-closed.
- Queued requests support cancellation by request ID or player+destination.
- Expiry applies only to queued requests and uses refreshed `last_seen_at`.
- All lifecycle transitions are appended to an audit log.
- Query APIs do not mutate queue state.

## Public QueueEngine API

Core commands:

```rust
QueueEngine::new(config)
engine.enqueue(request)
engine.cancel(selector, now)
engine.activate_next(resource, now)
engine.complete(active_job_id, now)
engine.fail(active_job_id, disposition, now)
engine.expire(now)
engine.snapshot()
QueueEngine::restore(snapshot, now)
```

Queries:

```rust
engine.request(request_id)
engine.position(request_id)
engine.queued_count_by_destination(destination)
engine.active_job_by_resource(resource)
engine.next_eligible_request(resource)
engine.audit_log()
engine.validate_invariants()
```

## Semantic events

The engine returns typed events, not human-log text:

- `RequestAccepted`
- `RequestRejected`
- `DuplicateSuppressed`
- `RequestQueued`
- `RequestCancelled`
- `RequestExpired`
- `JobActivated`
- `JobCompleted`
- `JobFailed`
- `JobBlockedUncertain`
- `QueuePositionChanged`

These are intended to map cleanly into the wider TELE08 event/command vocabulary without scraping logs.

## Snapshot / restore boundary

`QueueSnapshot` is a typed in-memory persistence boundary. No database and no serialization/storage backend are introduced in Track C.

Restore behavior:

- `Queued` requests remain queued with deterministic ordering.
- snapshot invariants are validated before restore is accepted.
- any previously `Active` job is removed from active resource ownership and converted to `BlockedReconciliation`.
- restore emits `JobBlockedUncertain` for each previously active job.
- a crashed active mutation therefore cannot silently replay after orchestrator restart.

## Invariants enforced/tested

- a request never appears simultaneously in conflicting live structures/states;
- maximum one active job per exclusive resource;
- every queued record exists exactly in its matching destination queue;
- every active record exists exactly once in resource ownership;
- completed/cancelled/expired/terminal-failed/blocked records are not in live queue/resource structures;
- uncertain active jobs never auto-replay;
- duplicate suppression preserves original request identity;
- deterministic behavior does not depend on `HashMap` iteration order (`BTreeMap`/ordered tie-breaks are used).

## Test coverage

The 22 contract tests cover:

- FIFO 1/2/3;
- two independent destinations;
- duplicate same player/destination;
- same player/different destination;
- repeated request refresh semantics;
- cancellation first/middle/last;
- cancellation by player+destination;
- expiry;
- safe retry;
- terminal failure;
- uncertain failure never replays;
- crash/restore queued;
- crash/restore active fail-closed;
- queue/query non-mutation and positions;
- resource locking;
- one destination with multiple teams;
- deterministic selection independent of mapping insertion order;
- unknown destination rejection;
- exact request-ID conflict rejection;
- completed/cancelled/terminal never auto-reactivate;
- audit transition sequence;
- deterministic 2,000-step randomized invariant sequence.

## B -> C integration contract

Track B (or any future whisper/classification module) should hand Track C a structured request only:

```rust
let request = SummonRequest {
    request_id,
    player,
    destination,
    received_at,
    metadata,
};

let outcome = queue.enqueue(request);
```

Track C owns acceptance/rejection, deduplication, queue identity/position, expiry and scheduling. Track B should not create a second parallel queue or infer queue state from chat wording/log output.

## C -> future orchestrator integration contract

1. Orchestrator resolves an available execution `ResourceKey` from config/state.
2. It may inspect `next_eligible_request(resource)` without mutation.
3. It calls `activate_next(resource, now)` to acquire the exclusive resource and receives `JobActivated { job }`.
4. `job.job_id`, `job.request_id`, `job.destination`, `job.resource`, and `job.attempt` become the typed correlation keys for the downstream summon job.
5. The future orchestrator maps `JobActivated` to its `StartSummonJob` command and runs invite/party/ritual/portal/customer-confirmation logic outside Track C.
6. On confirmed success, it calls `complete(job_id, now)`.
7. On a known safe failure before an uncertain mutation, it calls `fail(job_id, RetryableSafe, now)`.
8. On a known terminal business failure, it calls `fail(job_id, Terminal, now)`.
9. On any ambiguous post-mutation/network outcome where replay could duplicate an irreversible action, it calls `fail(job_id, UncertainDoNotReplay, now)`.
10. Only an explicit later reconciliation policy may decide what to do with `BlockedReconciliation`; Track C never silently replays it.

TELE07 network/session recovery remains separate from these business-job retry decisions.

## Destination/resource configuration example

```rust
let mut config = QueueConfig::new(dedup_window, expiry);
config
    .map_destination_resource("Hyjal", ResourceKey::from("team-a"))
    .map_destination_resource("Azshara", ResourceKey::from("team-a"))
    .map_destination_resource("Winterspring", ResourceKey::from("team-b"));
```

Future destinations should be added by data/config mapping rather than scheduler branching logic.

## Limitations / intentionally out of scope

- No WoW packet encoding, sockets, credentials, login/session recovery, party mutations, ritual opcodes, portals, movement or customer `0x02AB` parsing.
- No DB and no persistent storage implementation; only typed snapshot/export + restore semantics are provided.
- No wall-clock implementation; timestamps are injected by the caller for deterministic offline tests.
- No automatic blocked-job reconciliation policy.
- No UI or chat wording.
- `RetryableSafe` requeues at the front to preserve the failed active request's prior service precedence; activation is still explicit.

## Verification result

Dedicated workflow `TELE08 C request queue`, run `37541031967`, on exact SHA `a8f1398729a9d339aa4b14165c1cf766d06365fc`:

```text
cargo fmt --check       PASS
cargo check --all-targets PASS
cargo test --all-targets  PASS
22 tests passed, 0 failed
```

Diff audit from authoritative base `04e8337fec7ba0d76c8267e03c1324f7039f2487` to green implementation SHA showed only the four new Track C files listed above, with no TELE06/TELE07 core modifications.
