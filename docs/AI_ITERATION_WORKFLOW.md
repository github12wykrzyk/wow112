# AI iteration workflow

Objective: **minimum request-to-result wall-clock time with exact-SHA safety**.

```text
main HEAD once
-> startup snapshot once
-> owner files
-> one coherent feature change
-> targeted preflight/profile gates
-> optimistic CAS integration
-> routed exact-SHA delivery
-> done
```

Do not front-load history, branch lists, global task records, experiment ledger/index, or successful CI logs.

Multiple feature integrations may run concurrently. Each uses the current live `main`, revalidates, creates its merge, then atomically pushes `main + parallel`. A lost race is retried from the new `main`; it is not a failure and no force push is allowed.

Delivery:
- docs/task metadata: no binary delivery,
- profile-contained ECONOMY/UPDATER/AUTOLOGINBRIDGE: matching profile,
- unknown/mixed/shared/native-core/control-plane: STANDARD.

Chat behavior is final-only by default. Detailed status/log inspection is failure-driven or explicit-user-check driven.

Release remains curated `promote/**` + exact-SHA release gates/packaging.
