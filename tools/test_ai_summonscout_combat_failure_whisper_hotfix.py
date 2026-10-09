#!/usr/bin/env python3
"""Contract tests for the combat-caused summon failure customer whisper hotfix."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
HOT = ADDON / "SummonScout_CombatFailureWhisperHot.lua"
TOC = ADDON / "SummonScout.toc"


class SummonScoutCombatFailureWhisperContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hot = HOT.read_text(encoding="utf-8")
        cls.code = "\n".join(
            line for line in cls.hot.splitlines() if not line.lstrip().startswith("--")
        )
        cls.toc = TOC.read_text(encoding="utf-8").splitlines()

    def test_hotfix_is_loaded_after_grouped_resume(self):
        grouped = self.toc.index("SummonScout_GroupedResumeHot.lua")
        combat = self.toc.index("SummonScout_CombatFailureWhisperHot.lua")
        self.assertGreater(combat, grouped)

    def test_customer_gets_direct_combat_failure_whisper(self):
        self.assertIn(
            'SendChatMessage("Summon failed because you\'re in combat. Whisper r when you\'re out and I\'ll retry.", "WHISPER", nil, name)',
            self.hot,
        )

    def test_native_target_failed_requires_live_target_combat(self):
        self.assertIn('if cfTargetInCombat(name) ~= true then return false end', self.hot)
        self.assertIn('if lastError == "target-failed" then', self.hot)
        self.assertIn('nativeStatus == "target-failed"', self.hot)
        self.assertIn('ackSeq == requestSeq', self.hot)

    def test_explicit_combat_error_can_use_recent_exact_active_target(self):
        self.assertIn('cfExplicitCombatError(message)', self.hot)
        self.assertIn('S.lastActiveName', self.hot)
        self.assertIn('<= 3.0', self.hot)

    def test_dedupes_with_existing_grouped_resume_ack(self):
        self.assertIn('local G = H.GetState("groupedresume")', self.hot)
        self.assertIn('G.lastCombatAckAt[playerKey] = t', self.hot)
        self.assertIn('(t - sharedLast) < 10', self.hot)

    def test_notification_module_does_not_mutate_summon_or_trade(self):
        self.assertNotIn("CastSpell", self.code)
        self.assertNotIn("AcceptTrade", self.code)
        self.assertNotIn("finishActiveSummon", self.code)
        self.assertNotIn("queuePartySummon", self.code)
        self.assertNotIn("InviteByName", self.code)

    def test_vanilla_lua_compatibility(self):
        self.assertNotIn("string.match(", self.code)
        self.assertNotIn("table.unpack", self.code)
        self.assertNotIn("goto ", self.code)
        self.assertNotIn("continue", self.code)


if __name__ == "__main__":
    unittest.main()
