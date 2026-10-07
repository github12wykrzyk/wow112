#!/usr/bin/env python3
"""Deterministic TELE10 trade/payment ledger harness.

This is not a live WoW test. It models the persistence/correlation/settlement
contract and also asserts the production Lua contains the hard-stop anchors.
"""
from __future__ import annotations

import copy
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
LUA = ROOT / "src/AddOns/SummonScout/SummonScout_TradePaymentLedger.lua"
TOC = ROOT / "src/AddOns/SummonScout/SummonScout.toc"
AUTO = ROOT / "src/AutoSummonAssist/WoWAutoSummonAssist_5875_v1.c"


class Model:
    def __init__(self, persisted=None):
        self.db = copy.deepcopy(persisted) if persisted is not None else {
            "seq": 0,
            "settle_seq": 0,
            "summons": [],
            "settlements": set(),
        }
        self.now = 10_000

    def tick(self, seconds):
        self.now += seconds

    def summon(self, player, dest="Hyjal", expected=40_000):
        for r in self.db["summons"]:
            if r["player"].lower() == player.lower() and r["status"] in {"unpaid", "partial"}:
                r["active_until"] = 0
        self.db["seq"] += 1
        rec = {
            "id": f"S{self.db['seq']}",
            "player": player,
            "dest": dest,
            "expected": expected,
            "paid": 0,
            "status": "unpaid",
            "summon_status": "summoned",
            "created": self.now,
            "active_until": self.now + 600,
        }
        self.db["summons"].append(rec)
        return rec

    def correlate(self, player):
        same = [r for r in self.db["summons"] if r["player"].lower() == player.lower()]
        if any(r["status"] == "uncertain" for r in same):
            return None, "hard_stop_uncertain"
        open_rows = [r for r in same if r["summon_status"] == "summoned" and r["status"] in {"unpaid", "partial"}
                     and 0 <= self.now - r["created"] <= 21_600]
        active = [r for r in open_rows if self.now <= r["active_until"]]
        if len(active) == 1:
            return active[0], "active_session_exact"
        if len(active) > 1:
            return None, "ambiguous_active_sessions"
        if len(open_rows) == 1:
            return open_rows[0], "unique_unpaid_window"
        if len(open_rows) > 1:
            return None, "ambiguous_unpaid_summons"
        return None, "no_matching_unpaid_summon"

    def settle(self, player, offered, delta, both_accepted=True, settlement_id=None):
        rec, reason = self.correlate(player)
        if settlement_id is None:
            self.db["settle_seq"] += 1
            settlement_id = f"SET{self.db['settle_seq']}"
        if settlement_id in self.db["settlements"]:
            return "duplicate", rec
        if delta <= 0:
            return "cancelled", rec
        if not both_accepted or delta != offered or offered <= 0 or rec is None:
            if rec is not None:
                rec["status"] = "uncertain"
                rec["active_until"] = 0
            return "uncertain", rec
        self.db["settlements"].add(settlement_id)
        rec["paid"] += delta
        if rec["paid"] < rec["expected"]:
            rec["status"] = "partial"
            rec["active_until"] = self.now + 600
        elif rec["paid"] == rec["expected"]:
            rec["status"] = "paid"
            rec["active_until"] = 0
        else:
            rec["status"] = "overpaid"
            rec["active_until"] = 0
        return rec["status"], rec


