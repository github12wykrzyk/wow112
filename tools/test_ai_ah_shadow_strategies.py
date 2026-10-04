#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import ORDER, build_bundle

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
MANIFEST = ROOT / "runtime" / "ah_consolidation_shadow_v2.json"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-consolidation-strategies-v1.json"

STRATEGY_FILES = (
    "AuxEconomyShadow_Flip.lua",
    "AuxEconomyShadow_Stack.lua",
    "AuxEconomyShadow_Bid.lua",
)


class AHShadowStrategyParityTests(unittest.TestCase):
    def test_active_defaults_have_shadow_strategy_models(self):
        flip = (SHADOW / "AuxEconomyShadow_Flip.lua").read_text(encoding="utf-8")
        stack = (SHADOW / "AuxEconomyShadow_Stack.lua").read_text(encoding="utf-8")
        for token in (
            "flipDepthUnits",
            "flipHistMaxPct",
            "flipMinSellers",
            "flipMaxItemSpend",
            "historyByKey",
        ):
            self.assertIn(token, flip)
        for token in (
            "stackSmallPct",
            "stackLargePct",
            "stackSmallDepthUnits",
            "stackMinSmallSellers",
        ):
            self.assertIn(token, stack)

    def test_postscan_buyout_precedes_bid_fallback(self):
        pipeline = (SHADOW / "AuxEconomyShadow_CandidatePipeline.lua").read_text(encoding="utf-8")
        selection = (
            'local selectedPostscan = postscanBestAffordable\n'
            '        local selectionSource = selectedPostscan and "buyout" or nil\n'
            '        if not selectedPostscan and bestBidLive then\n'
            '            selectedPostscan = bestBidLive\n'
            '            selectionSource = "bid-fallback"'
        )
        self.assertIn(selection, pipeline)

    def test_de_history_rollback_boundary_is_preserved(self):
        de = (SHADOW / "AuxEconomyShadow_Disenchant.lua").read_text(encoding="utf-8").lower()
        for forbidden in (
            "aux.core.history",
            "avm_aux_history",
            "history.value",
            "data_points",
            "depriceguard",
            "dehistorycaphits",
        ):
            self.assertNotIn(forbidden, de)

    def test_strategy_modules_are_pure_and_lua50_safe(self):
        for name in STRATEGY_FILES:
            text = (SHADOW / name).read_text(encoding="utf-8")
            self.assertIn("ReplaceModule", text)
            for forbidden in (
                "PlaceAuctionBid",
                "CancelAuction",
                "PostAuction",
                "QueryAuctionItems",
                "GetAuctionItemInfo",
                "GetNumAuctionItems",
                "CreateFrame(",
                "RegisterEvent(",
                'SetScript("OnUpdate"',
            ):
                self.assertNotIn(forbidden, text)

    def test_bid_contract_matches_current_active_guards(self):
        bid = (SHADOW / "AuxEconomyShadow_Bid.lua").read_text(encoding="utf-8")
        for token in (
            "bidVendorMarginPct",
            "bidDeMarginPct",
            "bidMaxAmount",
            "bidMaxDuration",
            "bidMaxSessionPlacements",
            "has-buyout",
            "high-bidder",
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
        bridge = "AuxEconomyShadow_ParityBridge.lua"
        exporter = "AuxEconomyShadow_ParityExport.lua"
        cutover = "AuxEconomyShadow_Cutover.lua"
        direct_live = "AuxEconomyShadow_DirectLive.lua"
        for name in (bridge, exporter, cutover, direct_live):
            self.assertIn("src/AddOns/AuxEconomyShadow/" + name, watches)
            self.assertIn(name, toc)
            self.assertIn(name, ORDER)
        self.assertLess(ORDER.index(cutover), ORDER.index(direct_live))
        self.assertLess(ORDER.index(direct_live), ORDER.index("AuxEconomyShadow_HotPayload.lua"))
        self.assertEqual(manifest["stage"], "direct_live_active_shadow_observer")
        self.assertFalse(manifest["delivery"]["cutover_allowed"])
        self.assertEqual(manifest["delivery"]["authoritative_live_module"], "AuxVmangos")
        self.assertTrue(manifest["safety"]["real_actions_fail_closed"])
        self.assertTrue(manifest["safety"]["real_actions_hard_locked"])
        self.assertFalse(manifest["safety"]["may_submit_transactions"])
        bundle = build_bundle()
        for name in STRATEGY_FILES + (bridge, exporter, cutover, direct_live):
            self.assertIn(("-- BEGIN " + name).encode("ascii"), bundle)

    def test_task_is_economy_gated_and_integrated(self):
        task = json.loads(TASK.read_text(encoding="utf-8"))
        self.assertEqual(task["branch"], "feature/ah-consolidation-strategies-v1")
        self.assertEqual(task["base_parallel_sha"], "3eb8ea2008c3889944409c907af207e820c69216")
        self.assertEqual(task["status"], "integrated")
        self.assertFalse(task["auto_integrate"])
        self.assertEqual(task["delivery_profiles"], ["economy"])
        self.assertEqual(task["integrated_feature_sha"], "ed4f1ac8769ce1e665b690a792eb3b06f926eba1")
        self.assertIsNone(task.get("lease"))


if __name__ == "__main__":
    unittest.main()
