import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TASK = ROOT / "runtime" / "parallel_tasks" / "summonscout-whisper-relay-spamfix-v2.json"


class SummonScoutWhisperRelaySpamFixV2Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = (ADDON / "SummonScout_WhisperRelaySpamGuardHot.lua").read_text(encoding="utf-8")
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_task_targets_current_canonical_and_auto_integrates(self):
        self.assertEqual(self.task["base_parallel_sha"], "1d0f1a5690fc32bb5d31d93daf24da08363f3bf7")
        self.assertEqual(self.task["branch"], "feature/summonscout-whisper-relay-spamfix-v2")
        self.assertEqual(self.task["status"], "ready_for_integration")
        self.assertTrue(self.task["auto_integrate"])
        self.assertEqual(self.task["delivery_profiles"], [])

    def test_version_is_demand_only(self):
        self.assertIn('local VERSION = "2-demand-only-handshake-hidden-control"', self.guard)

    def test_idle_queue_is_absolute_handshake_stop(self):
        start = self.guard.index("local function sgHandshakeNeeded()")
        end = self.guard.index("local function sgWrappedOnUpdate()")
        block = self.guard[start:end]
        self.assertIn("if not sgRelayQueued() then return false end", block)
        self.assertIn("return (tonumber(G.helloAttempts) or 0) < HELLO_MAX_IDLE_ATTEMPTS", block)
        self.assertNotIn("return sgRelayQueued()", block)

    def test_login_parks_hello_without_emitting(self):
        marker = 'if ev == "PLAYER_LOGIN" then'
        self.assertIn(marker, self.guard)
        after = self.guard[self.guard.index(marker):]
        self.assertIn("sgResetHandshake(sgMaster())", after[:260])
        self.assertIn("R.nextHelloAt = sgNow() + HELLO_PARK", after[:320])

    def test_real_queue_can_arm_bounded_handshake(self):
        self.assertIn('elseif ev == "CHAT_MSG_WHISPER" and not R.masterReady and sgRelayQueued() then', self.guard)
        self.assertIn("G.nextHelloAllowedAt = 0", self.guard)
        self.assertIn("R.nextHelloAt = 0", self.guard)
        self.assertIn("if G.helloAttempts >= HELLO_MAX_IDLE_ATTEMPTS then", self.guard)
        self.assertIn("G.nextHelloAllowedAt = t + HELLO_PARK", self.guard)

    def test_guard_never_sends_chat_itself(self):
        self.assertNotIn("SendChatMessage", self.guard)

    def test_hot_wrapper_contract_is_preserved(self):
        self.assertIn("relay.OnEvent = sgWrappedOnEvent", self.guard)
        self.assertIn("relay.OnUpdate = sgWrappedOnUpdate", self.guard)
        self.assertIn('H.Register("whisperrelayspamguard", M, VERSION)', self.guard)


if __name__ == "__main__":
    unittest.main()
