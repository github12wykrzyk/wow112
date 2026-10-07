#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path

import github_archive
import history_worker as hw
import shadow_quality_v2 as q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("database")
    ap.add_argument("output")
    ap.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "github12wykrzyk/wow112"))
    ap.add_argument("--server-id", required=True)
    ap.add_argument("--realm-id", required=True)
    ap.add_argument("--ah-pool-id", required=True)
    ap.add_argument("--market-epoch", required=True)
    args = ap.parse_args()

    identity = {
        "server_id": args.server_id,
        "realm_id": args.realm_id,
        "ah_pool_id": args.ah_pool_id,
        "market_epoch": args.market_epoch,
    }
    db_path = Path(args.database)
    db_path.parent.mkdir(parents=True, exist_ok=True)

    archive = github_archive.GitHubArchive(args.repository, os.environ.get("GITHUB_TOKEN"))
    restore = archive.restore(db_path)

    db = hw.connect(db_path)
    admissions = []
    skipped = []
    try:
        scans = db.execute(
            "SELECT scan_id,market,source,scope,status,started_ms,ended_ms,quality,reasons "
            "FROM scans ORDER BY ended_ms,scan_id"
        ).fetchall()
        for scan in scans:
            scan_id, raw_market, source, scope, status, started_ms, ended_ms, base_quality, reasons_json = scan
            if source != "live":
                skipped.append({"scan_id": scan_id, "reason": "non_live_source"})
                continue
            if not raw_market.startswith("live-test:octowow:"):
                skipped.append({"scan_id": scan_id, "reason": "market_not_mapped", "raw_market_id": raw_market})
                continue
            rows = db.execute(
                "SELECT payload FROM events WHERE scan_id=? ORDER BY seq",
                (scan_id,),
            ).fetchall()
            events = [json.loads(r[0]) for r in rows]
            try:
                result = q.reconcile_segment(db, events, identity)
                admission = result["v2_admission"]
                admissions.append({
                    "scan_id": scan_id,
                    "raw_market_id": raw_market,
                    "started_ms": started_ms,
                    "ended_ms": ended_ms,
                    "status": status,
                    "v0_quality": base_quality,
                    "v0_reasons": json.loads(reasons_json),
                    "v2_eligible": admission["eligible"],
                    "v2_exclusion_reasons": admission["exclusion_reasons"],
                    "metrics": admission["metrics"],
                })
            except Exception as exc:
                admissions.append({
                    "scan_id": scan_id,
                    "raw_market_id": raw_market,
                    "started_ms": started_ms,
                    "ended_ms": ended_ms,
                    "status": status,
                    "v0_quality": base_quality,
                    "v0_reasons": json.loads(reasons_json),
                    "v2_eligible": False,
                    "v2_exclusion_reasons": ["reconciliation_error:" + type(exc).__name__],
                })

        canonical_market = q.canonical_market_id(identity)
        cutoff = max((a["ended_ms"] for a in admissions), default=0) + 1
        view = q.material_history_view(db, canonical_market, None, cutoff) if cutoff else {
            "items": [], "view_id": None, "material_view_version": q.MATERIAL_VIEW_VERSION
        }
        eligible = sum(1 for a in admissions if a.get("v2_eligible"))
        report = {
            "schema_version": 1,
            "mode": "CUMULATIVE_IMMUTABLE_ARCHIVE_REPLAY_V2",
            "repository": args.repository,
            "archive_restore": restore,
            "identity": identity,
            "canonical_market_id": canonical_market,
            "quality_rule_version": q.QUALITY_RULE_VERSION,
            "material_view_version": q.MATERIAL_VIEW_VERSION,
            "scans_total": len(scans),
            "scans_reconciled": len(admissions),
            "scans_v2_eligible": eligible,
            "scans_v2_diagnostic": len(admissions) - eligible,
            "scans_skipped": len(skipped),
            "cutoff_ms": cutoff,
            "material_view_items": len(view.get("items", [])),
            "view_id": view.get("view_id"),
            "admissions": admissions,
            "skipped": skipped,
            "safety": {
                "live_game_connection": False,
                "immutable_capture_rewritten": False,
                "v0_quality_mutated": False,
                "history_can_authorize_buy": False,
                "buy_decision_changed": 0,
            },
        }
        Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not admissions:
            raise SystemExit("no live archive scans were reconciled")
    finally:
        db.close()


if __name__ == "__main__":
    main()
