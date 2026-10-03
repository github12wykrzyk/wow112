#!/usr/bin/env python3
import json
import re
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import ORDER, build_bundle

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
ACTIVE = ROOT / "src" / "AddOns" / "AuxVmangos" / "AuxVmangos.lua"
MANIFEST = ROOT / "runtime" / "ah_consolidation_shadow_v2.json"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-consolidation-strategies-v1.json"
STRATEGY_FILES = (
    "AuxEconomyShadow_Flip.lua",
    "AuxEconomyShadow_Stack.lua",
    "AuxEconomyShadow_Bid.lua",
)
FORBIDDEN = (
    "PlaceAuctionBid", "CancelAuction", "PostAuction", "QueryAuctionItems", "UseContainerItem",
    "GetAuctionItemInfo", "GetNumAuctionItems", "GetMoney(", "UnitName(", "CreateFrame(",
    "RegisterEvent(", 'SetScript("OnUpdate"',
)
LUA51_LENGTH_OPERATOR = re.compile(r"#\s*[A-Za-z_(]")


class AHShadowStrategyParityTests(unittest.TestCase):
    def test_active_defaults_have_shadow_strategy_models(self):
        active = ACTIVE.read_text(encoding="utf-8")
        self.assertIn("AVM_DB.flipEnabled == nil then AVM_DB.flipEnabled = true", active)
        self.assertIn("AVM_DB.stackArbEnabled == nil then AVM_DB.stackArbEnabled = true", active)
        self.assertIn("AVM_DB.bidArbEnabled == nil then AVM_DB.bidArbEnabled = true", active)
        for name in STRATEGY_FILES:
            self.assertTrue((SHADOW / name).is_file(), name)

    def test_strategy_modules_are_pure_and_lua50_safe(self):
        for name in STRATEGY_FILES:
            text = (SHADOW / name).read_text(encoding="utf-8")
            self.assertIn("ReplaceModule", text)
            for token in FORBIDDEN:
                self.assertNotIn(token, text, f"{name}: {token}")
            for raw in text.splitlines():
                code = raw.split("--", 1)[0]
                self.assertIsNone(LUA51_LENGTH_OPERATOR.search(code), f"{name}: Lua 5.1 # operator")

    def test_de_history_rollback_boundary_is_preserved(self):
        de = (SHADOW / "AuxEconomyShadow_Disenchant.lua").read_text(encoding="utf-8").lower()
        for token in ("aux.core.history", "history.value", "data_points", "dehistorycaphits"):
            self.assertNotIn(token, de)
        flip = (SHADOW / "AuxEconomyShadow_Flip.lua").read_text(encoding="utf-8")
        self.assertIn("historyByKey", flip)
        self.assertNotIn("aux.core.history", flip)

    def test_postscan_buyout_precedes_bid_fallback(self):
        pipeline = (SHADOW / "AuxEconomyShadow_CandidatePipeline.lua").read_text(encoding="utf-8")
        buyout = pipeline.find("selectedPostscan = postscanBestAffordable")
        fallback = pipeline.find("if not selectedPostscan and bestBidLive")
        marker = pipeline.find('selectionSource = "bid-fallback"')
        self.assertGreaterEqual(buyout, 0)
        self.assertGreater(fallback, buyout)
        self.assertGreater(marker, fallback)
        for name in ('"disenchant"', '"flip"', '"stack"'):
            self.assertIn(name, pipeline)

    def test_bid_contract_matches_current_active_guards(self):
        bid = (SHADOW / "AuxEconomyShadow_Bid.lua").read_text(encoding="utf-8")
        for token in (
            "bidVendorMarginPct", "bidDeMarginPct", "bidMinProfit", "bidMaxAmount",
            "bidMaxDuration", "bidMaxSessionPlacements", "has-buyout", "high-bidder",
        ):
            self.assertIn(token, bid)
        contracts = (SHADOW / "AuxEconomyShadow_Contracts.lua").read_text(encoding="utf-8")
        for token in ("NormalizeListing", "bid_price", "blizzard_bid", "start_price"):
            self.assertIn(token, contracts)

    def test_manifest_toc_and_bundle_are_complete(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        watches = set(manifest["hot_reload"]["watch_files"])
        toc = (SHADOW / "AuxEconomyShadow.toc").read_text(encoding="utf-8")
        for name in STRATEGY_FILES:
            self.assertIn("src/AddOns/AuxEconomyShadow/" + name, watches)
            self.assertIn(name, toc)
            self.assertIn(name, ORDER)
        self.assertEqual(manifest["stage"], "full_strategy_model_ready_for_passive_parity")
        self.assertFalse(manifest["delivery"]["cutover_allowed"])
        bundle = build_bundle()
        for name in STRATEGY_FILES:
            self.assertIn(("-- BEGIN " + name).encode("ascii"), bundle)

    def test_task_is_economy_gated_and_queue_ready(self):
        task = json.loads(TASK.read_text(encoding="utf-8"))
        self.assertEqual(task["branch"], "feature/ah-consolidation-strategies-v1")
        self.assertEqual(task["base_parallel_sha"], "3eb8ea2008c3889944409c907af207e820c69216")
        self.assertEqual(task["status"], "ready_for_integration")
        self.assertTrue(task["auto_integrate"])
        self.assertEqual(task["delivery_profiles"], ["economy"])
        lease = task.get("lease") or {}
        self.assertEqual(lease.get("owner"), "chatgpt:ah-strategies-v1")
        self.assertIn("module:AuxEconomyShadow", lease.get("scopes", []))
        self.assertNotIn("resource:hot-lua-runtime", lease.get("scopes", []))


if __name__ == "__main__":
    unittest.main()
