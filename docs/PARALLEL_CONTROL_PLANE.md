# Parallel Control Plane

This layer extends the existing `runtime/parallel_tasks/*.json` coordination model. It does not replace the experiment ledger, candidate gates, provenance, or the serialized Parallel integration queue.

## Lease model

A task can own a TTL lease with an `owner`, `acquired_at`, `heartbeat_at`, `ttl_seconds`, and explicit scopes. Scopes are restricted to declarations already present in the task:

- `module:<module>`
- `resource:<shared_resource>`

The default TTL is six hours. New feature branches based on a Parallel revision containing `runtime/parallel_control_plane_v1.marker` must hold an active lease while in `coding`, `preflight`, `ready_for_integration`, or `integrating`.

Lease operations:

```text
python tools/parallel_task_state.py lease-claim --task-id <id> --owner <session>
python tools/parallel_task_state.py lease-heartbeat --task-id <id> --owner <session>
python tools/parallel_task_state.py lease-release --task-id <id> --owner <session>
```

A lease may cover all declared task scopes or a safe subset via repeated `--scope`.

## Conflict behavior

Independent feature coding remains parallel. Before preflight and again immediately before integration, the Control Plane checks all fetched `feature/**` task records.

When multiple live leases cover the same scope, ownership is deterministic:

1. oldest live `acquired_at`;
2. branch name;
3. task id.

Only the winning task may pass the conflicting scope gate. No branch is deleted, reset, or rewritten. When a lease expires it stops blocking other tasks.

## Reconciler

`.github/workflows/parallel_control_plane_reconcile.yml` runs hourly and on relevant Parallel infrastructure changes. It fetches live `feature/**` refs and emits:

- tracked feature tasks;
- active and expired leases;
- required leases that are missing;
- scope conflicts and deterministic winners.

The reconciler is intentionally read-only. Cleanup or status mutation is never inferred from time alone.

## Compatibility

Feature branches whose merge-base predates `runtime/parallel_control_plane_v1.marker` are grandfathered. This prevents the rollout from breaking already-running work. Existing task records may omit `lease`.

The task record, lease, and reconciler report are coordination evidence only. Exact-SHA feature preflight, STANDARD/ECONOMY/profile workflows, FINAL_PACKAGE, provenance, `parallel-testpoint`, updater integrity, and gameplay evidence remain authoritative.
