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

## Fast feature preflight

Ordinary feature preflight is path-routed instead of running every repository gate on every edit.

- checkout starts shallow (`fetch-depth: 8`);
- the integration base is fetched shallow as well;
- if the feature fork point is older, history is deepened only for the current feature/base refs (32, 128, then 512 commits) and full history is a correctness fallback, not the default;
- an empty diff is an immediate no-op PASS;
- edited text receives a cheap NUL/unresolved-conflict-marker sanity check;
- SummonScout changes run the SummonScout Lua upvalue guard;
- Aux/AH changes run the relevant ECONOMY and AutoSell contracts;
- PlayerESP changes run the GUI ABI/behavior contracts;
- TargetAura/LazyScript changes run their bridge contract;
- native changes run core runtime/provenance/dependency checks and compile only changed active/companion modules;
- workflow/tooling/policy changes still run the broad `test_ai_*` suite and broad infrastructure gates.

Integration deliberately keeps `fetch-depth: 0`: shallow history is an optimization for the feature hot path, never for the actual merge/CAS safety boundary.

The separate `Verify AI experiment registry` workflow does not run on ordinary `feature/**` pushes; branch-local task validation is owned by feature preflight. Registry-wide verification remains on integration/trunk infrastructure paths and pull requests.

## Integration mutex

The authoritative concurrency mechanism for trunk movement is the GitHub Actions concurrency group:

```text
parallel-integration-queue
```

Independent coding and feature preflight remain concurrent. Only integration is serialized. The existing compare-and-swap retry behavior still protects against the integration base moving between validation and push.

## Single-owner delivery

Queued integration has exactly one downstream delivery owner.

The integration job checks out with the default `actions/checkout` repository `GITHUB_TOKEN` credentials and pushes the integrated SHA to `parallel`. GitHub intentionally does not create new workflow runs for ordinary events caused by that repository `GITHUB_TOKEN`, so that queue push does **not** recursively start the build workflows' `push` triggers.

After the remote SHA is verified, `tools/parallel_ci_dispatch.py` explicitly starts only the required STANDARD/ECONOMY/UPDATER/AutoLoginBridge workflows with `workflow_dispatch`, resolves the newly materialized run by exact branch + exact SHA, and waits for that exact run to succeed.

Therefore the normal queue path is:

```text
queue integration
  -> GITHUB_TOKEN push (no recursive push workflows)
  -> exact-SHA workflow_dispatch owner
  -> wait for exact selected delivery runs
```

Existing `push` triggers on delivery workflows are retained only as a direct/manual-push recovery path. They are not a second delivery owner for queued integration. Do not replace the integration push credentials with a PAT or another token that can recursively trigger workflows unless the delivery ownership model is redesigned at the same time.

`tools/test_ai_delivery_single_owner.py` protects this invariant and must remain in the broad infrastructure test suite.

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

- exactly one task record for feature branches after the enforcement marker when the feature has an actual diff;
- delivery-profile routing checks;
- exact-SHA feature preflight;
- changed native-module compilation where applicable;
- serialized integration;
- live-base revalidation immediately before merge;
- compare-and-swap retry if the integration base moved;
- single-owner exact-SHA downstream delivery;
- STANDARD/ECONOMY/profile workflows where required;
- FINAL_PACKAGE, provenance, updater integrity and gameplay evidence.

The old global Control Plane can still be invoked when diagnosing coordination problems, but it must not be placed back in the normal feature hot path.
