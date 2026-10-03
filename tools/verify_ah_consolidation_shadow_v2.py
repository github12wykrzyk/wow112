#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

from ah_shadow_hot_bundle import BUNDLE_MARKER, HOST_NAME, ORDER, build_bundle, transform_summonscout_host
from summonscout_hot_transform import transform_file as transform_summonscout_file

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-consolidation-hotreload-v2.json"
MANIFEST = ROOT / "runtime" / "ah_consolidation_shadow_v2.json"
PARALLEL = ROOT / "runtime" / "parallel_candidate.json"
ECONOMY = ROOT / "runtime" / "parallel_economy.json"
ACTIVE_AUX_TOC = ROOT / "src" / "AddOns" / "AuxVmangos" / "AuxVmangos.toc"
REMOVED_DE_GUARD = ROOT / "src" / "AddOns" / "AuxVmangos" / "AuxVmangos_DEPriceGuard.lua"
PACKAGER = ROOT / "tools" / "package_lazyrogue_addons.py"
HOT_HOST_SOURCE = ROOT / "src" / "AddOns" / "SummonScout" / HOST_NAME

BRIDGE_MODULE = "AuxEconomyShadow_ParityBridge.lua"
MODULES = [
    "AuxEconomyShadow_Contracts.lua",
    "AuxEconomyShadow_MarketBook.lua",
    "AuxEconomyShadow_Vendor.lua",
    "AuxEconomyShadow_Disenchant.lua",
    "AuxEconomyShadow_Flip.lua",
    "AuxEconomyShadow_Stack.lua",
    "AuxEconomyShadow_Bid.lua",
    "AuxEconomyShadow_CandidatePipeline.lua",
    "AuxEconomyShadow_Coordinator.lua",
    "AuxEconomyShadow_AuxAdapter.lua",
    "AuxEconomyShadow_TransactionGuard.lua",
    "AuxEconomyShadow_AutoSell.lua",
    "AuxEconomyShadow_Ledger.lua",
    "AuxEconomyShadow_Parity.lua",
    BRIDGE_MODULE,
]
REQUIRED = [TASK, MANIFEST, SHADOW / "README.md", SHADOW / "AuxEconomyShadow.toc",
            SHADOW / "AuxEconomyShadow_Anchor.lua", SHADOW / "AuxEconomyShadow_HotPayload.lua",
            PACKAGER, HOT_HOST_SOURCE, ROOT / "tools" / "ah_shadow_hot_bundle.py"] + [SHADOW / x for x in MODULES]
FORBIDDEN_ACTIONS = ("PlaceAuctionBid", "CancelAuction", "PostAuction", "QueryAuctionItems", "UseContainerItem")
FORBIDDEN_RUNTIME = ("GetAuctionItemInfo", "GetNumAuctionItems", "GetMoney(", "UnitName(", "CreateFrame(", "RegisterEvent(", "SetScript(\"OnUpdate\"")
BRIDGE_FORBIDDEN = ("GetAuctionItemInfo", "GetNumAuctionItems", "CreateFrame(", "RegisterEvent(", "SetScript(\"OnUpdate\"", "AUXFAST_RestartSearch", "AUXFAST_ResumeSearch")
DE_FORBIDDEN = ("AVM_AUX_HISTORY", "aux.core.history", "history.value", "data_points", "AVM_DE_PRICE_GUARD_HISTORY", "deHistoryCapHits")


def fail(msg: str) -> None:
    raise SystemExit("AH_CONSOLIDATION_SHADOW_V2: FAIL: " + msg)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"cannot read {path.relative_to(ROOT)}: {exc}")


def roots(data: dict) -> set[str]:
    out: set[str] = set()
    addons = data.get("addons")
    if isinstance(addons, dict):
        out.update(x for x in addons.get("roots", []) if isinstance(x, str))
    for key in ("addon_roots", "roots"):
        values = data.get(key, [])
        if isinstance(values, list):
            out.update(x for x in values if isinstance(x, str))
    return out


def require_tokens(path: Path, tokens: tuple[str, ...], label: str) -> str:
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        if token not in text:
            fail(label + " missing " + token)
    return text


