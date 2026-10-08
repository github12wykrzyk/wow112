import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TASK = ROOT / "runtime" / "parallel_tasks" / "summonscout-whisper-relay-chatguard-v3.json"


class SummonScoutWhisperRelayChatGuardV3Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = (ADDON / "SummonScout_WhisperRelaySpamGuardHot.lua").read_text(encoding="utf-8")
        cls.relay = (ADDON / "SummonScout_WhisperRelayHot.lua").read_text(encoding="utf-8")
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8")
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_task_tracks_integrated_lifecycle(self):
        self.assertEqual(self.task["base_parallel_sha"], "9ffc0fdb1efb5b28a9fa1c093abf442a587e75d3")
        self.assertEqual(self.task["branch"], "feature/summonscout-whisper-relay-chatguard-v3")
        self.assertEqual(self.task["status"], "integrated")
        self.assertFalse(self.task["auto_integrate"])
        self.assertEqual(self.task["integrated_feature_sha"], "3f4ceef20712a14734f6bcf5d4439293b3a96c27")
        self.assertEqual(self.task["delivery_profiles"], [])

    def test_transport_remains_real_whisper(self):
        start = self.relay.index("local function wrSendRawWhisper")
        end = self.relay.index("local function wrSendPacket", start)
        block = self.relay[start:end]
        self.assertIn('pcall(SendChatMessage, text, "WHISPER", nil, target)', block)
        self.assertIn('SendChatMessage(text, "WHISPER", nil, target)', block)

    def test_wim_is_optional_dependency_and_uses_native_block_filter(self):
        self.assertIn("## OptionalDeps: AuxVmangos, WIM", self.toc)
        self.assertIn('local WIM_FILTER_PATTERN = "%[SSWR1%]"', self.guard)
        self.assertIn('WIM_Filters[WIM_FILTER_PATTERN] = "Block"', self.guard)
        self.assertIn("sgInstallWimSuppression()", self.guard)

    def test_chatframe_global_is_never_replaced(self):
        self.assertNotIn("ChatFrame_OnEvent =", self.guard)
        self.assertNotIn("OWN_CHAT_BASE", self.guard)
        self.assertNotIn("OWN_CHAT_WRAPPER", self.guard)

    def test_live_nil_crash_path_is_structurally_removed(self):
        self.assertNotIn("return OWN_CHAT_BASE(", self.guard)
        self.assertIn('local VERSION = "', self.guard)
        self.assertIn("wim-", self.guard)

    def test_wim_filter_self_repairs_after_filter_reset_or_late_load(self):
        start = self.guard.index("local function sgWrappedOnUpdate()")
        end = self.guard.index("local function sgWrappedOnEvent", start)
        self.assertIn("sgInstallWimSuppression()", self.guard[start:end])

    def test_zero_idle_handshake_is_preserved(self):
        start = self.guard.index("local function sgHandshakeNeeded()")
        end = self.guard.index("local function sgWrappedOnUpdate()")
        block = self.guard[start:end]
        self.assertIn("if not sgRelayQueued() then return false end", block)
        self.assertIn("HELLO_MAX_IDLE_ATTEMPTS", block)

    def test_guard_adds_no_new_customer_send_path(self):
        self.assertNotIn("SendChatMessage", self.guard)


if __name__ == "__main__":
    unittest.main()
