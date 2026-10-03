# AuxEconomyShadow v2

Side-by-side consolidation workspace for the WoW 1.12.1 (5875 x86) auction-house/economy stack.

## Baseline

This branch starts from `parallel@c4e35928deab3b07e667b94631c61dc63510d9a6`, after both DE rollback steps. In particular, the consolidation must not reintroduce the removed `AuxVmangos_DEPriceGuard.lua` / DE history-cap valuation path. The currently working `AuxVmangos`, `AuxFastBridge`, native AH module, manifests and updater delivery stay unchanged until a separate cutover stage.

## Hot-fix invariant

The target production design is hot-fixable while WoW stays running and without `/reload`:

1. `AuxEconomyShadow_Anchor.lua` is the stable, persistent runtime anchor. It owns persistent state and the replace-module protocol.
2. Replaceable strategy/runtime modules are re-executable through `W112_AH_SHADOW.ReplaceModule`, preserving their state tables across hot generations.
3. A failed module replacement fails closed and keeps or restores the prior module when possible.
4. Hot modules must not create unmanaged duplicate frames, `ADDON_LOADED` ownership or free-running `OnUpdate` loops.
5. No new native watcher is required. `tools/ah_shadow_hot_bundle.py` composes the shadow modules into the already watched `SummonScout_PostPaymentOfferHot.lua` payload during addon packaging. The existing `WoWAutoLoginBridge_5875_v1.dll` watcher executes a changed host in-world.
6. Because the updater already permits AddOn-only writes while WoW is running, future Lua-only AH fixes can be delivered without closing the client and without `/reload` once this routing is integrated.

## Staged consolidation

- Stage 1: persistent anchor, replaceable payload contract, safety verifier.
- Stage 2: pure normalized auction contracts plus Vendor and DE evaluators. No AH actions.
- Stage 3: MarketBook and deterministic CandidatePipeline. No AH actions.
- Stage 4: coordinator/state machine, AUX observation adapter and fail-closed TransactionGuard. Real actions remain hard-locked.
- Stage 5: pure AutoSell lifecycle plus bounded Ledger. AutoSell emits intents only: cancel -> owner verification -> return/mail proof -> reprice -> post intent -> owner reconciliation.
- Stage 6: reuse the existing native hot watcher by packaging the complete shadow runtime into the already watched SummonScout hot host. No new DLL and no extra watcher slot.
- Stage 7: parity diagnostics against the working AH stack, including decisions, lifecycle transitions and ledger output.
- Stage 8: explicit cutover candidate only after exact-SHA CI, package/provenance gates and user acceptance.

No stage may silently activate `AuxEconomyShadow` as its own addon root in `runtime/parallel_candidate.json` or `runtime/parallel_economy.json`.
