#!/usr/bin/env python3
"""Regression contract for relation-based World summon buyer wording."""
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

    def test_relation_parser_is_word_order_independent(self):
        for cue in (
            '"lf"', '"need"', '"wtb"', '"buy"', '"want"',
            '"looking for"', '"pls"', '"inv"', '"invite"',
        ):
            self.assertIn(cue, self.hot)
        self.assertIn("brBuyerLead", self.hot)
        self.assertIn("brHasTravel", self.hot)
        self.assertIn("brTokenStarts", self.hot)
        self.assertIn('.. " lf summon"', self.hot)

    def test_wtb_plus_one_recognized_destination_is_always_buyer_signal(self):
        self.assertIn("local function brWtbLead(s)", self.hot)
        self.assertIn('brPhrase(s, "wtb") or brTokenStarts(s, "wtb")', self.hot)
        self.assertIn("if brWtbLead(normalized) then", self.hot)
        self.assertIn('return true, locations, "wtb+destination"', self.hot)
        self.assertIn("table.getn(locations) ~= 1", self.hot)
        self.assertIn("core still owns service matching, blacklist, dedupe and invite", self.hot)

    def test_short_natural_shorthand_and_typo_roots_are_supported(self):
        self.assertIn('brTokenStarts(s, "summ")', self.hot)
        self.assertIn('brTokenStarts(s, "sumon")', self.hot)
        self.assertIn('brTokenStarts(s, "port")', self.hot)
        self.assertIn('brTokenStarts(s, "tele")', self.hot)
        self.assertIn('brTokenStarts(s, "taxi")', self.hot)
        self.assertIn("brTokenCount(normalized) <= 4", self.hot)
        self.assertIn('"short-travel"', self.hot)
        self.assertIn('"travel-question"', self.hot)

    def test_destination_specific_buyer_shorthand_can_omit_summon(self):
        self.assertIn("brSpecificServiceContains(locations[1].id)", self.hot)
        self.assertIn('"buyer+served-destination"', self.hot)
        self.assertIn('"need one"', self.hot)
        self.assertIn('"one pls"', self.hot)

    def test_false_positive_guards_remain_fail_closed(self):
        self.assertIn("HARD_SELLER_CUES", self.hot)
        self.assertIn("CONTACT_CUES", self.hot)
        self.assertIn("OWN_SUMMON_CUES", self.hot)
        self.assertIn("RECRUITMENT_CUES", self.hot)
        self.assertIn("if brAny(normalized, HARD_SELLER_CUES)", self.hot)
        self.assertIn("if brAny(normalized, CONTACT_CUES) and not buyer", self.hot)
        self.assertIn("if brRecruitment(normalized)", self.hot)
        self.assertIn('"multi-destination"', self.hot)
        self.assertIn("brHasPrice", self.hot)

    def test_world_reinvite_dedupe_is_bounded_not_120_seconds(self):
        self.assertIn("local REINVITE_SECONDS = 8", self.hot)
        self.assertIn("brRelaxRecent", self.hot)
        self.assertIn("W112_SUMMONSCOUT_STATE", self.hot)
        self.assertIn("state.recent[key] = nil", self.hot)
        self.assertIn("brServiceContains(locations[1].id)", self.hot)
        self.assertIn('"reinvite-dedupe-reset"', self.hot)

    def test_debug_state_explains_why_a_line_was_classified(self):
        for field in (
            "S.lastRaw", "S.lastSender", "S.lastReason", "S.lastAccepted",
            "S.lastChanged", "S.lastRelaxedRecent", "S.lastLocation",
        ):
            self.assertIn(field, self.hot)

    def test_v3_contract_version(self):
        self.assertIn('local VERSION = "3-wtb-location-invite-reinvite8"', self.hot)
        self.assertIn("W112_SUMMONSCOUT_WORLD_BUYER_RELATION_VERSION", self.hot)


if __name__ == "__main__":
    unittest.main()
