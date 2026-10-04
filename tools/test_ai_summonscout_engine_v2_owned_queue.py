#!/usr/bin/env python3
"""Contract tests for SummonScout Engine V2 owned queue API."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
FOUNDATION = ADDON / "SummonScout_EngineV2FoundationHot.lua"
GROUPED = ADDON / "SummonScout_GroupedResumeHot.lua"


class SummonScoutOwnedQueueApiContract(unittest.TestCase):
    def text(self, path):
        return path.read_text(encoding="utf-8")

    def test_foundation_publishes_owned_queue_boundary(self):
        text = self.text(FOUNDATION)
        self.assertIn("S.rawQueuePartySummon = rawQueue", text)
        self.assertIn("S.publicQueuePartySummon = publicQueue", text)
        self.assertIn("api.queuePartySummon = publicQueue", text)
        self.assertIn("api.QueuePartySummonExplicit = explicitQueue", text)
        self.assertNotIn("api.RawQueuePartySummon", text)

    def test_default_public_queue_requires_invite_ownership(self):
        text = self.text(FOUNDATION)
        self.assertIn('return false, "ownership-required"', text)
        self.assertIn("if not fHasInviteOwnership(state, name) then", text)
        self.assertIn('return true, "owned-join"', text)

    def test_grouped_and_combat_resume_require_real_group_membership(self):
        text = self.text(FOUNDATION)
        self.assertIn('source == "grouped-resume" or source == "combat-resume"', text)
        self.assertIn('if not fInGroup(api, name) then return false, "not-grouped" end', text)
        self.assertIn('source ~= "manual-explicit"', text)

    def test_grouped_resume_cannot_bypass_when_explicit_api_is_present(self):
        grouped = self.text(GROUPED)
        foundation = self.text(FOUNDATION)
        self.assertIn("QueuePartySummonExplicit", grouped)
        self.assertIn("api.queuePartySummon(name)", grouped)
        self.assertIn("api.queuePartySummon = publicQueue", foundation)
        self.assertIn('return false, "ownership-required"', foundation)

    def test_p01_event_guard_remains_defense_in_depth(self):
        text = self.text(FOUNDATION)
        self.assertIn('event == "CHAT_MSG_SYSTEM"', text)
        self.assertIn("not fHasInviteOwnership(state, joined)", text)
        self.assertIn("SummonScoutDB.partyAutoSummon = false", text)


if __name__ == "__main__":
    unittest.main()
