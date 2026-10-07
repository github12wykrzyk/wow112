#!/usr/bin/env python3
import argparse
import csv
import json
import os
from pathlib import Path

import github_archive
import history_worker as hw
import shadow_quality_v2 as q


def write_pricebook_csv(view, output_path):
    """Export an audit-only, point-in-time V2 pricebook from the reconciled immutable view.

    Prices are floored to whole copper so this exporter never rounds a historical
    unit price upward.  The file is evidence only; the terminal must not use it to
    authorize, retry, reorder, or mutate BUY.
    """
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for item in view.get("items", []):
        price = item.get("unit_price") or {}
        numerator = int(price.get("numerator_copper") or 0)
        denominator = int(price.get("denominator_units") or 0)
        unit_price = numerator // denominator if numerator > 0 and denominator > 0 else 0
        if unit_price <= 0:
            continue
        rows.append({
            "item_id": int(item["item_id"]),
            "history_unit_price_copper": unit_price,
            "confidence_bps": int(round(float(item.get("confidence", 0.0)) * 10_000)),
            "sample_scans": int(item.get("sample_scans", 0)),
            "freshness_bps": int(round(float(item.get("freshness", 0.0)) * 10_000)),
            "coverage_bps": int(round(float(item.get("coverage", 0.0)) * 10_000)),
            "observed_supply_units_mean": item.get("observed_supply_units_mean", 0),
            "observed_depth_listings_mean": item.get("observed_depth_listings_mean", 0),
            "latest_observed_ms": int(item.get("latest_observed_ms", 0)),
            "view_id": view.get("view_id") or "",
            "quality_rule_version": view.get("quality_rule_version") or "",
            "material_view_version": view.get("material_view_version") or "",
        })
    fieldnames = [
        "item_id",
        "history_unit_price_copper",
        "confidence_bps",
        "sample_scans",
        "freshness_bps",
        "coverage_bps",
        "observed_supply_units_mean",
        "observed_depth_listings_mean",
        "latest_observed_ms",
        "view_id",
        "quality_rule_version",
        "material_view_version",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("database")
    ap.add_argument("output")
    ap.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "github12wykrzyk/wow112"))
    ap.add_argument("--server-id", required=True)
    ap.add_argument("--realm-id", required=True)
    ap.add_argument("--ah-pool-id", required=True)
    ap.add_argument("--market-epoch", required=True)
    ap.add_argument("--pricebook-csv")
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
            "items": [], "view_id": None, "material_view_version": q.MATERIAL_VIEW_VERSION,
            "quality_rule_version": q.QUALITY_RULE_VERSION,
        }
        pricebook_rows = 0
        if args.pricebook_csv:
            pricebook_rows = write_pricebook_csv(view, args.pricebook_csv)
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
            "pricebook_csv": args.pricebook_csv,
            "pricebook_rows": pricebook_rows,
            "admissions": admissions,
            "skipped": skipped,
            "safety": {
                "live_game_connection": False,
                "immutable_capture_rewritten": False,
                "v0_quality_mutated": False,
                "history_can_authorize_buy": False,
                "history_can_retry_buy": False,
                "history_can_reorder_buy": False,
                "buy_decision_changed": 0,
            },
        }
        Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not admissions:
            raise SystemExit("no live archive scans were reconciled")
        if args.pricebook_csv and pricebook_rows == 0:
            raise SystemExit("shadow pricebook export produced zero rows")
    finally:
        db.close()


if __name__ == "__main__":
    main()
