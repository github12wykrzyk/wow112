# Parallel Control Plane

Legacy name; ordinary integration authority is canonical `main`. This layer is diagnostic, not a hot-path global gate.

## Hot path

```text
current feature only
-> targeted preflight/profile gates
-> optimistic CAS integration against live main
-> atomic main + parallel update
-> routed exact-SHA delivery
```

No normal run enumerates all `feature/**` refs or performs global lease election.

## Integration concurrency

There is **no serialized GitHub pending-slot queue**. Independent integration attempts may run concurrently.

Each attempt:
1. fetches live `main` and verifies `parallel == main`,
2. re-runs branch-local preflight against that live base,
3. creates a local merge commit,
4. atomically pushes the same commit to `main` and `parallel`,
5. on race loss, refetches/revalidates/retries (bounded CAS retries),
6. dispatches exact-SHA delivery only after winning the atomic ref update.

This avoids GitHub concurrency's one-running/one-pending replacement behavior.

## Single-owner delivery

Queued integration pushes with repository `GITHUB_TOKEN`; recursive ordinary push workflows are suppressed. `tools/parallel_ci_dispatch.py` explicitly owns exact-SHA downstream `workflow_dispatch` delivery.

Feature-specific validation must not also start an independent feature `push` build for the same profile. Such duplicate triggers waste runner capacity and create ambiguous CI evidence.

## Leases/reconciler

Leases are optional diagnostic metadata. The reconciler is manual/read-only. Neither is required for ordinary preflight/integration.

## Chat/API discipline

Do not poll CI to produce progress messages. The integration job waits for exact-SHA downstream delivery internally. Chat reads detailed jobs/logs only on failure, unexpected stall, or explicit `check`.
