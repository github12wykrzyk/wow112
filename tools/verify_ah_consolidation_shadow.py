#!/usr/bin/env python3
"""Fail closed if the AH consolidation shadow can affect the active AH stack."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
PARALLEL = ROOT / "runtime" / "parallel_candidate.json"
ECONOMY = ROOT / "runtime" / "parallel_economy.json"
MANIFEST = ROOT / "runtime" / "ah_consolidation_shadow.json"

REQUIRED = {
    "README.md",
    "AuxEconomyShadow.toc",
    "AuxEconomyShadow_Contracts.lua",
    "AuxEconomyShadow_Coordinator.lua",
    "AuxEconomyShadow_AuxAdapter.lua",
}

FORBIDDEN_LUA = (
    "PlaceAuctionBid",
    "CancelAuction",
    "PostAuction",
    "QueryAuctionItems(",
    "QueryAuctionItems =",
    "GetAuctionItemInfo =",
    "CanSendAuctionQuery =",
    "RegisterEvent(\"AUCTION_",
    "SetScript(\"OnUpdate\"",
)


def fail(message: str) -> None:
    raise SystemExit("AH_CONSOLIDATION_SHADOW: FAIL: " + message)


def load_json(path: Path):
    if not path.is_file():
        fail(f"missing {path.relative_to(ROOT)}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"invalid JSON {path.relative_to(ROOT)}: {exc}")


def addon_roots(doc):
    addons = doc.get("addons") or {}
    roots = addons.get("roots") or []
    return {str(v) for v in roots}


def main() -> int:
    if not SHADOW.is_dir():
        fail("shadow source directory missing")

    names = {p.name for p in SHADOW.iterdir() if p.is_file()}
    missing = REQUIRED - names
    if missing:
        fail("missing shadow files: " + ", ".join(sorted(missing)))

    parallel = load_json(PARALLEL)
    economy = load_json(ECONOMY)
    shadow_manifest = load_json(MANIFEST)

    for label, doc in (("parallel candidate", parallel), ("economy overlay", economy)):
        if "AuxEconomyShadow" in addon_roots(doc):
            fail(f"shadow addon is active in {label}")

    delivery = shadow_manifest.get("delivery") or {}
    if delivery.get("enabled") is not False:
        fail("shadow delivery.enabled must remain false")
    if any(delivery.get(k) for k in ("active_parallel_candidate", "active_economy_overlay", "updater_visible")):
        fail("shadow delivery flags must all remain false")

    for path in sorted(SHADOW.glob("*.lua")):
        text = path.read_text(encoding="utf-8")
        for token in FORBIDDEN_LUA:
            if token in text:
                fail(f"forbidden active-AH primitive {token!r} in {path.name}")

    toc = (SHADOW / "AuxEconomyShadow.toc").read_text(encoding="utf-8")
    if "## SavedVariables: AVM_SHADOW_DB" not in toc:
        fail("shadow SavedVariables namespace is not isolated")
    if "AuxVmangos" in toc:
        fail("shadow TOC must not reuse active AuxVmangos identity")

    print("AH_CONSOLIDATION_SHADOW: PASS")
    print("base=" + str(shadow_manifest.get("base_commit") or ""))
    print("delivery=disabled active-manifests=clean action-primitives=absent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
