#!/usr/bin/env python3
"""Contract tests for SummonScout Engine V2 P0.2 explicit compatibility API."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
FOUNDATION = ADDON / "SummonScout_EngineV2FoundationHot.lua"
GROUPED = ADDON / "SummonScout_GroupedResumeHot.lua"
ROSTER = ADDON / "SummonScout_RosterOwnershipHot.lua"
LOCATION = ADDON / "SummonScout_LocationAnchorHot.lua"
TOC = ADDON / "SummonScout.toc"


class SummonScoutExplicitApiContract(unittest.TestCase):
    def text(self, path):
        return path.read_text(encoding="utf-8")

    def test_foundation_owns_legacy_introspection(self):
        text = self.text(FOUNDATION)
        self.assertIn("W112_SUMMONSCOUT_API_V1 = api", text)
        self.assertIn("W112_SUMMONSCOUT_STATE = state", text)
        self.assertIn("api.FindLocation", text)
        self.assertIn("api.GetLocationCatalog", text)
        self.assertIn("api.InstallLocationRootMatcher", text)
        self.assertIn("api.InstallRosterQueueGuard", text)
        self.assertIn("debug.getupvalue", text)
        self.assertIn("debug.setupvalue", text)

    def test_consumers_do_not_walk_core_upvalues(self):
        for path in (GROUPED, ROSTER, LOCATION):
            text = self.text(path)
            self.assertNotIn("debug.getupvalue", text, path.name)
            self.assertNotIn("debug.setupvalue", text, path.name)
            self.assertNotIn("GetScript(\"OnEvent\")", text, path.name)
            self.assertIn("W112_SUMMONSCOUT_API_V1", text, path.name)

    def test_grouped_resume_uses_explicit_state_and_queue_contract(self):
        text = self.text(GROUPED)
        self.assertIn("W112_SUMMONSCOUT_STATE", text)
        self.assertIn("QueuePartySummonExplicit", text)
        self.assertIn('"grouped-resume"', text)
        self.assertIn('"combat-resume"', text)

    def test_roster_and_location_use_foundation_adapters(self):
        roster = self.text(ROSTER)
        location = self.text(LOCATION)
        self.assertIn("api.FindLocation", roster)
        self.assertIn("api.InstallRosterQueueGuard", roster)
        self.assertIn("api.GetLocationCatalog", location)
        self.assertIn("api.InstallLocationRootMatcher", location)

    def test_foundation_loads_before_api_consumers(self):
        lines = [line.strip() for line in self.text(TOC).splitlines() if line.strip() and not line.startswith("##")]
        foundation = lines.index("SummonScout_EngineV2FoundationHot.lua")
        for name in (
            "SummonScout_LocationAnchorHot.lua",
            "SummonScout_GroupedResumeHot.lua",
            "SummonScout_RosterOwnershipHot.lua",
        ):
            self.assertLess(foundation, lines.index(name), name)


if __name__ == "__main__":
    unittest.main()