def main() -> None:
    missing = [str(p.relative_to(ROOT)) for p in REQUIRED if not p.is_file()]
    if missing:
        fail("missing files: " + ", ".join(missing))

    task, manifest, parallel = read_json(TASK), read_json(MANIFEST), read_json(PARALLEL)
    economy = read_json(ECONOMY) if ECONOMY.is_file() else {}

    if task.get("branch") != "feature/ah-consolidation-hotreload-v2": fail("task branch mismatch")
    if task.get("status") not in {"coding", "preflight", "blocked"}: fail("invalid inactive-shadow task status")
    if task.get("auto_integrate") is not False: fail("shadow must not auto-integrate")
    if task.get("delivery_profiles") != []: fail("inactive shadow must not declare delivery profiles")
    if manifest.get("base_parallel_sha") != task.get("base_parallel_sha"): fail("base SHA mismatch")
    if "SummonScout" not in task.get("modules", []): fail("hot host owner is not declared in task modules")

    hot_cfg = manifest.get("hot_reload", {})
    if hot_cfg.get("required") is not True: fail("hot reload must remain required")
    if hot_cfg.get("close_game_required_for_lua_fix") is not False: fail("Lua hot fix may not require closing WoW")
    if hot_cfg.get("reload_ui_required_for_lua_fix") is not False: fail("Lua hot fix may not require /reload")
    if hot_cfg.get("native_live_executor") != "WoWAutoLoginBridge_5875_v1.dll": fail("unexpected hot executor")
    if hot_cfg.get("native_live_executor_status") != "reuse_existing_watcher": fail("hot executor must reuse existing watcher")
    if hot_cfg.get("new_native_binary_required") is not False: fail("AH hot routing unexpectedly requires a new native binary")
    if hot_cfg.get("bundle_host") != "Interface/AddOns/SummonScout/" + HOST_NAME: fail("hot bundle host mismatch")
    if "src/AddOns/AuxEconomyShadow/" + BRIDGE_MODULE not in hot_cfg.get("watch_files", []): fail("parity bridge is not hot-routed")

    for key in ("enabled", "active_parallel_candidate", "active_economy_overlay", "updater_visible", "cutover_allowed"):
        if manifest.get("delivery", {}).get(key) is not False:
            fail("delivery flag must remain false: " + key)
    safety = manifest.get("safety", {})
    if safety.get("production_ah_untouched") is not True: fail("production AH safety flag changed")
    if safety.get("may_send_ah_queries") is not False: fail("shadow may not send AH queries")
    if safety.get("may_submit_transactions") is not False: fail("shadow may not submit transactions")
    if safety.get("may_patch_global_ah_api") is not False: fail("shadow may not patch Blizzard AH API")
    if safety.get("passive_project_callback_wrapping") is not True: fail("passive callback bridge safety declaration missing")
    if safety.get("wrapper_preserves_original_return") is not True: fail("callback wrapper must preserve active return")
    expected_callbacks = {"AVM_AuxArbScanStart", "AVM_AuxArbAuction", "AVM_AuxArbPageDone", "AVM_AuxArbScanDone"}
    if set(safety.get("wrapped_project_callbacks", [])) != expected_callbacks: fail("unexpected passive callback set")

    if "AuxEconomyShadow" in roots(parallel) or "AuxEconomyShadow" in roots(economy): fail("shadow addon became active")
    if "SummonScout" not in roots(parallel): fail("watched hot host addon is not in parallel candidate")
    if REMOVED_DE_GUARD.exists(): fail("removed DE price guard was reintroduced")
    if "AuxVmangos_DEPriceGuard.lua" in ACTIVE_AUX_TOC.read_text(encoding="utf-8"): fail("active Aux TOC restored DE guard")

    companions = parallel.get("companions", [])
    auto = [x for x in companions if isinstance(x, dict) and x.get("runtime_name") == "WoWAutoLoginBridge_5875_v1.dll"]
    if len(auto) != 1: fail("parallel candidate does not expose exactly one AutoLoginBridge")
    if "src/AutoLoginBridge/WoWAutoLoginBridge_5875_v1_HOTPROBE.c" not in auto[0].get("sources", []):
        fail("parallel AutoLoginBridge is not the existing hot-probe build")

    all_lua = "\n".join(p.read_text(encoding="utf-8") for p in SHADOW.glob("*.lua"))
    for token in FORBIDDEN_ACTIONS:
        if token in all_lua: fail("forbidden AH action primitive: " + token)

    anchor = (SHADOW / "AuxEconomyShadow_Anchor.lua").read_text(encoding="utf-8")
    for token in ("W112_AH_SHADOW", "ReplaceModule", "BeginHotPayload", "EndHotPayload"):
        if token not in anchor: fail("anchor missing " + token)

    for name in MODULES:
        text = (SHADOW / name).read_text(encoding="utf-8")
        if "ReplaceModule" not in text: fail(name + " is not hot-replaceable")
        if name != BRIDGE_MODULE:
            for token in FORBIDDEN_RUNTIME:
                if token in text: fail(f"{name} uses runtime/game primitive {token}")

    bridge = require_tokens(SHADOW / BRIDGE_MODULE,
                            ("AVM_AuxArbScanStart", "AVM_AuxArbAuction", "AVM_AuxArbPageDone", "AVM_AuxArbScanDone",
                             "function api.install", "function api.uninstall", "HooksIntact", "RecordDecision", "CutoverGate",
                             "GetMoney(", "UnitName(", "pcall(observeStart", "pcall(observeAuction", "pcall(observePageDone", "pcall(observeScanDone"),
                            "passive parity bridge")
    for token in BRIDGE_FORBIDDEN:
        if token in bridge: fail("passive parity bridge owns forbidden runtime primitive: " + token)
    for token in FORBIDDEN_ACTIONS:
        if token in bridge: fail("passive parity bridge owns forbidden AH action: " + token)
    if bridge.count("state.originals.scanStart(resume, filterString)") != 1: fail("scan-start wrapper does not call original exactly once")
    if bridge.count("state.originals.auction(raw)") != 1: fail("auction wrapper does not call original exactly once")
    if bridge.count("state.originals.pageDone(page, lastPage)") != 1: fail("page-done wrapper does not call original exactly once")
    if bridge.count("state.originals.scanDone()") != 1: fail("scan-done wrapper does not call original exactly once")

    contracts = require_tokens(SHADOW / "AuxEconomyShadow_Contracts.lua",
                               ("NormalizeAuction", "NormalizeListing", "bidAmount", "BetterCandidate"), "contracts")
    if "blizzard_bid" not in contracts or "start_price" not in contracts: fail("contracts missing active bid-price aliases")

    de_text = (SHADOW / "AuxEconomyShadow_Disenchant.lua").read_text(encoding="utf-8")
    for token in DE_FORBIDDEN:
        if token.lower() in de_text.lower(): fail("DE evaluator restored historical price anchor: " + token)
    for token in ("DepthPrice", "deSafetyMarginPct", "deAhCutPct"):
        if token not in de_text: fail("DE evaluator missing " + token)

    vendor_text = (SHADOW / "AuxEconomyShadow_Vendor.lua").read_text(encoding="utf-8")
    if vendor_text.find('"aux-learned"') > vendor_text.find('"turtle-db"'): fail("vendor priority changed")

    require_tokens(SHADOW / "AuxEconomyShadow_MarketBook.lua",
                   ("NormalizeListing", "ItemOffers", "ItemListings", "bidOnlyCount", "Snapshot"), "market book")

    flip = require_tokens(SHADOW / "AuxEconomyShadow_Flip.lua",
                          ("ReferenceFloor", "flipDepthUnits", "flipHistMaxPct", "flipMinSellers", "flipMaxItemSpend", "historyByKey", 'route = "flip"'),
                          "flip evaluator")
    if "aux.core.history" in flip: fail("flip evaluator directly binds AUX history runtime")

    stack = require_tokens(SHADOW / "AuxEconomyShadow_Stack.lua",
                           ("stackSmallPct", "stackLargePct", "stackSmallDepthUnits", "stackMinSmallSellers", "smallSellers", 'route = "stack"'),
                           "stack evaluator")
    if "aux.core.history" in stack: fail("stack evaluator directly binds AUX history runtime")

    require_tokens(SHADOW / "AuxEconomyShadow_Bid.lua",
                   ("bidVendorMarginPct", "bidDeMarginPct", "bidMaxAmount", "bidMaxDuration", "bidMaxSessionPlacements", "has-buyout", "high-bidder", 'route = route'),
                   "bid evaluator")

    require_tokens(SHADOW / "AuxEconomyShadow_CandidatePipeline.lua",
                   ('"vendor"', '"disenchant"', '"flip"', '"stack"', '"bid"', "BetterCandidate", "EvaluateBook", "postscanBestAffordable", "bid-fallback"),
                   "candidate pipeline")

    coord = (SHADOW / "AuxEconomyShadow_Coordinator.lua").read_text(encoding="utf-8")
    for state in ("IDLE","SCANNING","PAUSE_REQUESTED","PAUSED","VERIFYING","TRANSACTION_PENDING","UNKNOWN_HOLD","RESUME_PENDING","STOPPED"):
        if state not in coord: fail("coordinator missing state " + state)

    adapter = (SHADOW / "AuxEconomyShadow_AuxAdapter.lua").read_text(encoding="utf-8")
    for token in ("BeginObservedScan", "ObserveAuction", "PageDone", "EndObservedScan"):
        if token not in adapter: fail("AUX adapter missing " + token)

    tx = (SHADOW / "AuxEconomyShadow_TransactionGuard.lua").read_text(encoding="utf-8")
    for token in ("Prepare", "Validate", "shadow-real-actions-locked", "realActionsEnabled = false"):
        if token not in tx: fail("transaction guard missing fail-closed token " + token)
    if "realActionsEnabled = true" in tx: fail("transaction guard armed real actions")

    autosell = (SHADOW / "AuxEconomyShadow_AutoSell.lua").read_text(encoding="utf-8")
    for state_name in ("OWNED", "CANCEL_REQUESTED", "WAIT_RETURN", "WAIT_REPRICE", "POST_READY", "POST_PENDING", "POST_RECOVER", "DONE", "BLOCKED"):
        if state_name not in autosell: fail("autosell missing state " + state_name)
    for token in ("RequestCancel", "ObserveOwnerSnapshot", "ObserveReturnedToBag", "SetReprice", "MarkPostStarted", "ObservePosted", "NextIntent"):
        if token not in autosell: fail("autosell missing lifecycle API " + token)

    ledger = (SHADOW / "AuxEconomyShadow_Ledger.lua").read_text(encoding="utf-8")
    for token in ("Record", "Recent", "Summary", "SetMaxRows"):
        if token not in ledger: fail("ledger missing " + token)

    parity = (SHADOW / "AuxEconomyShadow_Parity.lua").read_text(encoding="utf-8")
    for token in ("RecordDecision", "RecordLifecycle", "RuntimeSnapshot", "decisionMatchPct", "shadow-miss", "shadow-extra", "different-candidate"):
        if token not in parity: fail("parity diagnostics missing " + token)

    hot = (SHADOW / "AuxEconomyShadow_HotPayload.lua").read_text(encoding="utf-8")
    if any(x in hot for x in ("CreateFrame(", "RegisterEvent(", "ADDON_LOADED")):
        fail("hot payload owns unmanaged frame/event")

    toc = (SHADOW / "AuxEconomyShadow.toc").read_text(encoding="utf-8")
    if "AVM_SHADOW_DB" not in toc: fail("SavedVariables namespace not isolated")
    order = ["AuxEconomyShadow_Anchor.lua"] + MODULES + ["AuxEconomyShadow_HotPayload.lua"]
    pos = -1
    for name in order:
        nxt = toc.find(name)
        if nxt <= pos: fail("TOC module order invalid at " + name)
        pos = nxt
    if tuple(order) != ORDER: fail("bundle builder order differs from TOC/module verifier order")

    packager_text = PACKAGER.read_text(encoding="utf-8")
    for token in ("from ah_shadow_hot_bundle import transform_summonscout_host", "transform_summonscout_host(path.name, data)"):
        if token not in packager_text: fail("addon packager missing AH hot bundle routing")

    bundle = build_bundle()
    if bundle.count(BUNDLE_MARKER) != 1: fail("AH bundle marker count mismatch")
    packed_host = transform_summonscout_file(HOST_NAME, HOT_HOST_SOURCE.read_bytes())
    packed_host = transform_summonscout_host(HOST_NAME, packed_host)
    if packed_host.count(BUNDLE_MARKER) != 1: fail("watched host does not contain exactly one AH bundle")
    if len(packed_host) >= 262144: fail("watched host exceeds native hot payload cap")

    print("AH_CONSOLIDATION_SHADOW_V2: PASS")
    print("delivery=inactive")
    print("hot_reload=existing-autologinbridge-watcher")
    print("hot_bundle_host=SummonScout_PostPaymentOfferHot.lua")
    print("hot_fix_requires_close=false reload=false")
    print("marketbook=pure-listings pipeline=pure-full-strategies")
    print("de=pure-live-depth-no-history-cap")
    print("flip=pure-readonly-history-live-depth")
    print("stack=pure-small-large-depth")
    print("bid=pure-vendor-de-fallback")
    print("parity_bridge=passive-readonly-original-return-preserved")
    print("transaction_guard=real-actions-hard-locked")
    print("autosell=pure-intents-only")
    print("ledger=pure-bounded-event-store")
    print("parity=pure-active-vs-shadow-comparator")
    print("de_rollback_guard=preserved")


if __name__ == "__main__":
    main()
