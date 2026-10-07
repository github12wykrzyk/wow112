#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path

import history_worker
import terminal_spool


def raw(page, n, total, ms, scope="full_market", session="run1"):
    records=[]
    for i in range(n):
        aid=page*1000+i+1
        records.append({"record_index":i,"auction_id":aid,"item_id":10940,"count":1,
                        "buyout_total_copper":100+i,"owner_token":None,"start_bid_copper":50,
                        "current_bid_copper":0,"min_increment_copper":0,"time_left_raw":3})
    return {"schema_version":1,"event_type":"RawAhPageObserved","session_id":session,
            "capture_scope":scope,"label":"poc08-unified-full-ah" if scope=="full_market" else "poc07-fresh-precheck",
            "market_id":"wow112:test:neutral","server_id":"srv","realm_id":"realm","ah_pool_id":"neutral",
            "market_epoch":"epoch1","observed_at_utc_ms":ms,"page":page,"listfrom":page*50,"total":total,
            "record_count":n,"records":records}


class TerminalSpoolTests(unittest.TestCase):
    def test_full_scan_stays_one_capture_and_preserves_server_totals(self):
        rows=[raw(0,50,55,1000),raw(1,5,54,1100)]
        groups=terminal_spool.split_captures(rows)
        self.assertEqual(len(groups),1)
        events,identity=terminal_spool.to_segment(groups[0],1)
        self.assertEqual(events[-1]["status"],"completed")
        self.assertEqual([e["total"] for e in events[1:-1]],[55,54])
        self.assertEqual(identity["market_epoch"],"epoch1")

    def test_unfinished_full_scan_is_truncated_diagnostic(self):
        rows=[raw(0,50,100,1000),raw(1,50,100,1100)]
        events,_=terminal_spool.to_segment(terminal_spool.split_captures(rows)[0],1)
        self.assertEqual(events[-1]["status"],"truncated")

    def test_revalidation_is_distinct_capture(self):
        rows=[raw(7,1,100,1000,"revalidation_window")]
        events,_=terminal_spool.to_segment(terminal_spool.split_captures(rows)[0],1)
        self.assertEqual(events[0]["scope"],"revalidation_window")

    def test_import_uses_canonical_database_not_parallel_store(self):
        with tempfile.TemporaryDirectory() as td:
            spool=Path(td)/"spool.ndjson"
            spool.write_text("\n".join(json.dumps(r) for r in [raw(0,50,55,1000),raw(1,5,55,1100)])+"\n")
            db=history_worker.connect(Path(td)/"history.sqlite")
            try:
                result=terminal_spool.import_spool(db,spool)
                self.assertEqual(result[0]["history_sink"],"ok")
                self.assertEqual(db.execute("SELECT count(*) FROM scans").fetchone()[0],1)
                self.assertEqual(db.execute("SELECT count(*) FROM observations").fetchone()[0],55)
            finally:
                db.close()

if __name__=="__main__":
    unittest.main()
