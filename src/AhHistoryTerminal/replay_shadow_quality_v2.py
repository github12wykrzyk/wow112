#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import history_worker as hw
import shadow_quality_v2 as q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("database")
    ap.add_argument("bundle")
    ap.add_argument("--server-id", required=True)
    ap.add_argument("--realm-id", required=True)
    ap.add_argument("--ah-pool-id", required=True)
    ap.add_argument("--market-epoch", required=True)
    ap.add_argument("--output")
    args = ap.parse_args()

    identity = {
        "server_id": args.server_id,
        "realm_id": args.realm_id,
        "ah_pool_id": args.ah_pool_id,
        "market_epoch": args.market_epoch,
    }
    events = hw.verify_bundle(Path(args.bundle))
    if len({e["scan_id"] for e in events}) != 1:
        raise SystemExit("V2 replay requires exactly one immutable scan bundle")

    db = hw.connect(args.database)
    try:
        outcome = q.reconcile_segment(db, events, identity)
        admission = outcome["v2_admission"]
        cutoff = events[-1]["observed_at_utc_ms"] + 1
        view = q.material_history_view(db, admission["canonical_market_id"], None, cutoff)
        stored = db.execute(
            "SELECT quality,reasons,record_count,unique_count FROM scans WHERE scan_id=?",
            (events[0]["scan_id"],),
        ).fetchone()
        report = {
            "schema_version": 1,
            "mode": "IMMUTABLE_SHADOW_REPLAY_V2",
            "scan_id": events[0]["scan_id"],
            "raw_market_id": events[0]["market_id"],
            "canonical_market_id": admission["canonical_market_id"],
            "identity": identity,
            "v0": {
                "quality": stored[0],
                "reasons": json.loads(stored[1]),
                "record_count": stored[2],
                "unique_count": stored[3],
            },
            "v2": {
                "quality_rule_version": q.QUALITY_RULE_VERSION,
                "eligible": admission["eligible"],
                "inclusion_reason": admission["inclusion_reason"],
                "exclusion_reasons": admission["exclusion_reasons"],
                "metrics": admission["metrics"],
                "material_view_version": q.MATERIAL_VIEW_VERSION,
                "material_view_items": len(view["items"]),
                "view_id": view["view_id"],
                "buy_decision_changed": 0,
            },
            "safety": {
                "immutable_capture_rewritten": False,
                "v0_quality_mutated": False,
                "history_can_authorize_buy": False,
                "future_observations_allowed": False,
            },
        }
        text = json.dumps(report, indent=2) + "\n"
        if args.output:
            Path(args.output).write_text(text)
        print(text, end="")
        if not admission["eligible"]:
            raise SystemExit(2)
    finally:
        db.close()


if __name__ == "__main__":
    main()
