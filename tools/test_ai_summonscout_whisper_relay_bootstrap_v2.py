import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TASK = ROOT / "runtime" / "parallel_tasks" / "summonscout-whisper-relay-bootstrap-v2.json"


class SummonScoutWhisperRelayBootstrapV2Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = (ADDON / "SummonScout_WhisperRelayTrustBridgeHot.lua").read_text(encoding="utf-8")
        cls.bridge_code = "\n".join(
            line for line in cls.bridge.splitlines() if not line.lstrip().startswith("--")
        )
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8").splitlines()
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_task_targets_exact_current_canonical_and_auto_integrates(self):
        self.assertEqual(self.task["id"], "summonscout-whisper-relay-bootstrap-v2")
        self.assertEqual(self.task["branch"], "feature/summonscout-whisper-relay-bootstrap-v2")
        self.assertEqual(self.task["base_parallel_sha"], "4511245836cedb06f2161047fd194507bca85ccf")
        self.assertEqual(self.task["status"], "ready_for_integration")
        self.assertTrue(self.task["auto_integrate"])
        self.assertEqual(self.task["delivery_profiles"], [])

    def test_bridge_loads_after_spam_guard(self):
        spam = self.toc.index("SummonScout_WhisperRelaySpamGuardHot.lua")
        bridge = self.toc.index("SummonScout_WhisperRelayTrustBridgeHot.lua")
        self.assertGreater(bridge, spam)

    def test_h_breaks_only_the_circular_bootstrap(self):
        self.assertIn('if code == "H" then', self.bridge)
        self.assertIn("tbRememberHello(sender)", self.bridge)
        self.assertIn("return tbCallTemporarilyTrusted(ev, a1, a2, a3)", self.bridge)
        self.assertIn('local PROTO = "[SSWR1]"', self.bridge)

    def test_data_packets_require_runtime_peer_established_by_h(self):
        self.assertIn('return code == "I" or code == "IB" or code == "IC" or code == "E"', self.bridge)
        self.assertIn("tbSummonerDataCode(code) and tbKnownPeer(sender)", self.bridge)
        self.assertIn("B.peers[key]", self.bridge)

    def test_master_reply_acl_is_never_bridged(self):
        data_line = 'return code == "I" or code == "IB" or code == "IC" or code == "E"'
        self.assertIn(data_line, self.bridge)
        self.assertNotIn('code == "R" or', self.bridge)
        self.assertNotIn('code == "RB" or', self.bridge)
        self.assertNotIn('code == "RC" or', self.bridge)
        self.assertIn("K/R/RB/RC", self.bridge)

    def test_trust_admission_is_temporary_and_restored(self):
        self.assertIn("local previous = D.trustedSummoners[key]", self.bridge)
        self.assertIn("local hadPrevious = previous ~= nil", self.bridge)
        self.assertIn("D.trustedSummoners[key] = sender", self.bridge)
        self.assertIn("D.trustedSummoners[key] = previous", self.bridge)
        self.assertIn("D.trustedSummoners[key] = nil", self.bridge)

    def test_bridge_does_not_create_any_chat_send_path(self):
        self.assertNotIn("SendChatMessage", self.bridge_code)
        self.assertNotIn("CastSpell", self.bridge_code)
        self.assertNotIn("AcceptTrade", self.bridge_code)

    def test_runtime_peers_reset_on_login(self):
        self.assertIn('if ev == "PLAYER_LOGIN" then', self.bridge)
        self.assertIn("B.peers = {}", self.bridge)

    def test_vanilla_lua_compatibility(self):
        self.assertNotIn("string.match(", self.bridge_code)
        self.assertNotIn("table.unpack", self.bridge_code)
        self.assertNotIn("goto ", self.bridge_code)
        self.assertNotIn("continue", self.bridge_code)


if __name__ == "__main__":
    unittest.main()
