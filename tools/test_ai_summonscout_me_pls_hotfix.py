from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"

class MePleaseHotfixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hot = (ADDON / "SummonScout_WhisperMePlease.lua").read_text(encoding="utf-8")
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8")

    def test_loaded_cold(self):
        self.assertIn("SummonScout_WhisperMePlease.lua", self.toc)
        self.assertNotIn("SummonScout_WhisperMePleaseHot.lua", self.toc)

    def test_exact_polite_me_variants(self):
        self.assertIn('n == "me pls"', self.hot)
        self.assertIn('n == "me plz"', self.hot)
        self.assertIn('n == "me please"', self.hot)

    def test_uses_canonical_classifier_and_invite_path(self):
        self.assertIn('api.whisperInviteDecision, "invite me"', self.hot)
        self.assertIn("api.tryWhisperInvite", self.hot)
        self.assertNotIn("InviteByName", self.hot)

    def test_does_not_promote_summoning_confirmation_to_request(self):
        self.assertNotIn('n == "summoning you to winterspring"', self.hot.lower())
        self.assertNotIn('string.find(n, "summoning you to"', self.hot.lower())

    def test_lua50_safe(self):
        self.assertNotIn("table.unpack", self.hot)
        self.assertNotIn("goto ", self.hot)

if __name__ == "__main__":
    unittest.main()
