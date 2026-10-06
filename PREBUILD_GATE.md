# GITHUB 1.12 — Mandatory Prebuild / Blocker Gate

This document defines the mandatory workflow before any non-trivial code change, long CI run, artifact build, or retry-heavy debugging session.

The goal is to avoid spending build/test time on code changes when the observed failure may be caused by environment, runtime state, configuration, network, server state, player state, position/range, stale data, or another external blocker.

## Core rule

**DO NOT BUILD FIRST. DIAGNOSE FIRST.**

Before starting a costly build, classify the current problem as one of:

- `CODE` — evidence points to a specific implementation defect.
- `ENVIRONMENT` — evidence points to runtime/server/player/network/configuration/state outside the changed code.
- `UNKNOWN` — root cause is not isolated yet.

A costly build is authorized only when:

1. there is a concrete code delta that causally explains the symptom; or
2. the cheapest environment/runtime blocker tests have been performed and the major external causes are excluded; or
3. a controlled reproduction demonstrates that the failure is inside the program.

If none of those is true, the required output is:

`BLOCKER: BUILD PAUSED — test <cheapest discriminating test> first.`

Do not hide uncertainty behind another retry, fallback, guard, timeout increase, cache invalidation, or speculative rebuild.

## Evidence priority

Use this evidence hierarchy:

1. **Live proven evidence / successful production log**
2. **Last-known-good artifact and log**
3. **Exact GOOD vs FAIL runtime delta**
4. **Code diff / configuration diff**
5. **Server/protocol source behavior**
6. **Static reasoning**
7. **Hypothesis**

A previously live-proven behavior is the golden reference until evidence shows that it is no longer applicable.

## Mandatory preflight before a build

### 1. Last-known-good anchor

Identify the most recent run where the exact failing capability worked.

Record at minimum:

- artifact / binary / commit;
- date/time;
- account / character / realm where relevant;
- launcher and important env/config values;
- success marker proving the capability actually worked;
- mutation state (read-only / BUY sent / BUY confirmed).

Never replace live proof with `CI PASS` when a live log exists.

### 2. GOOD vs FAIL delta audit

Compare only facts that changed between the last-known-good run and the failure.

Check, where applicable:

- binary SHA / commit;
- launcher / arguments / environment variables;
- realm endpoint / server IP;
- server/network availability;
- player position and orientation;
- interaction range / target NPC / target GUID;
- combat/dead/ghost/standing/mounted/channel state;
- party/group/leader state;
- inventory/gold/mailbox state;
- auction house GUID / mailbox GUID;
- cache/history/database state;
- scan parameters / thresholds / risk gates;
- account/character selection;
- time-sensitive server state;
- dependency/API availability.

Do not modify code until the relevant deltas are understood or explicitly ruled out.

### 3. External blocker scan

Ask:

> Can a condition outside the code, by itself, produce exactly this symptom?

Examples for WoW112 include:

- player is outside NPC interaction distance;
- wrong NPC/GUID is visible but not interactable;
- target is in combat;
- character moved between runs;
- auth/world server is unavailable;
- realm address changed;
- mailbox/AH object was not spawned for the player yet;
- stale cache/env points at a previous object;
- external DB/API is unavailable;
- insufficient gold/inventory space;
- server-side throttle/cooldown/state blocks the action.

If yes, test that condition before rebuilding.

### 4. Cheapest falsification test

Choose the fastest test that can distinguish between the leading explanations.

Prefer, in this order:

1. same binary, change only runtime/environment state;
2. read-only smoke;
3. inspect existing logs/state/cache;
4. reproduce with last-known-good artifact;
5. narrow diagnostic run;
6. only then build new code.

Target duration for a prebuild falsification test: seconds to a few minutes, not a full CI cycle.

### 5. Build authorization statement

Before starting a costly build, state one of:

- `BUILD AUTHORIZED — root cause points to code: <evidence>`
- `BUILD AUTHORIZED — external blockers excluded by: <tests>`
- `BLOCKER: BUILD PAUSED — unresolved: <blocker>; next test: <test>`

Do not silently start the build.

## One-layer-at-a-time rule

While root cause is unknown, change **one layer only** per experiment.

Do not simultaneously change, for example:

- launcher;
- GUID discovery;
- retry timing;
- protocol parser;
- cache policy;
- economic decision logic.

The debugging sequence is:

`observe -> isolate -> prove -> change one thing -> retest`

If several layers must ultimately change, prove each causal step separately where practical.

## No symptom masking

The following are not accepted as fixes unless they address a proven cause:

- adding retries;
- increasing packet/time limits;
- trying more GUIDs/targets;
- clearing caches automatically;
- swallowing an error;
- converting a hard failure into a warning;
- restarting the process repeatedly;
- rebuilding the same path with different constants.

A workaround may be used temporarily, but it must be labelled `WORKAROUND`, not `ROOT CAUSE FIX`.

## Causal proof after a fix

A fix is not complete because:

- it compiles;
- CI is green;
- the expected marker exists in the binary;
- the artifact opens.

For runtime defects, require evidence that the original failure condition now succeeds under an equivalent scenario.

For mutation paths, preserve the existing rule:

- target selection is not purchase proof;
- SEND is not purchase proof;
- uncertain SEND remains a hard stop;
- only the defined final confirmation marker/log evidence counts as confirmed mutation.

## WoW112 AH specific preflight

Before rebuilding AH protocol/open/buy logic, check:

1. auth server reachable;
2. SRP6/auth result;
3. realm endpoint selected;
4. world login reaches `SMSG_LOGIN_VERIFY_WORLD PASS`;
5. current character position vs last-known-good position;
6. intended auctioneer/mailbox is present in live object updates;
7. player is plausibly inside interaction range;
8. configured/cached GUID is live-observed in the current session;
9. last-known-good binary can/cannot reproduce the issue;
10. only after those checks, inspect/change HELLO/query/BUY protocol code.

If `MSG_AUCTION_HELLO` is silent, interaction feasibility must be treated as a first-class blocker because server implementations may simply return without a response when the player cannot interact with the supplied auctioneer.

## Build cost awareness

Before starting a workflow expected to take more than a few minutes, explicitly consider:

- expected duration;
- whether the result can change the diagnosis;
- whether a cheaper local/read-only/runtime test exists;
- whether an unresolved blocker can make the build irrelevant.

If a known blocker can invalidate the result, do not spend the build.

## Communication contract

When a large unresolved obstacle is detected, surface it immediately rather than continuing silently.

Preferred format:

`BLOCKER: <what may prevent success>`

`WHY IT MATTERS: <how it could fully explain the symptom>`

`CHEAPEST TEST: <specific test>`

`BUILD STATUS: PAUSED`

When the gate passes:

`PREFLIGHT PASS: <evidence>`

`BUILD AUTHORIZED: <specific change being built>`

## Scope

This gate applies to the entire GITHUB 1.12 project, including:

- Windows AH canonical development;
- Vendor / Disenchant / BUY paths;
- summon/portal automation;
- loader/multibox work;
- Android porting;
- cloud/headless deployment;
- AUX/native bridges;
- other long CI/build workflows.

Windows remains the reference implementation for AH. Android work must still follow the Windows-first policy.
