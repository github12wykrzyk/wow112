#!/usr/bin/env python3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "src" / "AddOns" / "AuxEconomyShadow" / "AuxEconomyShadow_ParityBridge.lua"
SUMMON_TOC = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout.toc"


class AHParityEvidenceHardeningTests(unittest.TestCase):
    def test_scan_done_reads_active_consumed_candidate_locations(self):
        text = BRIDGE.read_text(encoding="utf-8")
        self.assertIn('REVISION = "2-scan-done-evidence-hardening"', text)
        self.assertIn("arb.postscanCandidate", text)
        self.assertIn("arb.candidate", text)
        self.assertIn("avm.candidate", text)
        self.assertIn("avm.bidCandidate", text)
        self.assertIn('return avm.bidCandidate, "AVM.bidCandidate"', text)

    def test_scan_done_compares_full_shadow_selection_including_bid_fallback(self):
        text = BRIDGE.read_text(encoding="utf-8")
        self.assertIn("shadowCandidate = result.selected", text)
        self.assertNotIn("shadowCandidate = result.selectedPostscan", text)
        self.assertIn("state.lastShadowSource", text)
        self.assertIn("state.lastActiveSource", text)

    def test_bridge_remains_passive(self):
        text = BRIDGE.read_text(encoding="utf-8")
        for token in (
            "PlaceAuctionBid", "CancelAuction", "PostAuction", "QueryAuctionItems", "UseContainerItem",
            "GetAuctionItemInfo", "GetNumAuctionItems", "CreateFrame(", "RegisterEvent(", 'SetScript("OnUpdate"',
            "AUXFAST_RestartSearch", "AUXFAST_ResumeSearch",
        ):
            self.assertNotIn(token, text)
        for token in (
            "state.originals.scanStart(resume, filterString)",
            "state.originals.auction(raw)",
            "state.originals.pageDone(page, lastPage)",
            "state.originals.scanDone()",
        ):
            self.assertEqual(text.count(token), 1)

    def test_cold_start_orders_summonscout_after_auxvmangos_when_present(self):
        toc = SUMMON_TOC.read_text(encoding="utf-8")
        self.assertIn("## OptionalDeps: AuxVmangos", toc)
        self.assertLess(toc.find("## OptionalDeps: AuxVmangos"), toc.find("SummonScout_PostPaymentOfferHot.lua"))


if __name__ == "__main__":
    unittest.main()
