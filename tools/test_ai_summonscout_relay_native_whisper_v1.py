import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
LUA = ROOT / "src/AddOns/SummonScout/SummonScout_WhisperRelayWimNativeHot.lua"
TOC = ROOT / "src/AddOns/SummonScout/SummonScout.toc"


class NativeWhisperRelayV1Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = LUA.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")

    def test_reuses_existing_wim_hot_slot_without_extra_fanout_module(self):
        self.assertIn("SummonScout_WhisperRelayWimNativeHot.lua", self.toc)
        self.assertNotIn("SummonScout_WhisperRelayNativeWhisperHot.lua", self.toc)
        self.assertIn('"2-native-whisper-wim"', self.lua)
        self.assertIn('H.GetState("whisperrelaywim")', self.lua)

    def test_transport_is_consumed_from_real_whisper_event(self):
        self.assertIn('ev~="CHAT_MSG_WHISPER"', self.lua)
        self.assertIn('"[SSWR1]"', self.lua)
        self.assertIn('starts(raw,P)', self.lua)
        self.assertIn('WIM_ChatFrame_OnEvent=W112_SUMMONSCOUT_RELAY_WIM_WRAPPER', self.lua)

    def test_inbound_packet_renders_in_summoner_wim(self):
        self.assertIn('WIM_PostMessage,sender,msg,typ,from,raw', self.lua)
        self.assertIn('"|cff66ccff["', self.lua)
        self.assertIn('customer.."]|r "..raw', self.lua)

    def test_outbound_event_renders_in_same_wim(self):
        self.assertIn('kind=="WHISPER_OUT_AUTO" or kind=="WHISPER_OUT_MASTER"', self.lua)
        self.assertIn('outgoing and 2 or 1', self.lua)
        self.assertIn('"|cffaaaaaa[to "', self.lua)

    def test_chunked_inbound_is_reassembled_before_display(self):
        self.assertIn('if c=="IB" then return begin(sender,f) end', self.lua)
        self.assertIn('if c=="IC" then return part(sender,f) end', self.lua)
        self.assertIn('for i=1,x.count do raw=raw..x.p[i] end', self.lua)

    def test_technical_packets_are_swallowed(self):
        self.assertIn('return true\nend\nlocal function installWim()', self.lua)

    def test_legacy_default_chat_mirror_is_suppressed_when_wim_available(self):
        self.assertIn('type(WIM_PostMessage)~="function"', self.lua)
        self.assertIn('SummonRelay:|r [', self.lua)
        self.assertIn('DEFAULT_CHAT_FRAME.AddMessage=W112_SUMMONSCOUT_RELAY_CHAT_WRAPPER', self.lua)

    def test_reply_uses_canonical_ssr_router_and_exact_session(self):
        self.assertIn('SlashCmdList["SUMMONSCOUTRELAY"]', self.lua)
        self.assertIn('session(sid,s,c)', self.lua)
        self.assertIn('local cmd=s.." "..c.." "..text', self.lua)

    def test_module_never_sends_chat_directly(self):
        self.assertNotIn('SendChatMessage(', self.lua)

    def test_hot_wrappers_are_stable_global_dispatchers(self):
        self.assertIn('W112_SUMMONSCOUT_RELAY_WIM_BASE', self.lua)
        self.assertIn('W112_SUMMONSCOUT_RELAY_WIM_WRAPPER', self.lua)
        self.assertIn('W112_SUMMONSCOUT_RELAY_CHAT_BASE', self.lua)
        self.assertIn('W112_SUMMONSCOUT_RELAY_CHAT_WRAPPER', self.lua)


if __name__ == "__main__":
    unittest.main()
