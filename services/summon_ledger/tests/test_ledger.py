from __future__ import annotations

import tempfile
import unittest
from datetime import timedelta
from pathlib import Path

from services.summon_ledger.benchmark import run as run_benchmark
from services.summon_ledger.ledger import EventConflictError, Ledger, parse_since, utc_now, utc_text


def make_event(event_id, event_type, request_id="r1", *, now=None, amount=0, customer="PlayerOne", destination="Hyjal", correlation_id=None, session_id="s1", state=None):
    now = now or utc_now()
    return {
        "schema_version": 1,
        "event_id": event_id,
        "ts_utc": utc_text(now),
        "type": event_type,
        "session_id": session_id,
        "request_id": request_id,
        "customer": customer,
        "destination": destination,
        "state": state or event_type,
        "amount_copper": amount,
        "correlation_id": correlation_id or ("c-" + request_id if request_id else None),
        "severity": "info",
        "metadata": {},
    }


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "ledger.sqlite3"
        self.ledger = Ledger(self.db)
        self.now = utc_now()

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def test_restart_persistence_and_wal(self):
        self.ledger.ingest_event(make_event("e1", "PaymentReceived", amount=40000, now=self.now))
        self.assertEqual(self.ledger.request("r1")["paid_copper"], 40000)
        mode = self.ledger.conn.execute("PRAGMA journal_mode").fetchone()[0]
        self.assertEqual(mode.lower(), "wal")
        self.ledger.close()
        self.ledger = Ledger(self.db)
        self.assertEqual(self.ledger.request("r1")["payment_state"], "paid")

    def test_duplicate_replay_is_idempotent(self):
        event = make_event("e1", "PaymentReceived", amount=40000, now=self.now)
        self.assertEqual(self.ledger.ingest_event(event), "inserted")
        self.assertEqual(self.ledger.ingest_event(event), "duplicate")
        self.assertEqual(self.ledger.stats(self.now)["event_count"], 1)
        self.assertEqual(self.ledger.request("r1")["paid_copper"], 40000)

    def test_duplicate_event_id_with_changed_payload_is_rejected(self):
        self.ledger.ingest_event(make_event("e1", "PaymentReceived", amount=40000, now=self.now))
        with self.assertRaises(EventConflictError):
            self.ledger.ingest_event(make_event("e1", "PaymentReceived", amount=50000, now=self.now))

    def test_out_of_order_rebuilds_projection_by_event_time(self):
        self.ledger.ingest_event(make_event("done", "SummonCompleted", now=self.now))
        self.ledger.ingest_event(make_event("start", "SummonStarted", now=self.now - timedelta(minutes=2)))
        self.ledger.ingest_event(make_event("expected", "PaymentExpected", amount=40000, now=self.now - timedelta(minutes=1)))
        self.ledger.ingest_event(make_event("paid", "PaymentReceived", amount=40000, now=self.now + timedelta(seconds=1)))
        request = self.ledger.request("r1")
        self.assertEqual(request["summon_state"], "completed")
        self.assertEqual(request["payment_state"], "paid")
        self.assertEqual(request["expected_copper"], 40000)

    def test_request_and_correlation_identity_protection(self):
        self.ledger.ingest_event(make_event("e1", "SummonStarted", request_id="r1", correlation_id="corr", now=self.now))
        with self.assertRaises(EventConflictError):
            self.ledger.ingest_event(make_event("e2", "SummonCompleted", request_id="r2", correlation_id="corr", now=self.now))
        with self.assertRaises(EventConflictError):
            self.ledger.ingest_event(make_event("e3", "SummonCompleted", request_id="r1", correlation_id="other", now=self.now))

    def test_payment_from_about_an_hour_ago_is_queryable(self):
        paid_at = self.now - timedelta(minutes=59)
        self.ledger.ingest_event(make_event("e1", "PaymentReceived", amount=40000, now=paid_at))
        since = utc_text(self.now - timedelta(hours=1))
        result = self.ledger.find_player("playerone", since)
        self.assertEqual(result["payment_count"], 1)
        self.assertEqual(result["paid_total_copper"], 40000)

    def test_two_payments_same_player_are_kept_separately(self):
        self.ledger.ingest_many([
            make_event("e1", "PaymentReceived", request_id="r1", amount=30000, now=self.now),
            make_event("e2", "PaymentReceived", request_id="r2", amount=40000, now=self.now + timedelta(seconds=1)),
        ])
        result = self.ledger.find_player("PlayerOne")
        self.assertEqual(result["payment_count"], 2)
        self.assertEqual(result["paid_total_copper"], 70000)
        self.assertEqual({x["request_id"] for x in result["payments"]}, {"r1", "r2"})

    def test_unpaid(self):
        self.ledger.ingest_many([
            make_event("expected", "PaymentExpected", amount=40000, now=self.now),
            make_event("missing", "PaymentMissing", amount=0, now=self.now + timedelta(minutes=1)),
        ])
        rows = self.ledger.unpaid()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["request_id"], "r1")
        self.assertEqual(rows[0]["payment_state"], "unpaid")

    def test_uncertain(self):
        self.ledger.ingest_many([
            make_event("expected", "PaymentExpected", amount=40000, now=self.now),
            make_event("uncertain", "TradeUncertain", amount=0, now=self.now + timedelta(minutes=1)),
        ])
        self.assertEqual(self.ledger.uncertain()[0]["request_id"], "r1")

    def test_later_payment_resolves_uncertain(self):
        self.ledger.ingest_many([
            make_event("expected", "PaymentExpected", amount=40000, now=self.now),
            make_event("uncertain", "TradeUncertain", now=self.now + timedelta(minutes=1)),
            make_event("paid", "PaymentReceived", amount=40000, now=self.now + timedelta(minutes=2)),
        ])
        self.assertEqual(self.ledger.request("r1")["payment_state"], "paid")

    def test_failed_summon(self):
        self.ledger.ingest_many([
            make_event("start", "SummonStarted", now=self.now),
            make_event("failed", "SummonFailed", now=self.now + timedelta(seconds=30)),
        ])
        request = self.ledger.request("r1")
        self.assertEqual(request["summon_state"], "failed")
        self.assertEqual(self.ledger.stats(self.now)["failed_summons"], 1)

    def test_revenue_today_last_hour_and_session(self):
        self.ledger.ingest_many([
            make_event("e1", "PaymentReceived", request_id="r1", amount=40000, now=self.now - timedelta(minutes=30), session_id="A"),
            make_event("e2", "PaymentReceived", request_id="r2", amount=30000, now=self.now - timedelta(hours=2), session_id="A"),
            make_event("e3", "PaymentReceived", request_id="r3", amount=20000, now=self.now - timedelta(minutes=10), session_id="B"),
        ])
        stats = self.ledger.stats(self.now)
        self.assertEqual(stats["revenue_last_hour"]["revenue_copper"], 60000)
        self.assertEqual(self.ledger.revenue(session_id="A")["revenue_copper"], 70000)

    def test_parse_since_duration(self):
        since = parse_since("1h", self.now)
        self.assertEqual(since, utc_text(self.now - timedelta(hours=1)))


class LargeLedgerTest(unittest.TestCase):
    def test_50000_records_and_query_performance(self):
        result = run_benchmark(50000, 1500.0)
        self.assertEqual(result["total_event_count"], 50000)
        self.assertLess(result["find_player_ms"], 1500.0)
        self.assertLess(result["revenue_ms"], 1500.0)
        self.assertLess(result["stats_ms"], 1500.0)


if __name__ == "__main__":
    unittest.main()
