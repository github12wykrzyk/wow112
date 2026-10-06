# WoW112 AH canonical development path

## Authoritative branch

`dev/windows-ah-canonical`

This is the only active development branch for the headless AH engine.

Historical feature branches are inputs/history only. New Vendor, Disenchant, risk, cache, BUY safety, logging, launcher and protocol work must land here first.

## Platform policy

### Phase 1 — Windows first

Windows is the reference implementation and validation platform.

All new behavior is implemented and live-validated on native Windows before any Android port work starts.

Current canonical Windows scope:

- FULL-AH Vendor scan
- all classes / qualities / stacks
- vendor valuation from live item query
- profit-first purchase ordering
- exact auction tuple revalidation before SEND
- bounded neighborhood revalidation
- broad Disenchant coverage (2343 live item snapshot)
- DE provenance preservation
- CapyDB live eligibility only with independent model agreement = 0
- legacy DE provenance blocked for live BUY
- SAFE EV / ROI / P(loss) risk gates
- exact audited DE BUY
- no automatic retry after uncertain mutation
- Windows CI artifact containing Vendor and DE binaries

## Single-source CI rule

`.github/workflows/build_windows_ah_canonical.yml` must build entirely from this branch.

It must not checkout or fetch implementation files from historical feature branches.

A CI build may generate derived Rust sources, but every generator, cache builder, seed, configuration and safety patch required to reproduce the build must exist on this branch.

## Development ownership rule

Parallel conversations are allowed only when they own different modules.

Examples of safe parallel work:

- AH protocol / pagination
- economy database / history
- Vendor strategy
- DE valuation / risk
- GUI / launcher
- observability / reports

Two conversations must not independently implement the same engine behavior on different branches.

Any new work must state that `dev/windows-ah-canonical` is the authoritative baseline.

## Phase 1 exit criteria

Do not start the Android port as an independent implementation. Windows core should first have:

1. reproducible green canonical CI;
2. stable FULL-AH Vendor operation;
3. stable broad DE audit and guarded BUY;
4. unified shared economic decision model;
5. deterministic logs and machine-readable reports;
6. mutation uncertainty hard-stop verified;
7. no runtime dependency on historical feature branches;
8. a defined platform boundary between shared core and OS-specific launcher/transport code.

## Phase 2 — Android port

Android is a port of the Windows-proven canonical core, not a second product line.

Target architecture:

- shared Rust AH/protocol/economy/risk core;
- thin Windows platform adapter;
- thin Android platform adapter;
- identical decision rules and safety contracts on both platforms;
- platform-specific build/launch packaging only where required.

Feature development remains Windows-first after the Android port exists: implement -> validate on Windows -> port/test adapter impact on Android.

## Historical branches

Treat previous `feature/windows-headless-ah-fast`, `feature/poc08-*`, `feature/vendor-*`, and `feature/vendor-plus-de-windows` branches as frozen historical references unless a missing change is explicitly being migrated into canonical.

Do not base new feature work on them.
