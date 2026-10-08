import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"


def normalize(text: str) -> str:
    text = (text or "").lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return " ".join(text.split())


def phrase(text: str, needle: str) -> bool:
    return f" {normalize(needle)} " in f" {normalize(text)} "


def conservative_unknown(text: str, has_destination: bool = False) -> bool:
    n = normalize(text)
    if not n or len(n.split()) <= 4:
        return False
    wait = any(phrase(n, p) for p in ("wait", "one sec", "sec", "brb", "relog", "relogging"))
    request = any(phrase(n, p) for p in ("summon", "summ", "invite", "inv", "need one", "can i get one", "could i get one", "123"))
    return wait and not request and not has_destination


class WhisperRelayMatrixV1(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = (ADDON / "SummonScout_WhisperRelayIntentGuardHot.lua").read_text(encoding="utf-8")
        cls.relay = (ADDON / "SummonScout_WhisperRelayHot.lua").read_text(encoding="utf-8")
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8").splitlines()

    def test_required_freeform_unknown_vector(self):
        self.assertTrue(conservative_unknown("yo wait sec my friend relogging xd"))
        self.assertIn('eventRow.intent = "UNKNOWN"', self.guard)

    def test_short_wait_remains_actionable(self):
        self.assertFalse(conservative_unknown("wait sec"))
        self.assertFalse(conservative_unknown("one sec"))
        self.assertIn('if igWordCount(n) <= 4 then return false end', self.guard)

    def test_second_summon_vector_is_not_overridden(self):
        self.assertFalse(conservative_unknown("can u summon my alt?"))
        self.assertIn('wrPhrase(n, "my alt")', self.relay)
        self.assertIn('return "SECOND_SUMMON"', self.relay)

    def test_thanks_vector_is_not_overridden(self):
        self.assertFalse(conservative_unknown("ty"))
        self.assertIn('return "THANKS"', self.relay)

    def test_guard_runs_after_relay(self):
        relay_idx = self.toc.index("SummonScout_WhisperRelayHot.lua")
        guard_idx = self.toc.index("SummonScout_WhisperRelayIntentGuardHot.lua")
        self.assertGreater(guard_idx, relay_idx)
        self.assertIn('local oldOnEvent = relay.OnEvent', self.guard)
        self.assertIn('relay.OnEvent = igWrappedOnEvent', self.guard)

    def test_master_relay_is_held_until_intent_is_corrected(self):
        wrapped = self.guard[self.guard.index("local function igWrappedOnEvent"):]
        self.assertIn('R.masterReady = false', wrapped)
        self.assertIn('igPatchLatestInbound(a2 or "", a1 or "")', wrapped)
        self.assertIn('R.masterReady = wasReady', wrapped)
        self.assertLess(wrapped.index('igPatchLatestInbound(a2 or "", a1 or "")'), wrapped.index('R.masterReady = wasReady'))

    def test_guard_never_sends_customer_chat(self):
        self.assertNotIn("SendChatMessage", self.guard)
        self.assertNotIn("WHISPER_OUT", self.guard)
        self.assertNotIn("PAID", self.guard)

    def test_unknown_guard_preserves_raw_identity(self):
        self.assertIn('tostring(eventRow.raw or "") == tostring(raw or "")', self.guard)
        self.assertNotIn('eventRow.raw =', self.guard)
        self.assertIn('return oldOnEvent(ev, a1, a2, a3)', self.guard)

    def test_destination_or_explicit_request_does_not_force_unknown(self):
        self.assertFalse(conservative_unknown("wait sec summon me please"))
        self.assertFalse(conservative_unknown("yo wait sec friend relogging", has_destination=True))
        self.assertIn('if igHasRequestCue(n) then return false end', self.guard)
        self.assertIn('if igHasDestination(raw) then return false end', self.guard)


if __name__ == "__main__":
    unittest.main()
