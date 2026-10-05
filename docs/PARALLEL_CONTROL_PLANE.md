# Parallel Control Plane

This layer is now **diagnostic only**. It no longer gates ordinary feature preflight or integration.

The hot path is deliberately branch-local:

1. fetch the current integration base;
2. validate the current feature's own `runtime/parallel_tasks/*.json` record;
3. validate delivery-profile declarations for the files changed by that feature;
4. run targeted preflight/build checks;
5. serialize only the actual trunk movement through the integration queue;
6. re-run the same branch-local checks against the live base immediately before merge.

No normal feature run fetches or reconciles every remote `feature/**` ref.

## Integration mutex

The authoritative concurrency mechanism for trunk movement is the GitHub Actions concurrency group:

```text
parallel-integration-queue
```

Independent coding and feature preflight remain concurrent. Only integration is serialized. The existing compare-and-swap retry behavior still protects against the integration base moving between validation and push.

## Legacy lease metadata

Task records may still contain a TTL `lease` object (`owner`, timestamps, TTL and scopes). The lease commands remain available for explicit diagnostics or manual coordination:

```text
python tools/parallel_task_state.py lease-claim --task-id <id> --owner <session>
python tools/parallel_task_state.py lease-heartbeat --task-id <id> --owner <session>
python tools/parallel_task_state.py lease-release --task-id <id> --owner <session>
```

These leases are **not required by the normal preflight/integration hot path** and no global winner election is performed before a feature can compile or enter the serialized integration queue.

## Manual reconciler

`.github/workflows/parallel_control_plane_reconcile.yml` is manual (`workflow_dispatch`) only. When explicitly run, it fetches live `feature/**` refs and reports task/lease state and scope conflicts. It is an audit tool, not a delivery dependency.

The reconciler remains read-only. Cleanup or task mutation is never inferred from its report.

## Safety that remains mandatory

Removing global lease reconciliation does not weaken the delivery gates. The following remain authoritative:

- exactly one task record for feature branches after the enforcement marker;
- delivery-profile routing checks;
- exact-SHA feature preflight;
- changed native-module compilation where applicable;
- serialized integration;
- live-base revalidation immediately before merge;
- compare-and-swap retry if the integration base moved;
- STANDARD/ECONOMY/profile workflows where required;
- FINAL_PACKAGE, provenance, updater integrity and gameplay evidence.

The old global Control Plane can still be invoked when diagnosing coordination problems, but it must not be placed back in the normal feature hot path.
