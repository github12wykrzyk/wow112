import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TASK = ROOT / "runtime" / "parallel_tasks" / "summonscout-whisper-relay-spamfix-v1.json"


class SummonScoutWhisperRelaySpamFixV1Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = (ADDON / "SummonScout_WhisperRelaySpamGuardHot.lua").read_text(encoding="utf-8")
        cls.relay = (ADDON / "SummonScout_WhisperRelayHot.lua").read_text(encoding="utf-8")
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8").splitlines()
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_v1_task_is_integrated_history(self):
        self.assertEqual(self.task["id"], "summonscout-whisper-relay-spamfix-v1")
        self.assertEqual(self.task["status"], "integrated")
        self.assertFalse(self.task["auto_integrate"])
        self.assertEqual(self.task["delivery_profiles"], [])
        self.assertEqual(len(self.task["integrated_feature_sha"]), 40)

    def test_guard_loads_after_relay_and_intent_guard(self):
        relay = self.toc.index("SummonScout_WhisperRelayHot.lua")
        intent = self.toc.index("SummonScout_WhisperRelayIntentGuardHot.lua")
        guard = self.toc.index("SummonScout_WhisperRelaySpamGuardHot.lua")
        self.assertGreater(guard, relay)
        self.assertGreater(guard, intent)

    def test_base_five_second_heartbeat_is_overridden(self):
        self.assertIn("local HELLO_MAX_IDLE_ATTEMPTS = 3", self.guard)
        self.assertIn("local HELLO_RETRY_1 = 10", self.guard)
        self.assertIn("local HELLO_RETRY_2 = 30", self.guard)
        self.assertIn("local HELLO_QUEUE_RETRY = 60", self.guard)
        self.assertIn("local HELLO_PARK = 86400", self.guard)
        self.assertIn("R.nextHelloAt = t + HELLO_PARK", self.guard)
        self.assertIn("if R.masterReady and sgSame(R.masterReadyName, master) then", self.guard)
        self.assertIn("local HELLO_INTERVAL = 5", self.relay)

    def test_zero_idle_handshake_regression(self):
        marker = "if not sgRelayQueued() then return false end"
        self.assertIn(marker, self.guard)
        start = self.guard.index("local function sgHandshakeNeeded()")
        end = self.guard.index("local function sgWrappedOnUpdate()")
        block = self.guard[start:end]
        self.assertIn(marker, block)
        self.assertIn("return (tonumber(G.helloAttempts) or 0) < HELLO_MAX_IDLE_ATTEMPTS", block)

    def test_empty_customer_whispers_are_dropped_before_capture(self):
        marker = 'if ev == "CHAT_MSG_WHISPER" and sgTrim(a1 or "") == "" then'
        self.assertIn(marker, self.guard)
        after = self.guard[self.guard.index(marker):]
        self.assertIn("return true", after[:220])
        self.assertNotIn("wrCaptureCustomer", self.guard)

    def test_transport_packets_stay_whisper_but_use_wim_native_filter(self):
        self.assertIn('local PROTO = "[SSWR1]"', self.guard)
        self.assertIn('local WIM_FILTER_PATTERN = "%[SSWR1%]"', self.guard)
        self.assertIn('WIM_Filters[WIM_FILTER_PATTERN] = "Block"', self.guard)
        self.assertIn("relay.OnEvent = sgWrappedOnEvent", self.guard)
        self.assertNotIn("ChatFrame_OnEvent =", self.guard)
        self.assertNotIn("SendChatMessage", self.guard)

    def test_shutdown_has_no_chatframe_wrapper_lifecycle(self):
        self.assertIn("if relay and relay.OnEvent == sgWrappedOnEvent then", self.guard)
        self.assertIn("if relay and relay.OnUpdate == sgWrappedOnUpdate then", self.guard)
        self.assertNotIn("OWN_CHAT_WRAPPER", self.guard)
        self.assertNotIn("OWN_CHAT_BASE", self.guard)

    def test_vanilla_lua_compatibility(self):
        self.assertNotIn("string.match(", self.guard)
        self.assertNotIn("table.unpack", self.guard)
        self.assertNotIn("goto ", self.guard)
        self.assertIn("table.getn", self.guard)


if __name__ == "__main__":
    unittest.main()
