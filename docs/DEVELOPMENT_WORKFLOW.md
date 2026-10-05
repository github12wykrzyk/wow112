# Development workflow

`AGENTS.md` is authoritative.

## One canonical trunk

`main` is the canonical integration/development trunk. `parallel` is an exact compatibility/delivery alias and must match the integrated `main` SHA after queue delivery. `work` is legacy history/compatibility, not the default development branch.

Ordinary independent work starts from current `main` on `feature/<purpose>`. `promote/**` is reserved for curated release snapshots.

## Fast iteration

1. Resolve current `main` HEAD.
2. Use the verified startup snapshot and compact experiment index.
3. Inspect only the owner files and direct dependency/contract evidence required by the risk.
4. Implement one coherent change on a short-lived feature branch.
5. Require routed feature preflight on the exact feature SHA.
6. Require declared profile gates only when their paths are affected.
7. Let the serialized queue revalidate against live `main`.
8. Integrate and atomically update `main` plus `parallel`.
9. Run only the post-integration delivery selected by the risk/path router.
10. Delete the integrated feature branch after successful delivery.

Broad history/branch archaeology is failure-driven, not a default preparation step.

## Verification tiers

Hot path:
- targeted syntax/static/module contract checks,
- changed native modules only,
- exact declared delivery profiles,
- STANDARD only for uncovered/shared/native-core/control-plane changes.

Heavy path:
- deep repository audit — nightly/manual/PR,
- full AI registry suite — nightly/manual/PR,
- broad native ABI audit — scheduled/manual,
- release checks — curated `promote/**`.

A green feature preflight alone does not produce a test-ready game artifact.

## Release

Create a curated `promote/<purpose>` snapshot from current `main`. Require exact-SHA pre-promotion verification, source metadata consistency, deep checks, exact-byte packaging and final package verification. Then run the stable candidate workflow explicitly on that curated release SHA.

Do not move `main` merely to represent stable state; stable identity is carried by baseline/runtime metadata and exact accepted artifacts.
