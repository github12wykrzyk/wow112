#!/usr/bin/env python3
import sqlite3
import tempfile
import unittest
from pathlib import Path

import history_worker
import shadow_history


def segment(scan_id, market, start_ms, item_id=10940, auction_id=100, buyout=300, count=3,
            scope="full_market", status="completed", total=1):
    common = dict(schema_version=1, scan_id=scan_id, market_id=market, producer_id="test-shadow",
                  source="live", scope=scope)
    return [
        dict(common, event_id=f"{scan_id}:1", producer_seq=1, event_type="ScanStarted",
             observed_at_utc_ms=start_ms),
        dict(common, event_id=f"{scan_id}:2", producer_seq=2, event_type="PageObserved",
             observed_at_utc_ms=start_ms + 10, page=0, listfrom=0, total=total, record_count=1,
             records=[dict(record_index=0, auction_id=auction_id, item_id=item_id, count=count,
                           buyout_total_copper=buyout, owner_token=None, start_bid_copper=100,
                           current_bid_copper=0, min_increment_copper=1, time_left_raw=3)]),
        dict(common, event_id=f"{scan_id}:3", producer_seq=3, event_type="ScanFinished",
             observed_at_utc_ms=start_ms + 20, status=status, pages=1),
    ]


class ShadowHistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = history_worker.connect(Path(self.tmp.name) / "history.sqlite")
        shadow_history.ensure_schema(self.db)
        self.identity = dict(market_id="wow112:test:neutral", server_id="test-server",
                             realm_id="test-realm", ah_pool_id="neutral",
                             market_epoch="epoch-2026-10")

    def tearDown(self):
        try:
            self.db.close()
        except Exception:
            pass
        self.tmp.cleanup()

    def test_shared_ingest_identity_and_scope(self):
        e = segment("s1", self.identity["market_id"], 1_000)
        result = shadow_history.ingest_shared_segment(self.db, e, self.identity)
        self.assertEqual(result["state"], "imported")
        row = self.db.execute("SELECT server_id,realm_id,ah_pool_id,market_epoch FROM market_identity").fetchone()
        self.assertEqual(row, ("test-server", "test-realm", "neutral", "epoch-2026-10"))
        ctx = self.db.execute("SELECT capture_scope,inclusion_reason FROM scan_context WHERE scan_id='s1'").fetchone()
        self.assertEqual(ctx, ("full_market", "eligible_for_decision_stats"))

    def test_all_capture_scopes_are_distinct_and_partial_are_diagnostic(self):
        for i, scope in enumerate(("full_market", "targeted_item", "revalidation_window"), 1):
            shadow_history.ingest_shared_segment(
                self.db, segment(f"scope{i}", self.identity["market_id"], 10_000 * i,
                                 auction_id=100+i, scope=scope), self.identity)
        rows = self.db.execute("SELECT scan_id,capture_scope,inclusion_reason FROM scan_context ORDER BY scan_id").fetchall()
        self.assertEqual([r[1] for r in rows], ["full_market", "targeted_item", "revalidation_window"])
        self.assertEqual(rows[0][2], "eligible_for_decision_stats")
        self.assertEqual(rows[1][2], "diagnostic_only")
        self.assertEqual(rows[2][2], "diagnostic_only")

    def test_material_view_uses_shared_observations_and_no_future_data(self):
        market = self.identity["market_id"]
        shadow_history.ingest_shared_segment(self.db, segment("past1", market, 100_000, buyout=300, count=3), self.identity)
        shadow_history.ingest_shared_segment(self.db, segment("past2", market, 200_000, auction_id=101, buyout=600, count=3), self.identity)
        shadow_history.ingest_shared_segment(self.db, segment("future", market, 900_000, auction_id=102, buyout=30, count=3), self.identity)
        view = shadow_history.material_history_view(self.db, market, [10940], cutoff_ms=500_000,
                                                    max_age_ms=1_000_000)
        self.assertEqual(len(view["items"]), 1)
        item = view["items"][0]
        self.assertEqual(item["sample_scans"], 2)
        self.assertNotIn("future", item["provenance_scan_ids"])
        # upper-middle median of 100c and 200c per unit is 200c under deterministic v1 rule
        self.assertEqual(item["unit_price"], {"numerator_copper": 200, "denominator_units": 1})
        self.assertGreater(item["confidence"], 0.0)
        self.assertGreater(item["freshness"], 0.0)

    def test_incomplete_scan_kept_but_excluded(self):
        e = segment("partial", self.identity["market_id"], 1000, status="truncated")
        shadow_history.ingest_shared_segment(self.db, e, self.identity)
        scan = self.db.execute("SELECT quality,reasons FROM scans WHERE scan_id='partial'").fetchone()
        self.assertEqual(scan[0], "diagnostic_only")
        self.assertIn("scan_truncated", scan[1])
        view = shadow_history.material_history_view(self.db, self.identity["market_id"], [10940], 999999)
        self.assertEqual(view["items"], [])

    def test_storage_failure_is_best_effort_and_never_retry_signal(self):
        e = segment("closed", self.identity["market_id"], 1000)
        self.db.close()
        result = shadow_history.safe_ingest_shared_segment(self.db, e, self.identity)
        self.assertEqual(result["history_sink"], "failed_open_for_scan")
        self.assertNotIn("retry", result)

    def test_shadow_valuation_cannot_change_buy_decision(self):
        out = shadow_history.record_shadow_valuation(
            self.db, "d1", 5000, self.identity["market_id"], 10940, 150, 180, 5000,
            {"scan_ids": ["s1"], "rule_version": shadow_history.QUALITY_RULE_VERSION}, 777)
        self.assertEqual(out["delta_copper"], 30)
        self.assertFalse(out["buy_decision_changed"])
        row = self.db.execute("SELECT buy_decision_changed FROM shadow_valuations WHERE decision_id='d1'").fetchone()
        self.assertEqual(row[0], 0)
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE shadow_valuations SET buy_decision_changed=1 WHERE decision_id='d1'")

    def test_market_identity_conflict_fails_closed_for_identity(self):
        shadow_history.register_market_identity(self.db, observed_ms=1, **self.identity)
        bad = dict(self.identity)
        bad["realm_id"] = "other-realm"
        with self.assertRaises(ValueError):
            shadow_history.register_market_identity(self.db, observed_ms=2, **bad)


if __name__ == "__main__":
    unittest.main()
