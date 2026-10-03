#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-consolidation-hotreload-v2.json"
MANIFEST = ROOT / "runtime" / "ah_consolidation_shadow_v2.json"
PARALLEL = ROOT / "runtime" / "parallel_candidate.json"
ECONOMY = ROOT / "runtime" / "parallel_economy.json"
ACTIVE_AUX_TOC = ROOT / "src" / "AddOns" / "AuxVmangos" / "AuxVmangos.toc"
REMOVED_DE_GUARD = ROOT / "src" / "AddOns" / "AuxVmangos" / "AuxVmangos_DEPriceGuard.lua"

MODULES = [
    "AuxEconomyShadow_Contracts.lua",
    "AuxEconomyShadow_MarketBook.lua",
    "AuxEconomyShadow_Vendor.lua",
    "AuxEconomyShadow_Disenchant.lua",
    "AuxEconomyShadow_CandidatePipeline.lua",
    "AuxEconomyShadow_Coordinator.lua",
    "AuxEconomyShadow_AuxAdapter.lua",
    "AuxEconomyShadow_TransactionGuard.lua",
]
REQUIRED = [TASK, MANIFEST, SHADOW / "README.md", SHADOW / "AuxEconomyShadow.toc",
            SHADOW / "AuxEconomyShadow_Anchor.lua", SHADOW / "AuxEconomyShadow_HotPayload.lua"] + [SHADOW / x for x in MODULES]
FORBIDDEN_ACTIONS = ("PlaceAuctionBid", "CancelAuction", "PostAuction", "QueryAuctionItems", "UseContainerItem")
FORBIDDEN_RUNTIME = ("GetAuctionItemInfo", "GetNumAuctionItems", "GetMoney(", "UnitName(", "CreateFrame(", "RegisterEvent(")
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

    hot_cfg = manifest.get("hot_reload", {})
    if hot_cfg.get("required") is not True: fail("hot reload must remain required")
    if hot_cfg.get("close_game_required_for_lua_fix") is not False: fail("Lua hot fix may not require closing WoW")
    if hot_cfg.get("reload_ui_required_for_lua_fix") is not False: fail("Lua hot fix may not require /reload")

    for key in ("enabled", "active_parallel_candidate", "active_economy_overlay", "updater_visible", "cutover_allowed"):
        if manifest.get("delivery", {}).get(key) is not False:
            fail("delivery flag must remain false: " + key)
    if "AuxEconomyShadow" in roots(parallel) or "AuxEconomyShadow" in roots(economy): fail("shadow addon became active")
    if REMOVED_DE_GUARD.exists(): fail("removed DE price guard was reintroduced")
    if "AuxVmangos_DEPriceGuard.lua" in ACTIVE_AUX_TOC.read_text(encoding="utf-8"): fail("active Aux TOC restored DE guard")

    all_lua = "\n".join(p.read_text(encoding="utf-8") for p in SHADOW.glob("*.lua"))
    for token in FORBIDDEN_ACTIONS:
        if token in all_lua: fail("forbidden AH action primitive: " + token)

    anchor = (SHADOW / "AuxEconomyShadow_Anchor.lua").read_text(encoding="utf-8")
    for token in ("W112_AH_SHADOW", "ReplaceModule", "BeginHotPayload", "EndHotPayload"):
        if token not in anchor: fail("anchor missing " + token)

    for name in MODULES:
        text = (SHADOW / name).read_text(encoding="utf-8")
        if "ReplaceModule" not in text: fail(name + " is not hot-replaceable")
        for token in FORBIDDEN_RUNTIME:
            if token in text: fail(f"{name} uses runtime/game primitive {token}")

    de_text = (SHADOW / "AuxEconomyShadow_Disenchant.lua").read_text(encoding="utf-8")
    for token in DE_FORBIDDEN:
        if token.lower() in de_text.lower(): fail("DE evaluator restored historical price anchor: " + token)
    for token in ("DepthPrice", "deSafetyMarginPct", "deAhCutPct"):
        if token not in de_text: fail("DE evaluator missing " + token)

    vendor_text = (SHADOW / "AuxEconomyShadow_Vendor.lua").read_text(encoding="utf-8")
    if vendor_text.find('"aux-learned"') > vendor_text.find('"turtle-db"'): fail("vendor priority changed")

    market = (SHADOW / "AuxEconomyShadow_MarketBook.lua").read_text(encoding="utf-8")
    for token in ("NormalizeAuction", "ItemOffers", "Snapshot"):
        if token not in market: fail("market book missing " + token)

    pipeline = (SHADOW / "AuxEconomyShadow_CandidatePipeline.lua").read_text(encoding="utf-8")
    for token in ('"vendor"', '"disenchant"', "BetterCandidate", "EvaluateBook"):
        if token not in pipeline: fail("candidate pipeline missing " + token)

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

    print("AH_CONSOLIDATION_SHADOW_V2: PASS")
    print("delivery=inactive")
    print("hot_reload=required")
    print("marketbook=pure pipeline=pure")
    print("de=pure-live-depth-no-history-cap")
    print("coordinator=single-state-machine")
    print("aux_adapter=observation-only")
    print("transaction_guard=real-actions-hard-locked")
    print("de_rollback_guard=preserved")


if __name__ == "__main__":
    main()
