# AI iteration workflow

## Objective

Minimize wall-clock time from request to verified result while preserving exact-SHA safety and stable rollback identity.

## 1. Route, do not rediscover

Normal entry:

```text
main HEAD
-> verified startup snapshot
-> compact experiment/task context
-> owner files only
```

Useful helper:

`python tools/ai_task_context.py --branch main --module <Module>`

Do not read the full experiment ledger, enumerate branches or inspect archives before the first implementation unless compact routing exposes a concrete unresolved risk.

## 2. Feature lifecycle

For ordinary changes:

1. create/reuse `feature/<purpose>` from current `main`,
2. implement the complete logical iteration,
3. pass routed feature preflight on the exact feature SHA,
4. pass exact feature-SHA profile gates when required,
5. enter the serialized canonical integration queue,
6. revalidate against live `main`,
7. merge once,
8. atomically move `main` and `parallel` to the integrated SHA,
9. run the exact integrated-SHA delivery selected by the risk/path router,
10. delete the integrated feature branch after successful delivery.

Expected state:

`EDITING -> PREFLIGHT -> INTEGRATION -> ROUTED DELIVERY -> TEST READY/DONE`

## 3. Delivery routing

- validation-only/docs/task metadata: no binary delivery,
- profile-contained ECONOMY/UPDATER/AUTOLOGINBRIDGE: only required profile(s),
- uncovered/shared/native/core/control-plane: STANDARD,
- classifier ambiguity: STANDARD.

Feature preflight and exact-SHA delivery are different stages. A preflight success alone never proves a runnable artifact is ready.

## 4. Heavy checks

Deep repository verification, full AI registry validation and broad ABI audit are intentionally outside the micro-iteration hot path. They run scheduled/manual/PR/release.

Inspect detailed jobs/steps/logs only to diagnose failure/cancellation/stall or a specific gate.

## 5. Release lifecycle

A stable release is a curated snapshot, not a separate long-lived development world.

1. start from current `main`,
2. curate accepted state into `promote/<purpose>`,
3. set stable metadata and synchronize fingerprints,
4. require `Pre-promote stable` PASS on the exact promote SHA,
5. run explicit `Build stable candidate` on that curated release SHA,
6. preserve exact accepted runtime bytes and rollback metadata.

`main` remains the canonical integration trunk before and after release.

## 6. Stable byte identity

TEST candidates may be rebuilt. STABLE packages must use exact accepted bytes referenced by runtime metadata or the content-addressed runtime cache and must pass final package verification.
