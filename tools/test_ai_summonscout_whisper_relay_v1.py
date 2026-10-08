import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TASK = ROOT / "runtime" / "parallel_tasks" / "summonscout-whisper-relay-v1.json"


class SummonScoutWhisperRelayV1Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = (ADDON / "SummonScout_WhisperRelayHot.lua").read_text(encoding="utf-8")
        cls.toc = (ADDON / "SummonScout.toc").read_text(encoding="utf-8").splitlines()
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_task_is_exact_base_and_auto_integrates(self):
        self.assertEqual(self.task["base_parallel_sha"], "8ad07c5a7ad583b4e1ce04b7b73c8fae7d4d024b")
        self.assertEqual(self.task["branch"], "feature/summonscout-whisper-relay-v1")
        self.assertEqual(self.task["status"], "ready_for_integration")
        self.assertTrue(self.task["auto_integrate"])
        self.assertEqual(self.task["delivery_profiles"], [])

    def test_module_loads_last_without_replacing_core(self):
        relay = self.toc.index("SummonScout_WhisperRelayHot.lua")
        route_guard = self.toc.index("SummonScout_PostPaymentRouteGuardHot.lua")
        self.assertGreater(relay, route_guard)
        self.assertIn('H.Register("whisperrelay", M, VERSION)', self.lua)
        self.assertNotIn('SummonScoutFrame:SetScript("OnEvent"', self.lua)

    def test_raw_capture_is_parser_independent_and_preserves_normalized_copy(self):
        self.assertIn('local eventRow = wrAppend(session, "WHISPER_IN"', self.lua)
        self.assertIn('raw = raw,', self.lua)
        self.assertIn('normalized = wrNormalize(raw),', self.lua)
        self.assertIn('intent = intent,', self.lua)
        self.assertIn('return "UNKNOWN"', self.lua)
        self.assertIn('return wrCaptureCustomer(sender, raw)', self.lua)

    def test_required_intent_tags_exist(self):
        for tag in (
            "SUMMON_REQUEST", "WAIT", "READY", "SECOND_SUMMON",
            "PAYMENT_QUESTION", "DESTINATION_QUESTION", "THANKS", "UNKNOWN",
        ):
            self.assertIn(f'"{tag}"', self.lua)
        self.assertIn('wrPhrase(n, "my alt")', self.lua)
        self.assertIn('wrPhrase(n, "my friend")', self.lua)
        self.assertIn('wrPhrase(n, "relogging")', self.lua)

    def test_persistence_model_has_required_conversation_fields(self):
        for field in (
            "session_id", "summoner_name", "customer_name", "destination",
            "created_at", "last_activity_at", "summon_state", "payment_state",
            "paid_amount", "status", "events",
        ):
            self.assertIn(field, self.lua)
        self.assertIn("SummonScoutDB.whisperRelayV1", self.lua)
        self.assertIn('session.status = "COMPLETED"', self.lua)
        self.assertIn('session.status = "EXPIRED"', self.lua)
        self.assertIn('s.status = "CLOSED"', self.lua)

    def test_master_relay_format_and_chunking_preserve_raw(self):
        self.assertIn('local PROTO = "[SSWR1]"', self.lua)
        self.assertIn('wrSendPacket(master, "IB"', self.lua)
        self.assertIn('wrSendPacket(master, "IC"', self.lua)
        self.assertIn('wrMirrorInbound(sender, pending.fields, raw)', self.lua)
        self.assertIn('wrChat("[" .. tostring(sender) .. "] <" .. tostring(customer) .. ">: " .. tostring(raw))', self.lua)
        self.assertIn('wrEncodedChunks(eventRow.raw or "", CHUNK_SIZE)', self.lua)

    def test_master_acl_and_summoner_trust_are_fail_closed(self):
        self.assertIn('if master == "" or not wrSame(sender, master) then', self.lua)
        self.assertIn('return nil, "wrong-summoner-owner"', self.lua)
        self.assertIn('return nil, "wrong-customer-owner"', self.lua)
        self.assertIn('return nil, "destination-mismatch"', self.lua)
        self.assertIn('return nil, "session-not-active"', self.lua)
        self.assertIn('if not wrTrustedSummoner(sender) then', self.lua)
        self.assertIn('wrFallbackPeerTrusted', self.lua)
        self.assertIn('D.trustedSummoners', self.lua)

    def test_control_like_customer_message_cannot_execute_but_is_still_raw_captured(self):
        marker = 'wrChat("blocked unauthorised control-like whisper from " .. tostring(sender))'
        self.assertIn(marker, self.lua)
        after = self.lua[self.lua.index(marker):]
        self.assertIn('return wrCaptureCustomer(sender, raw)', after[:400])

    def test_internal_control_whispers_never_enter_customer_transcript(self):
        self.assertIn('local EXISTING_CONTROL_PREFIX = "[SSFR1]"', self.lua)
        self.assertIn('local EXISTING_MASTER_PREFIX = "[SSI "', self.lua)
        self.assertIn('if wrStarts(raw, EXISTING_CONTROL_PREFIX) or wrStarts(raw, EXISTING_MASTER_PREFIX) then', self.lua)
        self.assertIn('return true', self.lua)

    def test_duplicate_inbound_event_is_suppressed(self):
        self.assertIn('local DUPLICATE_WINDOW = 0.80', self.lua)
        self.assertIn('if wrInboundDuplicate(sender, raw) then return true end', self.lua)
        self.assertIn('R.inboundRecent[key] = t', self.lua)

    def test_outgoing_master_and_auto_replies_are_separate_and_no_echo_loop(self):
        self.assertIn('local kind = "WHISPER_OUT_AUTO"', self.lua)
        self.assertIn('kind = "WHISPER_OUT_MASTER"', self.lua)
        self.assertIn('if wrIsReservedControl(raw) then return true end', self.lua)
        self.assertIn('H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")', self.lua)
        self.assertNotIn('wrCaptureCustomer(target, raw)', self.lua)
        self.assertIn('eventRow.raw or eventRow.value', self.lua)

    def test_explicit_and_shorthand_master_reply_guards(self):
        self.assertIn('SLASH_SUMMONSCOUTRELAY1 = "/ssr"', self.lua)
        self.assertIn('local matches = wrFindSessions(first, second, true)', self.lua)
        self.assertIn('if table.getn(matches) ~= 1 then', self.lua)
        self.assertIn('explicit reply blocked: expected exactly one ACTIVE owned conversation', self.lua)
        self.assertIn('if table.getn(active) ~= 1 then', self.lua)
        self.assertIn('shorthand blocked:', self.lua)
        self.assertIn('wrPrintCandidates(active)', self.lua)

    def test_master_reply_is_sent_by_owning_summoner_without_automatic_retry(self):
        execute = self.lua[self.lua.index("local function wrExecuteMasterReply"):]
        execute = execute[: execute.index("local function wrReplyChunkBegin")]
        self.assertIn('wrSendRawWhisper(customer, text)', execute)
        self.assertIn('reply send failed without retry', execute)
        self.assertEqual(execute.count('wrSendRawWhisper(customer, text)'), 1)
        self.assertIn('R.seenReplyNonce[nonce]', execute)

    def test_long_master_reply_reassembles_before_single_customer_send(self):
        self.assertIn('wrSendPacket(session.summoner_name, "RB"', self.lua)
        self.assertIn('wrSendPacket(session.summoner_name, "RC"', self.lua)
        self.assertIn('R.pendingReplyChunks[nonce]', self.lua)
        self.assertIn('return wrExecuteMasterReply(sender, {', self.lua)
        self.assertIn('local MAX_CUSTOMER_REPLY = 220', self.lua)

    def test_lifecycle_links_invite_join_summon_and_payment(self):
        for kind in ("INVITE", "JOIN", "SUMMON_START", "SUMMON_OK", "SUMMON_FAIL", "PAID"):
            self.assertIn(f'"{kind}"', self.lua)
        self.assertIn('W112_SUMMONSCOUT_STATE', self.lua)
        self.assertIn('W112_SUMMONSCOUT_API_V1', self.lua)
        self.assertIn('SummonScoutDB and SummonScoutDB.paymentLog', self.lua)
        self.assertIn('session.payment_state = "PAID"', self.lua)
        self.assertIn('session.paid_amount', self.lua)

    def test_payment_history_does_not_replay_on_first_install_or_reload(self):
        self.assertIn('local function wrSeedExistingPayments()', self.lua)
        self.assertIn('if D.paymentSeeded then return end', self.lua)
        self.assertIn('D.paymentSeeded = true', self.lua)
        self.assertIn('wrSeedExistingPayments()', self.lua)
        self.assertIn('D.seenPayments[signature]', self.lua)

    def test_full_history_survives_reload_and_old_sessions_are_retained(self):
        self.assertIn('SummonScoutDB.whisperRelayV1', self.lua)
        self.assertIn('local SESSION_LIMIT = 220', self.lua)
        self.assertIn('local EVENT_LIMIT = 140', self.lua)
        self.assertIn('local SESSION_REUSE_TTL = 1800', self.lua)
        self.assertIn('D.sessions[sid] = session', self.lua)
        self.assertIn('D.sessionOrder[table.getn(D.sessionOrder) + 1] = sid', self.lua)

    def test_multi_summoner_is_data_driven_not_bolthyjal_hardcoded(self):
        self.assertNotIn("Bolthyjal", self.lua)
        self.assertNotIn("Gatoacara", self.lua)
        self.assertIn('session.summoner_name', self.lua)
        self.assertIn('SummonScoutDB and SummonScoutDB.service', self.lua)

    def test_two_customers_cannot_cross_talk(self):
        self.assertIn('wrFindExactOwnedSession(sid, customer, destination)', self.lua)
        self.assertIn('if not wrSame(session.customer_name, customer) then', self.lua)
        self.assertIn('if not wrSame(session.summoner_name, wrPlayer()) then', self.lua)
        self.assertIn('nonce == ""', self.lua)

    def test_p1_conversation_browsing_commands_exist_without_gui_dependency(self):
        self.assertIn('lowerCmd == "list"', self.lua)
        self.assertIn('lowerCmd == "show"', self.lua)
        self.assertIn('lowerCmd == "close"', self.lua)
        self.assertIn('local function wrShowSession(session)', self.lua)
        self.assertNotIn('CreateFrame(', self.lua)

    def test_vanilla_lua_compatibility_contract(self):
        self.assertNotIn('string.match(', self.lua)
        self.assertNotRegex(self.lua, r'\bcontinue\b|\bgoto\b')
        self.assertNotIn('table.unpack', self.lua)
        self.assertIn('table.getn', self.lua)
        self.assertIn('string.g', self.lua)


if __name__ == "__main__":
    unittest.main()
