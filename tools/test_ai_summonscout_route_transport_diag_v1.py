from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LUA = (ROOT / "src/AddOns/SummonScout/SummonScout_RouteTransportDiag.lua").read_text(encoding="utf-8")
TOC = (ROOT / "src/AddOns/SummonScout/SummonScout.toc").read_text(encoding="utf-8")


class RouteTransportDiagContract(unittest.TestCase):
    def test_loaded_after_ack_bridge(self):
        self.assertIn("## Version: 1.84", TOC)
        self.assertIn("SummonScout_RouteTransportDiag.lua", TOC)
        self.assertLess(TOC.index("SummonScout_RouteAckHubFix.lua"), TOC.index("SummonScout_RouteTransportDiag.lua"))

    def test_observes_transaction_submit_and_delivery(self):
        for marker in ("TX_X_SUBMIT", "TX_A_SUBMIT", "INFORM_X", "INFORM_A", "RX_X", "RX_A", "ACK_EVAL"):
            self.assertIn(marker, LUA)
        self.assertIn('frame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")', LUA)
        self.assertIn('frame:RegisterEvent("CHAT_MSG_SYSTEM")', LUA)
        self.assertIn('frame:RegisterEvent("UI_ERROR_MESSAGE")', LUA)

    def test_no_mutation_retry_or_invite(self):
        forbidden = (
            "InviteByName",
            "CastSpell",
            "CastSpellByName",
            "Ritual of Summoning",
            "SendMail",
            "TakeInbox",
            "CancelAuction",
        )
        for token in forbidden:
            self.assertNotIn(token, LUA)
        self.assertNotIn("retry", LUA.lower())
        self.assertNotIn("C_Timer", LUA)

    def test_send_wrapper_is_observer_only(self):
        self.assertIn("R.sendBase = SendChatMessage", LUA)
        self.assertIn("return base(message, chatType, language, target)", LUA)
        self.assertIn("pcall(observeSubmit", LUA)
        self.assertNotIn("SendChatMessage = nil", LUA)

    def test_ring_buffer_and_manual_dump(self):
        self.assertIn("MAX_EVENTS = 50", LUA)
        self.assertIn('SLASH_SUMMONSCOUTROUTETRACE1 = "/ssroute"', LUA)
        self.assertIn("HUB_SUMMARY", LUA)
        self.assertIn("PROVIDER_SUMMARY", LUA)
        self.assertIn("W112_SUMMONSCOUT_ROUTE_TRANSPORT_DIAG_VERSION", LUA)

    def test_lua50_safety(self):
        self.assertNotIn("table.unpack", LUA)
        self.assertNotIn("goto ", LUA)
        self.assertNotIn("continue", LUA)


if __name__ == "__main__":
    unittest.main()
