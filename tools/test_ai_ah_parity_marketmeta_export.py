#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import ORDER, build_bundle

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
EXPORT_NAME = "AuxEconomyShadow_ParityExport.lua"
EXPORT = SHADOW / EXPORT_NAME
PARITY = SHADOW / "AuxEconomyShadow_Parity.lua"
TOC = SHADOW / "AuxEconomyShadow.toc"
MANIFEST = ROOT / "runtime" / "ah_consolidation_shadow_v2.json"


class AHParityMarketMetaExportTests(unittest.TestCase):
    def test_export_is_hot_routed_after_bridge(self):
        self.assertIn(EXPORT_NAME, ORDER)
        self.assertLess(ORDER.index("AuxEconomyShadow_ParityBridge.lua"), ORDER.index(EXPORT_NAME))
        self.assertLess(ORDER.index(EXPORT_NAME), ORDER.index("AuxEconomyShadow_HotPayload.lua"))
        toc = TOC.read_text(encoding="utf-8")
        self.assertIn(EXPORT_NAME, toc)
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertIn(
            "src/AddOns/AuxEconomyShadow/" + EXPORT_NAME,
            manifest["hot_reload"]["watch_files"],
        )
        bundle = build_bundle()
        self.assertEqual(bundle.count(("-- BEGIN " + EXPORT_NAME).encode("ascii")), 1)

    def test_export_is_observer_only_and_reversible(self):
        text = EXPORT.read_text(encoding="utf-8")
        for token in (
            'ReplaceModule("parity_export"',
            "parity.RecordDecision = state.wrapper",
            "state.parity.RecordDecision = state.originalRecordDecision",
            "AVM_DB.marketMeta.shadowParity",
            "CutoverGate",
            "decisionCompared",
            "decisionMatchPct",
        ):
            self.assertIn(token, text)
        for forbidden in (
            "PlaceAuctionBid",
            "CancelAuction",
            "PostAuction",
            "QueryAuctionItems",
            "UseContainerItem",
            "GetAuctionItemInfo",
            "GetNumAuctionItems",
            "CreateFrame(",
            "RegisterEvent(",
            "SetScript(",
            "AVM_AuxArbScanStart =",
            "AVM_AuxArbAuction =",
            "AVM_AuxArbPageDone =",
            "AVM_AuxArbScanDone =",
        ):
            self.assertNotIn(forbidden, text)

    def test_both_reject_counts_as_successful_decision_comparison(self):
        text = PARITY.read_text(encoding="utf-8")
        self.assertIn('local bothReject = tonumber(counts["both-reject"]) or 0', text)
        self.assertIn("local compared = bothReject + exactMatch +", text)
        self.assertIn("local matched = bothReject + exactMatch", text)
        for mismatch in ('counts["shadow-extra"]', 'counts["shadow-miss"]', 'counts["different-candidate"]'):
            self.assertIn(mismatch, text)


if __name__ == "__main__":
    unittest.main()
