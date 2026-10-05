# AI START HERE

`AGENTS.md` is authoritative. Target: **WoW 1.12.1 build 5875, Windows x86**.

## Normal ChatGPT fast path

```text
read live main HEAD once
-> read runtime/ai_startup_snapshot.json once
-> open known owner/module files directly
-> implement
-> targeted preflight
-> optimistic CAS integration to main + parallel
-> routed exact-SHA delivery
```

`main` is the canonical integration/development trunk. `parallel` is an exact compatibility/delivery alias, not a second development world. `feature/**` branches are short-lived tasks; `work` is legacy history; `promote/**` is release-only.

For ordinary work **trust the generated startup snapshot on canonical main**. Do not spend chat/tool time re-verifying its five source hashes. Hash verification/full startup is only for startup-contract edits, stale-snapshot diagnosis, release work, or ambiguous recovery.

Do **not** read `runtime/ai_experiment_index.json` by default. It contains historical experiment evidence and is consulted only for explicit continuation/ambiguity. If the module owner/path is known from the request, go straight to that owner.

Do **not** enumerate branches, history, archives, all task records, or successful CI jobs on the success path.

## Integration

Feature preflight/profile gates may run concurrently. Integration uses **optimistic atomic CAS**, not a serialized pending-slot queue:

```text
feature exact SHA
-> fetch/revalidate current main
-> local merge
-> atomic push main + parallel
-> lost race: refetch/revalidate/retry
-> path/risk-routed exact-SHA delivery
```

Unknown or mixed runtime changes fail closed to STANDARD. Profile-contained changes use their profile. Task/docs-only changes avoid binary delivery.

## Chat behavior

Default is **final-only** communication. No minute pings and no GitHub/API polling just to show progress. Report a blocker when one exists; otherwise return the result. Detailed jobs/logs are read only on failure, unexpected stall, or explicit `check`.

Heavy repository audits stay nightly/manual/PR/release.

Full contract: `AGENTS.md`.
