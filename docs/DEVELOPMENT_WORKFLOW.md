# Development workflow

`AGENTS.md` is authoritative.

`main` is canonical; `parallel` is its exact delivery alias; `work` is legacy.

## Ordinary iteration

1. Resolve `main` once.
2. Read the startup snapshot once.
3. Open only the owner/direct contract files.
4. Implement one coherent feature commit.
5. Run routed preflight and required exact feature-SHA profile gates.
6. Revalidate against live `main`.
7. Attempt atomic CAS update of `main + parallel`; on race loss refetch/revalidate/retry.
8. Run only path/risk-routed exact-SHA delivery.
9. Clean the integrated feature branch.

There is no serialized GitHub pending-slot integration queue.

Repository-wide audits are scheduled/manual/PR/release. Do not inspect successful CI detail or historical branch/task state on the normal path.