class TradeLedgerContractTests(unittest.TestCase):
    def test_happy_path_exact_4g(self):
        m = Model(); r = m.summon("PlayerA")
        status, _ = m.settle("PlayerA", 40_000, 40_000)
        self.assertEqual((status, r["paid"]), ("paid", 40_000))

    def test_underpay_is_partial(self):
        m = Model(); r = m.summon("PlayerA")
        status, _ = m.settle("PlayerA", 30_000, 30_000)
        self.assertEqual((status, r["paid"]), ("partial", 30_000))

    def test_overpay_keeps_actual_amount(self):
        m = Model(); r = m.summon("PlayerA")
        status, _ = m.settle("PlayerA", 50_000, 50_000)
        self.assertEqual((status, r["paid"]), ("overpaid", 50_000))

    def test_two_partial_trades_complete_one_summon(self):
        m = Model(); r = m.summon("PlayerA")
        self.assertEqual(m.settle("PlayerA", 20_000, 20_000)[0], "partial")
        self.assertEqual(m.settle("PlayerA", 20_000, 20_000)[0], "paid")
        self.assertEqual(r["paid"], 40_000)

    def test_cancel_never_books_payment(self):
        m = Model(); r = m.summon("PlayerA")
        self.assertEqual(m.settle("PlayerA", 40_000, 0)[0], "cancelled")
        self.assertEqual((r["status"], r["paid"]), ("unpaid", 0))

    def test_accept_then_cancel_never_books_payment(self):
        m = Model(); r = m.summon("PlayerA")
        self.assertEqual(m.settle("PlayerA", 40_000, 0, both_accepted=True)[0], "cancelled")
        self.assertEqual(r["paid"], 0)

    def test_duplicate_settlement_is_idempotent(self):
        m = Model(); r = m.summon("PlayerA")
        self.assertEqual(m.settle("PlayerA", 20_000, 20_000, settlement_id="X")[0], "partial")
        self.assertEqual(m.settle("PlayerA", 20_000, 20_000, settlement_id="X")[0], "duplicate")
        self.assertEqual(r["paid"], 20_000)

    def test_wrong_client_is_not_assigned(self):
        m = Model(); a = m.summon("PlayerA")
        status, rec = m.settle("PlayerB", 40_000, 40_000)
        self.assertEqual(status, "uncertain")
        self.assertIsNone(rec)
        self.assertEqual((a["status"], a["paid"]), ("unpaid", 0))

    def test_old_unique_unpaid_summon_can_be_paid_an_hour_later(self):
        m = Model(); r = m.summon("PlayerA")
        m.tick(3600)
        self.assertEqual(m.correlate("PlayerA")[0]["id"], r["id"])
        self.assertEqual(m.settle("PlayerA", 40_000, 40_000)[0], "paid")

    def test_new_active_session_beats_older_unpaid_same_client(self):
        m = Model(); old = m.summon("PlayerA", "Hyjal")
        m.tick(1200)
        new = m.summon("PlayerA", "Azshara")
        picked, reason = m.correlate("PlayerA")
        self.assertEqual((picked["id"], reason), (new["id"], "active_session_exact"))
        self.assertEqual(old["status"], "unpaid")

    def test_two_old_unpaid_same_client_fail_closed(self):
        m = Model(); m.summon("PlayerA", "Hyjal")
        m.tick(1200); m.summon("PlayerA", "Azshara")
        m.tick(700)
        picked, reason = m.correlate("PlayerA")
        self.assertIsNone(picked)
        self.assertEqual(reason, "ambiguous_unpaid_summons")

    def test_wallet_delta_mismatch_marks_uncertain_and_hard_stops(self):
        m = Model(); r = m.summon("PlayerA")
        self.assertEqual(m.settle("PlayerA", 40_000, 30_000)[0], "uncertain")
        self.assertEqual(r["status"], "uncertain")
        self.assertEqual(m.correlate("PlayerA")[1], "hard_stop_uncertain")

    def test_missing_both_accepted_is_uncertain_even_with_wallet_gain(self):
        m = Model(); r = m.summon("PlayerA")
        self.assertEqual(m.settle("PlayerA", 40_000, 40_000, both_accepted=False)[0], "uncertain")
        self.assertEqual(r["paid"], 0)

    def test_restart_preserves_unpaid_and_later_settles(self):
        m = Model(); r = m.summon("PlayerA")
        persisted = copy.deepcopy(m.db)
        restarted = Model(persisted)
        restarted.now = m.now + 1800
        picked, _ = restarted.correlate("PlayerA")
        self.assertEqual(picked["id"], r["id"])
        self.assertEqual(restarted.settle("PlayerA", 40_000, 40_000)[0], "paid")


class ProductionAnchorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = LUA.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")
        cls.auto = AUTO.read_text(encoding="utf-8")

    def test_savedvariables_persistence_and_required_fields(self):
        for token in [
            "SummonScoutDB.tele10Ledger", "summon_id", "timestamp_created",
            "client_name", "summoner_name", "destination", "trigger_message",
            "expected_price_copper", "summon_status", "payment_status",
            "amount_paid_copper", "payment_timestamp", "trade_partner",
            "payment_event_id", "settlement_id", "last_update", "failure_reason",
        ]:
            self.assertIn(token, self.lua)

    def test_settlement_is_wallet_delta_plus_both_accepted_not_offer_only(self):
        self.assertIn("delta == offered", self.lua)
        self.assertIn("t.both_accepted", self.lua)
        self.assertIn("wallet_delta_does_not_match_offer", self.lua)
        self.assertIn("wallet_gain_without_both_accepted_observed", self.lua)

    def test_uncertain_is_a_hard_stop(self):
        self.assertIn('rec.payment_status = "uncertain"', self.lua)
        self.assertIn('"hard_stop_uncertain"', self.lua)
        self.assertIn('"summon_payment_uncertain_hard_stop"', self.lua)

    def test_idempotency_anchor_exists(self):
        self.assertIn("db.settlement_ids[t.settlement_id]", self.lua)
        self.assertIn('return false, "duplicate_settlement"', self.lua)

    def test_existing_dll_is_reused_and_policy_gate_is_faster_than_accept_stability(self):
        self.assertIn("AcceptTrade()", self.auto)
        self.assertIn("t-W112_AUTOGOLD_SINCE>=0.25", self.auto)
        self.assertIn("W112_AUTOGOLD_TARGET_LATCH", self.auto)
        self.assertIn("TL.nextPolicyAt = t + 0.05", self.lua)
        self.assertIn("W112_AUTOGOLD_TARGET_LATCH = 1", self.lua)

    def test_legacy_core_settlement_writer_is_suppressed(self):
        self.assertIn("originalFinishTrade()", self.lua)
        self.assertIn("state.pendingTrade = nil", self.lua)

    def test_ledger_loads_last(self):
        lines = [x.strip() for x in self.toc.splitlines() if x.strip() and not x.startswith("##")]
        self.assertEqual(lines[-1], "SummonScout_TradePaymentLedger.lua")

    def test_query_surface_exists(self):
        for token in ["/ssledger", "/sspay", "tlShowSummons", "tlShowPayments", 'cmd == "since"']:
            self.assertIn(token, self.lua)


if __name__ == "__main__":
    unittest.main(verbosity=2)
