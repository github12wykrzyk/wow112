#!/usr/bin/env python3
"""Regression contract for order-independent World summon buyer wording."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOT = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout_WorldBuyerRelationHot.lua"
TOC = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout.toc"


class WorldBuyerRelationHotfixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hot = HOT.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")

    def test_hotfix_is_loaded_before_roster_guard(self):
        relation = self.toc.index("SummonScout_WorldBuyerRelationHot.lua")
        roster = self.toc.index("SummonScout_RosterOwnershipHot.lua")
        self.assertLess(relation, roster)

    def test_destination_matching_is_catalog_driven(self):
        self.assertIn("api.GetLocationCatalog()", self.hot)
        self.assertIn("loc.aliases", self.hot)
        self.assertIn("loc.roots", self.hot)
        self.assertIn("brTokenRoot", self.hot)
        self.assertNotIn('loc.id == "hydraxian"', self.hot)
        self.assertNotIn('loc.id == "hyjal"', self.hot)

    def test_order_independent_buyer_relation_is_canonicalized(self):
        for cue in ('"lf"', '"need"', '"wtb"', '"want"', '"looking for"'):
            self.assertIn(cue, self.hot)
        self.assertIn("if table.getn(locations) ~= 1", self.hot)
        self.assertIn("if not brAny(normalized, BUYER_LEADS)", self.hot)
        self.assertIn("if not brHasTravel(normalized)", self.hot)
        self.assertIn('.. " lf summon"', self.hot)

    def test_false_positive_guards_remain_fail_closed(self):
        self.assertIn("SELLER_CUES", self.hot)
        self.assertIn("OWN_SUMMON_CUES", self.hot)
        self.assertIn("RECRUITMENT_CUES", self.hot)
        self.assertIn("if brAny(normalized, SELLER_CUES)", self.hot)
        self.assertIn("if brRecruitment(normalized)", self.hot)
        self.assertIn("table.getn(locations) ~= 1", self.hot)

    def test_live_miss_shape_is_documented_without_destination_special_case(self):
        self.assertIn("LF hydraxian summon", self.hot)
        self.assertIn('local VERSION = "1-catalog-order-independent"', self.hot)
        self.assertIn("W112_SUMMONSCOUT_WORLD_BUYER_RELATION_VERSION", self.hot)


if __name__ == "__main__":
    unittest.main()
