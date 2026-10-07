#!/usr/bin/env python3
import copy
import tempfile
import unittest
from pathlib import Path

import history_worker
import shadow_quality_v2 as q


def make_segment(scan_id="scan", start_ms=1_000, duplicate_rows=5, evidence=(0, 1),
                 status="completed", page_gap=False, market="live-test:octowow:test"):
    common = dict(
        schema_version=1, scan_id=scan_id, market_id=market,
        producer_id="quality-v2-test", source="live", scope="full_market",
    )
    events = [dict(common, event_id=f"{scan_id}:1", producer_seq=1,
                   event_type="ScanStarted", observed_at_utc_ms=start_ms)]
    rows_all = []
    next_auction = 1
    page_count = 11
    total = 515
    for page in range(page_count):
        count = 15 if page == page_count - 1 else 50
        rows = []
        for index in range(count):
            row = dict(
                record_index=index,
                auction_id=next_auction,
                item_id=10940 + (next_auction % 10),
                count=1 + (next_auction % 4),
                buyout_total_copper=1000 + next_auction,
                owner_token=None,
                start_bid_copper=100,
                current_bid_copper=0,
                min_increment_copper=1,
                time_left_raw=3_600_000,
            )
            rows.append(row)
            rows_all.append(copy.deepcopy(row))
            next_auction += 1
        actual_page = page + 1 if page_gap and page == 5 else page
        events.append(dict(
            common, event_id=f"{scan_id}:{len(events)+1}", producer_seq=len(events)+1,
            event_type="PageObserved", observed_at_utc_ms=start_ms + page + 1,
            page=actual_page, listfrom=actual_page * 50,
            total=total + (1 if page in (3, 4) else 0), record_count=len(rows),
            market_evidence={"realm_id": evidence[0], "auction_house_id": evidence[1],
                             "identity_status": "observed_not_reconciled"},
            records=rows,
        ))
    candidates = [copy.deepcopy(r) for r in rows_all[:duplicate_rows]]
    pos = 0
    for event in events[1:]:
        for i in range(len(event["records"])):
            if pos >= duplicate_rows:
                break
            if event["page"] >= 8:
                dup = copy.deepcopy(candidates[pos])
                dup["record_index"] = i
                event["records"][i] = dup
                pos += 1
        if pos >= duplicate_rows:
            break
    events.append(dict(
        common, event_id=f"{scan_id}:{len(events)+1}", producer_seq=len(events)+1,
        event_type="ScanFinished", observed_at_utc_ms=start_ms + 100,
        status=status, pages=page_count,
    ))
    return events


IDENTITY = dict(server_id="octowow", realm_id="0", ah_pool_id="1",
                market_epoch="baseline-2026-10-07")


class ShadowQualityV2Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = history_worker.connect(Path(self.tmp.name) / "history.sqlite")

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def test_calibrated_live_churn_admitted_without_mutating_v0_quality(self):
        events = make_segment()
        base = history_worker.validate(events)
        self.assertEqual(base[2], "diagnostic_only")
        self.assertIn("unique_total_mismatch", base[3])
        self.assertIn("unverified_market_identity", base[3])
        out = q.reconcile_segment(self.db, events, IDENTITY)
        admission = out["v2_admission"]
        self.assertTrue(admission["eligible"], admission)
        self.assertEqual(admission["exclusion_reasons"], [])
        stored = self.db.execute("SELECT quality FROM scans WHERE scan_id='scan'").fetchone()[0]
        self.assertEqual(stored, "diagnostic_only")
        ctx = self.db.execute(
            "SELECT inclusion_reason,canonical_market_id FROM quality_v2_scan_admission WHERE scan_id='scan'"
        ).fetchone()
        self.assertEqual(ctx[0], "eligible_for_decision_stats")
        self.assertEqual(ctx[1], q.canonical_market_id(IDENTITY))

    def test_excessive_duplicate_churn_rejected(self):
        events = make_segment(scan_id="dup", duplicate_rows=30)
        out = q.evaluate(events, IDENTITY)
        self.assertFalse(out["eligible"])
        self.assertIn("duplicate_churn_above_limit", out["exclusion_reasons"])
        self.assertIn("unique_total_gap_above_limit", out["exclusion_reasons"])

    def test_market_evidence_mismatch_rejected(self):
        events = make_segment(scan_id="market", evidence=(0, 2))
        out = q.evaluate(events, IDENTITY)
        self.assertFalse(out["eligible"])
        self.assertIn("market_identity_evidence_mismatch", out["exclusion_reasons"])

    def test_page_gap_remains_hard_failure(self):
        events = make_segment(scan_id="gap", page_gap=True)
        out = q.evaluate(events, IDENTITY)
        self.assertFalse(out["eligible"])
        self.assertIn("v0:page_gap_or_reorder", out["exclusion_reasons"])

    def test_truncated_scan_remains_hard_failure(self):
        events = make_segment(scan_id="trunc", status="truncated")
        out = q.evaluate(events, IDENTITY)
        self.assertFalse(out["eligible"])
        self.assertIn("not_completed", out["exclusion_reasons"])
        self.assertIn("v0:scan_truncated", out["exclusion_reasons"])

    def test_point_in_time_view_excludes_future_scan(self):
        past1 = make_segment(scan_id="past1", start_ms=100_000)
        past2 = make_segment(scan_id="past2", start_ms=200_000)
        future = make_segment(scan_id="future", start_ms=900_000)
        for events in (past1, past2, future):
            out = q.reconcile_segment(self.db, events, IDENTITY)
            self.assertTrue(out["v2_admission"]["eligible"])
        market = q.canonical_market_id(IDENTITY)
        view = q.material_history_view(self.db, market, None, cutoff_ms=500_000, max_age_ms=1_000_000)
        self.assertGreater(len(view["items"]), 0)
        ids = {sid for item in view["items"] for sid in item["provenance_scan_ids"]}
        self.assertIn("past1", ids)
        self.assertIn("past2", ids)
        self.assertNotIn("future", ids)

    def test_quality_version_and_no_buy_surface(self):
        events = make_segment(scan_id="version")
        out = q.reconcile_segment(self.db, events, IDENTITY)
        self.assertEqual(out["v2_admission"]["quality_rule_version"], q.QUALITY_RULE_VERSION)
        self.assertFalse(hasattr(q, "buy"))
        self.assertFalse(hasattr(q, "purchase"))


if __name__ == "__main__":
    unittest.main()
