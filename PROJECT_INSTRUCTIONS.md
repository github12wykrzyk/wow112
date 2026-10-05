# Project instructions — WoW112 AI-first workflow

`AGENTS.md` is authoritative. Target: **WoW 1.12.1 build 5875, Windows x86**.

## Canonical model

- `main` — only normal integration/development trunk.
- `parallel` — exact compatibility/delivery alias updated atomically with `main`.
- `feature/**` — short-lived tasks from current `main`.
- `promote/**` — curated releases.
- `work` — legacy/history only.

## Minimum-latency execution

Normal task:

```text
main HEAD once
-> startup snapshot once
-> owner files
-> implement
-> targeted preflight/profile
-> optimistic CAS integration
-> routed exact-SHA delivery
```

Do not fetch the experiment index/ledger, all branches, all task records, history, archives, or successful CI logs unless the current task has a concrete unresolved need for them.

No chat progress pings by default. No API calls solely for status narration. The integration workflow waits for its own downstream exact-SHA delivery; chat inspects detailed jobs/logs only on failure/stall or explicit `check`.

Concurrent integration attempts are safe: each revalidates live `main`; atomic `main+parallel` push selects one winner; losers refetch/revalidate/retry.

Unknown/mixed/shared runtime changes fail closed to STANDARD. Profile-contained changes use only their profile. Docs/task-only changes avoid binary delivery.

Stable identity is baseline/artifact metadata; release uses curated `promote/**` exact SHAs.
