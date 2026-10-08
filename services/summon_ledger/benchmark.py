from __future__ import annotations

import argparse
import json
import tempfile
import time
from datetime import timedelta
from pathlib import Path

from .ledger import Ledger, utc_now, utc_text


def event(i: int, now, request_count: int):
    request_no = i % request_count
    request_id = "bench-request-%06d" % request_no
    customer = "BenchPlayer%03d" % (request_no % 500)
    return {
        "schema_version": 1,
        "event_id": "bench-event-%07d" % i,
        "ts_utc": utc_text(now - timedelta(seconds=(50000 - i) % 7200)),
        "type": "PaymentReceived",
        "session_id": "bench-session-%02d" % (request_no % 20),
        "request_id": request_id,
        "customer": customer,
        "destination": "Hyjal" if request_no % 2 else "Azshara",
        "state": "received",
        "amount_copper": 40000,
        "correlation_id": "bench-corr-%06d" % request_no,
        "severity": "info",
        "metadata": {"benchmark": True},
    }


def run(records: int, max_query_ms: float | None) -> dict:
    request_count = min(1000, max(1, records // 10))
    now = utc_now()
    with tempfile.TemporaryDirectory() as tmp:
        db = Path(tmp) / "bench.sqlite3"
        with Ledger(db) as ledger:
            batch = [event(i, now, request_count) for i in range(records)]
            start = time.perf_counter()
            ledger.ingest_many(batch)
            ingest_s = time.perf_counter() - start

            start = time.perf_counter()
            player = ledger.find_player("BenchPlayer042", utc_text(now - timedelta(hours=2)))
            player_ms = (time.perf_counter() - start) * 1000

            start = time.perf_counter()
            recent = ledger.revenue(since_utc=utc_text(now - timedelta(hours=1)))
            revenue_ms = (time.perf_counter() - start) * 1000

            start = time.perf_counter()
            stats = ledger.stats(now)
            stats_ms = (time.perf_counter() - start) * 1000

            result = {
                "records": records,
                "requests": request_count,
                "db_bytes": db.stat().st_size,
                "ingest_seconds": round(ingest_s, 4),
                "events_per_second": round(records / ingest_s, 1) if ingest_s else None,
                "find_player_ms": round(player_ms, 3),
                "revenue_ms": round(revenue_ms, 3),
                "stats_ms": round(stats_ms, 3),
                "player_payment_count": player["payment_count"],
                "total_event_count": stats["event_count"],
                "recent_revenue_copper": recent["revenue_copper"],
            }
            if stats["event_count"] != records:
                raise SystemExit("benchmark integrity failure")
            if max_query_ms is not None and max(player_ms, revenue_ms, stats_ms) > max_query_ms:
                raise SystemExit("benchmark query threshold exceeded: %s" % result)
            return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--records", type=int, default=50000)
    parser.add_argument("--max-query-ms", type=float)
    args = parser.parse_args(argv)
    if args.records < 50000:
        raise SystemExit("benchmark requires at least 50000 records")
    print(json.dumps(run(args.records, args.max_query_ms), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
