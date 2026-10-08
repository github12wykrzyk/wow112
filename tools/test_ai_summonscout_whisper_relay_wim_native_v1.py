import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TASK = ROOT / "runtime" / "parallel_tasks" / "summonscout-whisper-relay-wim-native-v1.json"


class SummonScoutWhisperRelayWimNativeV1Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = (ADDON / "SummonScout_WhisperRelayWimNativeHot.lua").read_text(encoding="utf-8")
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8").splitlines()
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_task_targets_current_canonical_and_auto_integrates(self):
        self.assertEqual(self.task["id"], "summonscout-whisper-relay-wim-native-v1")
        self.assertEqual(self.task["branch"], "feature/summonscout-whisper-relay-wim-native-v1")
        self.assertEqual(self.task["base_parallel_sha"], "37c7e663b9e1a2bbf58175abb25838b1084d758f")
        self.assertEqual(self.task["status"], "ready_for_integration")
        self.assertTrue(self.task["auto_integrate"])
        self.assertEqual(self.task["delivery_profiles"], [])

    def test_wim_bridge_loads_after_transport_trust_bridge(self):
        trust = self.toc.index("SummonScout_WhisperRelayTrustBridgeHot.lua")
        wim = self.toc.index("SummonScout_WhisperRelayWimNativeHot.lua")
        self.assertGreater(wim, trust)

    def test_transport_is_not_reimplemented(self):
        self.assertNotIn("SendChatMessage", self.lua)
        self.assertNotIn("wrSendRawWhisper", self.lua)
        self.assertNotIn('"[SSWR1]"', self.lua)
        self.assertIn("canonical [SSWR1]", self.lua)

    def test_remote_conversation_is_rendered_through_wim(self):
        self.assertIn("WIM_PostMessage", self.lua)
        self.assertIn('kind == "WHISPER_IN"', self.lua)
        self.assertIn('kind == "WHISPER_OUT_AUTO"', self.lua)
        self.assertIn('kind == "WHISPER_OUT_MASTER"', self.lua)
        self.assertIn('"|cff66ccff[via " .. summoner .. "]|r "', self.lua)

    def test_only_remote_mirrored_events_are_rendered(self):
        self.assertIn("eventRow.remote_seq == nil", self.lua)
        self.assertIn("wnSame(session.summoner_name, wnPlayer())", self.lua)
        self.assertIn("Local summoner/customer whispers are already native WIM traffic", self.lua)

    def test_existing_history_is_baselined_to_prevent_replay_spam(self):
        self.assertIn("local function wnBaselineExisting()", self.lua)
        self.assertIn("W.lastSeqBySession[sid] = tonumber(session.event_seq) or 0", self.lua)
        self.assertIn("wnBaselineExisting()", self.lua)

    def test_wim_reply_reuses_canonical_ssr_exact_owner_router(self):
        self.assertIn('SlashCmdList["SUMMONSCOUTRELAY"]', self.lua)
        self.assertIn('local command = summoner .. " " .. customer .. " " .. text', self.lua)
        self.assertIn("Reuse canonical exact-owner validation and no-retry send semantics", self.lua)

    def test_relay_window_reply_fails_closed_without_direct_customer_fallback(self):
        self.assertIn("reply blocked: canonical /ssr router unavailable", self.lua)
        self.assertIn("reply blocked: relay session is no longer ACTIVE", self.lua)
        self.assertIn("reply blocked: invalid relay ownership", self.lua)
        self.assertIn("direct send suppressed", self.lua)
        self.assertNotIn('"WHISPER"', self.lua)

    def test_slash_commands_keep_native_wim_behavior(self):
        self.assertIn('if string.sub(text, 1, 1) == "/" then', self.lua)
        self.assertIn("return false", self.lua)
        self.assertIn("local base = box and box.W112RelayBaseOnEnter or nil", self.lua)

    def test_hot_reload_wrapper_uses_global_dispatch_and_fail_closed_gap(self):
        self.assertIn("W112_SUMMONSCOUT_RELAY_WIM_DISPATCH", self.lua)
        self.assertIn("W112RelayBaseOnEnter", self.lua)
        self.assertIn("W112RelayRouterInstalled", self.lua)
        self.assertIn("relay UI is reloading; reply not sent", self.lua)

    def test_lua50_surface_is_conservative(self):
        self.assertNotIn("string.match(", self.lua)
        self.assertNotIn("table.unpack", self.lua)
        self.assertNotIn("goto ", self.lua)
        self.assertNotIn("continue", self.lua)
        self.assertIn("table.getn", self.lua)


if __name__ == "__main__":
    unittest.main()
