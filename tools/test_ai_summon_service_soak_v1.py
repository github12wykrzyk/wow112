#!/usr/bin/env python3
import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("soak", HERE / "summon_service_soak_v1.py")
soak = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["soak"] = soak
SPEC.loader.exec_module(soak)


class SummonServiceSoakV1Tests(unittest.TestCase):
    def test_required_event_contract_is_complete(self):
        expected = {
            "ServiceStarted", "SessionReady", "WhisperReceived", "ParserDecision",
            "RequestQueued", "SummonStarted", "SummonCompleted", "SummonFailed",
            "PaymentExpected", "PaymentReceived", "PaymentMissing", "TradeUncertain",
            "Reconnect", "ServiceStopped",
        }
        self.assertEqual(expected, soak.EVENT_TYPES)
        ev = soak.ServiceModel().store.events[0]
        self.assertEqual(set(soak.SCHEMA_FIELDS), set(soak.asdict(ev)))

    def test_whisper_adversarial_matrix_has_no_synthetic_failures(self):
        rows = soak.run_whispers()
        self.assertGreaterEqual(len(rows), 14)
        self.assertFalse([r for r in rows if r.result != "PASS"])
        names = {r.case for r in rows}
        for needle in ("need winterspring", "+", "invi", "inv pls", "can i get one", "need one", "here"):
            self.assertIn(f"whisper:{needle}", names)

    def test_queue_summon_payment_and_persistence_invariants(self):
        rows = soak.run_queue() + soak.run_summon() + soak.run_payment() + soak.run_persistence()
        self.assertFalse([r for r in rows if r.result != "PASS"])
        self.assertTrue(any(r.case == "payment:back_to_trade" for r in rows))
        self.assertTrue(any(r.case == "payment:uncertain_write" for r in rows))
        self.assertTrue(any(r.case.endswith(":replay") for r in rows))

    def test_soak_minimum_20_cycles(self):
        rows, metrics = soak.run_soak(20)
        self.assertFalse([r for r in rows if r.result != "PASS"])
        self.assertEqual(20, metrics["cycles"])
        self.assertEqual(0.0, metrics["duplicate_rate"])
        self.assertGreaterEqual(metrics["reconnect_count"], 1)
        self.assertGreaterEqual(metrics["unpaid_count"], 1)
        self.assertGreaterEqual(metrics["uncertain_count"], 1)

    def test_event_replay_is_idempotent(self):
        m = soak.ServiceModel("winterspring")
        r, _ = m.whisper("Replay", "need one")
        m.summon(r)
        m.payment(r, 4 * soak.GOLD)
        snap = m.store.snapshot()
        restored = soak.EventStore.restore(snap)
        before = len(restored.events)
        for row in snap:
            restored.append(soak.Event(**row))
        self.assertEqual(before, len(restored.events))


if __name__ == "__main__":
    unittest.main()
