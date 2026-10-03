# AuxEconomyShadow v2

Side-by-side consolidation workspace for the WoW 1.12.1 (5875 x86) auction-house/economy stack.

## Baseline

This branch starts from `parallel@c4e35928deab3b07e667b94631c61dc63510d9a6`, after both DE rollback steps. In particular, the consolidation must not reintroduce the removed `AuxVmangos_DEPriceGuard.lua` / DE history-cap valuation path. The currently working `AuxVmangos`, `AuxFastBridge`, native AH module, manifests and updater delivery stay unchanged until a separate cutover stage.

## Hot-fix invariant

The target production design is hot-fixable while WoW stays running and without `/reload`:

1. `AuxEconomyShadow_Anchor.lua` is the stable, persistent runtime anchor. It owns persistent state and the replace-module protocol.
2. `AuxEconomyShadow_HotPayload.lua` is replaceable logic. It may be written by the updater while WoW is running and re-executed by a native file watcher.
3. Hot generations reuse persistent module state and replace module APIs through the anchor. A failed replacement restores the prior module when possible.
4. Hot payloads must not create unmanaged duplicate frames or one-shot `ADDON_LOADED` ownership. Event/frame ownership will live behind reusable anchor-managed modules.
5. A later isolated stage will add the generic AH hot-Lua executor. Until then this shadow is deliberately not packaged or delivered.

## Staged consolidation

- Stage 1: persistent anchor, replaceable payload contract, safety verifier.
- Stage 2: pure normalized auction contracts plus Vendor and DE evaluators. No AH actions.
- Stage 3: coordinator/state machine and AUX observation adapter. No AH actions.
- Stage 4: transaction guard and action ownership, still shadow/test only.
- Stage 5: native live payload executor + updater/package routing, verified independently.
- Stage 6: parity diagnostics against the working AH stack.
- Stage 7: explicit cutover candidate only after exact-SHA CI, package/provenance gates and user acceptance.

No stage may silently activate this addon in `runtime/parallel_candidate.json` or `runtime/parallel_economy.json`.
