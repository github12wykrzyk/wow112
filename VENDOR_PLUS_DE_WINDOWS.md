# WoW112 Vendor + Disenchant — Windows

Final native-Windows combined build status: **PASS**.

## GitHub Actions

- Workflow: `WoW112 Vendor + DE Windows`
- Run: `37425292692`
- Artifact ID: `11394949324`
- Artifact: `WoW112-Windows-VENDOR-PLUS-DE-61979d9c64fa819a7c0f806126cddba85b1a848e`
- Artifact digest: `sha256:322a2763797d000513c72589017dd802e0176c5f485c83f984f3a94eb920fb2e`

## Vendor engine

- Native Windows EXE.
- FULL AH sweep.
- All classes, qualities and stack sizes.
- Profit-first purchase order: `PROFIT_DESC_PAGE_DESC_TIE`.
- Fresh exact tuple revalidation in original page +/- 5 before SEND.
- Default policy used by the combined launcher: minimum vendor profit `1c`, maximum single buyout `15g`.

Vendor source anchor: `5d26bfbf7588af2a7b1b241425932b5daa0d3ab7`.

## Disenchant engine

- Native Windows POC08-F2 exact audited BUY-one engine.
- Full cache coverage from the 2343 live item-ID snapshot.
- CI result: `2343/2343` resolved, `2334` positive DisenchantIDs, `0` unresolved.
- Exact tuple + fresh AH precheck before SEND.
- Maximum one DE purchase per DE process.
- Existing SAFE-profit / ROI / P(loss) risk gates remain in force.
- Live model disagreement is required to be `0 bps` in the combined launcher.

### DE provenance policy

Live DE eligibility is fail-closed:

- `OctoWow` with provenance confidence >= 2 is eligible subject to all normal risk/model gates.
- `CapyDB` is eligible **only when the independent reference DE model has exact agreement (`agreement_bps == 0`)**, and all normal risk gates pass.
- `SeedLegacy` does **not** authorize a live DE BUY.

Canonical F2 hardening anchor: `a5d5ceb3bdc6e62cfe350424dc7c230ebebdae18`.

## Mutation safety

- `AH_MUTATION_UNCERTAIN` => hard stop.
- A BUY SEND without the final confirmed PASS => hard stop / no blind retry.
- Vendor stale target => skip.
- DE target that changes or no longer passes the fresh gates => no SEND.

> Note: the first artifact-stage text was authored before the final CapyDB exact-agreement gate was added. The compiled final DE source/binary and this document describe the canonical final policy above.
