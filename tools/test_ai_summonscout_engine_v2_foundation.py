#!/usr/bin/env python3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"


class SummonEngineV2FoundationTests(unittest.TestCase):
    def test_foundation_is_loaded_after_existing_hot_guards(self):
        toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8")
        roster = toc.index("SummonScout_RosterOwnershipHot.lua")
        foundation = toc.index("SummonScout_EngineV2FoundationHot.lua")
        self.assertGreater(foundation, roster)

    def test_public_runtime_surface_is_exported(self):
        text = (ADDON / "SummonScout_EngineV2FoundationHot.lua").read_text(encoding="utf-8")
        self.assertIn("W112_SUMMONSCOUT_API_V1 = api", text)
        self.assertIn("W112_SUMMONSCOUT_STATE = state", text)
        self.assertIn("W112_SUMMONSCOUT_API_VERSION = 1", text)
        self.assertIn("QueuePartySummonExplicit", text)
        self.assertIn("HasInviteOwnership", text)

    def test_system_join_ownership_bypass_is_closed_fail_closed(self):
        text = (ADDON / "SummonScout_EngineV2FoundationHot.lua").read_text(encoding="utf-8")
        self.assertIn('event == "CHAT_MSG_SYSTEM"', text)
        self.assertIn("pendingManualInvites", text)
        self.assertIn("not fHasInviteOwnership(state, joined)", text)
        self.assertIn("SummonScoutDB.partyAutoSummon = false", text)
        self.assertNotIn("debug.setupvalue", text)

    def test_existing_core_path_that_needs_guard_remains_identified(self):
        core = (ADDON / "SummonScout.lua").read_text(encoding="utf-8")
        self.assertIn('if event == "CHAT_MSG_SYSTEM" then', core)
        self.assertIn("EventAPI.queuePartySummon(joinedName)", core)
        self.assertIn("SS.pendingManualInvites[EventAPI.lower(joinedName)] = nil", core)


if __name__ == "__main__":
    unittest.main()
