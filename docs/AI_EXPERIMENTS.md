# AI experiment lifecycle and recovery

The compact generated `runtime/ai_experiment_index.json` is the normal routing view. `runtime/ai_experiments.json` remains the evidence ledger and is loaded only when compact routing is insufficient or evidence must be updated.

Live GitHub `main` and canonical runtime metadata always outrank ledger snapshots.

## Route a task

1. Resolve current `main` HEAD.
2. Read the compact index and identify matching active feature work.
3. Inspect only the relevant module owner, direct dependencies and declared shared resources.
4. Continue an existing feature only when mechanism/goal match. Otherwise create `feature/<purpose>` from current `main`.
5. Keep one task coordination record at `runtime/parallel_tasks/<task-id>.json`.

Do not choose between historical `work` and `parallel` development worlds. They are no longer parallel authorities: `main` is canonical, `parallel` is its delivery alias, and `work` is legacy compatibility/history.

## Evidence and conflicts

The experiment ledger records declared goals and exact-commit evidence. It is not a live Git ref and it does not prove gameplay.

Broaden analysis only for a concrete unresolved risk:
- shared hook/ABI/load-order ownership,
- conflicting active feature task,
- provenance mismatch,
- merge conflict,
- failed verifier/build/package,
- explicit historical/audit request.

Shared-resource overlap requires ordered integration or explicit arbitration. It does not justify scanning every branch or globally serializing independent coding.

## Integration

A feature must pass its routed preflight on the exact feature SHA. Required profile workflows must pass when declared. The queue then revalidates against current `main`, merges once, records integrated task state, and atomically updates `main` and `parallel` to the same SHA.

Post-integration delivery is risk/path routed. Unknown or mixed runtime changes fail closed to STANDARD. `PREFLIGHT PASS` is never equivalent to `TEST READY`.

## Game-test evidence

Record user-reported game results only against the exact integrated/tested SHA and artifact. Unknown or unreported outcomes remain unknown. One passing module test does not accept unrelated work.

## Recovery

After an interrupted/ambiguous GitHub operation, re-read the target ref and exact-SHA Actions state before retrying. Resume from confirmed GitHub state; never replay an uncertain write blindly or reuse CI evidence from another SHA.
