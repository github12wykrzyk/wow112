#!/usr/bin/env python3
"""Regression contract for exact direct-whisper invite shorthand hotfix."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOT = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout_SoldInviteHot.lua"
TOC = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout.toc"


class SoldInviteHotfixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hot = HOT.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")

    def test_loaded_by_toc(self):
        self.assertIn("SummonScout_SoldInviteHot.lua", self.toc)

    def test_exact_normalized_short_replies_are_allowlisted(self):
        self.assertIn('local EXACT_INVITE_REPLIES = {', self.hot)
        self.assertIn('["sold"] = true', self.hot)
        self.assertIn('["pls"] = true', self.hot)
        self.assertIn('if not EXACT_INVITE_REPLIES[normalized] then return end', self.hot)
        self.assertNotIn('string.find(siNormalize(message), "sold"', self.hot)
        self.assertNotIn('string.find(siNormalize(message), "pls"', self.hot)

    def test_uses_canonical_invite_path(self):
        self.assertIn("W112_SUMMONSCOUT_API_V1", self.hot)
        self.assertIn("api.tryWhisperInvite", self.hot)
        self.assertNotIn("InviteByName", self.hot)

    def test_global_guards_are_preserved(self):
        self.assertIn("SummonScoutDB.whisperAutoInvite", self.hot)
        self.assertIn("state.shardGuardPaused", self.hot)
        self.assertIn("W112_SUMMONSCOUT_STATE", self.hot)

    def test_debug_records_normalized_trigger(self):
        self.assertIn("S.lastNormalized = normalized", self.hot)
        self.assertIn("SummonScout shorthand invite", self.hot)

    def test_hot_contract(self):
        self.assertIn('H.RegisterEvent("CHAT_MSG_WHISPER")', self.hot)
        self.assertIn('H.Register("soldinvite", M, VERSION)', self.hot)
        self.assertIn('local VERSION = "2-exact-sold-pls-invite"', self.hot)


if __name__ == "__main__":
    unittest.main()
