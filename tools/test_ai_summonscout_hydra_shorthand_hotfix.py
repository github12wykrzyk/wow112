#!/usr/bin/env python3
"""Regression contract for live `1 to hydra` customer shorthand."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
ANCHOR = ADDON / "SummonScout_LocationAnchorHot.lua"
CORE = ADDON / "SummonScout.lua"
TOC = ADDON / "SummonScout.toc"


class HydraShorthandHotfixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.anchor = ANCHOR.read_text(encoding="utf-8")
        cls.core = CORE.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")

    def test_location_anchor_remains_hot_loaded(self):
        self.assertIn("SummonScout_LocationAnchorHot.lua", self.toc)
        self.assertIn('local VERSION = "3-explicit-api-short-alias-dict"', self.anchor)

    def test_hydra_is_exact_alias_for_hydraxian(self):
        self.assertIn("EXTRA_EXACT_ALIASES", self.anchor)
        self.assertIn('hydraxian = { "hydra" }', self.anchor)
        self.assertIn("laInstallExtraAliases", self.anchor)
        self.assertIn("table.insert(loc.aliases, alias)", self.anchor)

    def test_alias_is_installed_before_root_generation(self):
        alias_pos = self.anchor.index("S.addedAliasCount = laInstallExtraAliases(locations)")
        roots_pos = self.anchor.index("S.generatedCount = laInstallRoots(locations)")
        self.assertLess(alias_pos, roots_pos)

    def test_direct_whisper_location_is_sufficient_for_core_invite_score(self):
        # Once `hydra` resolves to Hydraxian, the canonical whisper classifier
        # already gives an explicit known destination enough score to invite.
        self.assertIn("local loc, ambiguous = findLocation(message)", self.core)
        self.assertIn("if loc then", self.core)
        self.assertIn("score = score + 3", self.core)
        self.assertIn("if score < 3 then return false", self.core)

    def test_live_phrase_is_documented_in_hot_source(self):
        self.assertIn('"1 to hydra"', self.anchor)
        self.assertIn("W112_SUMMONSCOUT_LOCATION_EXTRA_ALIASES", self.anchor)


if __name__ == "__main__":
    unittest.main()
