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

REQUIRED = [
    TASK,
    MANIFEST,
    SHADOW / "README.md",
    SHADOW / "AuxEconomyShadow.toc",
    SHADOW / "AuxEconomyShadow_Anchor.lua",
    SHADOW / "AuxEconomyShadow_Contracts.lua",
    SHADOW / "AuxEconomyShadow_Vendor.lua",
    SHADOW / "AuxEconomyShadow_Disenchant.lua",
    SHADOW / "AuxEconomyShadow_HotPayload.lua",
]

FORBIDDEN_ACTIONS = (
    "PlaceAuctionBid",
    "CancelAuction",
    "PostAuction",
    "QueryAuctionItems",
    "UseContainerItem",
)
PURE_STRATEGY_FORBIDDEN = (
    "GetAuctionItemInfo",
    "GetNumAuctionItems",
    "GetMoney(",
    "UnitName(",
    "CreateFrame(",
    "RegisterEvent(",
)
DE_FORBIDDEN = (
    "AVM_AUX_HISTORY",
    "aux.core.history",
    "history.value",
    "data_points",
    "history-cap",
    "history cap",
)


def fail(message: str) -> None:
    raise SystemExit(f"AH_CONSOLIDATION_SHADOW_V2: FAIL: {message}")


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"cannot read {path.relative_to(ROOT)}: {exc}")


def addon_roots(data: dict) -> set[str]:
    roots: set[str] = set()
    addons = data.get("addons")
    if isinstance(addons, dict):
        for value in addons.get("roots", []):
            if isinstance(value, str):
                roots.add(value)
    for key in ("addon_roots", "roots"):
        values = data.get(key, [])
        if isinstance(values, list):
            for value in values:
                if isinstance(value, str):
                    roots.add(value)
    return roots


def main() -> None:
    missing = [str(path.relative_to(ROOT)) for path in REQUIRED if not path.is_file()]
    if missing:
        fail("missing files: " + ", ".join(missing))

    task = load_json(TASK)
    manifest = load_json(MANIFEST)
    parallel = load_json(PARALLEL)
    economy = load_json(ECONOMY) if ECONOMY.is_file() else {}

    if task.get("branch") != "feature/ah-consolidation-hotreload-v2":
        fail("task branch mismatch")
    if task.get("status") not in {"coding", "preflight", "blocked"}:
        fail("unexpected task status for inactive shadow")
    if task.get("auto_integrate") is not False:
        fail("shadow task must not auto-integrate")
    if task.get("delivery_profiles") != []:
        fail("inactive shadow must not declare delivery profiles yet")

    if manifest.get("base_parallel_sha") != task.get("base_parallel_sha"):
        fail("manifest/task base SHA mismatch")
    delivery = manifest.get("delivery", {})
    for key in ("enabled", "active_parallel_candidate", "active_economy_overlay", "updater_visible", "cutover_allowed"):
        if delivery.get(key) is not False:
            fail(f"delivery flag {key} must remain false")

    if "AuxEconomyShadow" in addon_roots(parallel):
        fail("shadow addon is active in parallel candidate")
    if "AuxEconomyShadow" in addon_roots(economy):
        fail("shadow addon is active in ECONOMY overlay")

    if REMOVED_DE_GUARD.exists():
        fail("removed DE price/history guard was reintroduced")
    aux_toc = ACTIVE_AUX_TOC.read_text(encoding="utf-8")
    if "AuxVmangos_DEPriceGuard.lua" in aux_toc:
        fail("active AuxVmangos.toc reintroduced DE price/history guard")

    lua_files = list(SHADOW.glob("*.lua"))
    lua_text = "\n".join(path.read_text(encoding="utf-8") for path in lua_files)
    for token in FORBIDDEN_ACTIONS:
        if token in lua_text:
            fail(f"shadow contains forbidden AH action primitive: {token}")

    anchor = (SHADOW / "AuxEconomyShadow_Anchor.lua").read_text(encoding="utf-8")
    for token in ("W112_AH_SHADOW", "ReplaceModule", "BeginHotPayload", "EndHotPayload"):
        if token not in anchor:
            fail(f"persistent anchor missing hot contract token: {token}")

    for name in ("AuxEconomyShadow_Contracts.lua", "AuxEconomyShadow_Vendor.lua", "AuxEconomyShadow_Disenchant.lua"):
        text = (SHADOW / name).read_text(encoding="utf-8")
        if "ReplaceModule" not in text:
            fail(f"hot module does not use ReplaceModule: {name}")
        for token in PURE_STRATEGY_FORBIDDEN:
            if token in text:
                fail(f"pure strategy {name} uses game/runtime primitive: {token}")

    de_text = (SHADOW / "AuxEconomyShadow_Disenchant.lua").read_text(encoding="utf-8")
    for token in DE_FORBIDDEN:
        if token.lower() in de_text.lower():
            fail(f"DE evaluator reintroduced forbidden historical price anchor: {token}")
    if "DepthPrice" not in de_text or "deSafetyMarginPct" not in de_text or "deAhCutPct" not in de_text:
        fail("DE evaluator missing live-depth/cut/margin contract")

    vendor_text = (SHADOW / "AuxEconomyShadow_Vendor.lua").read_text(encoding="utf-8")
    if vendor_text.find('"aux-learned"') > vendor_text.find('"turtle-db"'):
        fail("vendor source priority changed: aux-learned must remain before Turtle fallback")

    hot = (SHADOW / "AuxEconomyShadow_HotPayload.lua").read_text(encoding="utf-8")
    if "CreateFrame(" in hot or "RegisterEvent(" in hot or "ADDON_LOADED" in hot:
        fail("hot payload may not create unmanaged frame/event ownership")

    toc = (SHADOW / "AuxEconomyShadow.toc").read_text(encoding="utf-8")
    if "AVM_SHADOW_DB" not in toc:
        fail("shadow SavedVariables namespace is not isolated")
    expected_order = [
        "AuxEconomyShadow_Anchor.lua",
        "AuxEconomyShadow_Contracts.lua",
        "AuxEconomyShadow_Vendor.lua",
        "AuxEconomyShadow_Disenchant.lua",
        "AuxEconomyShadow_HotPayload.lua",
    ]
    pos = -1
    for name in expected_order:
        next_pos = toc.find(name)
        if next_pos <= pos:
            fail("shadow TOC hot module order is invalid")
        pos = next_pos

    print("AH_CONSOLIDATION_SHADOW_V2: PASS")
    print(f"base_parallel_sha={manifest['base_parallel_sha']}")
    print("delivery=inactive")
    print("hot_reload_contract=persistent-anchor+replaceable-modules")
    print("vendor_evaluator=pure")
    print("de_evaluator=pure-live-depth-no-history-cap")
    print("de_rollback_guard=preserved")


if __name__ == "__main__":
    main()
