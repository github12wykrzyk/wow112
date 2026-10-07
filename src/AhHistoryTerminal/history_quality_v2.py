#!/usr/bin/env python3
"""Quality-v2 projection for the canonical AH history SQLite database.

This module never creates a second market history. It derives versioned identity,
quality, and DE-material views from the existing `events/scans/observations`
tables produced by history_worker.py. Python standard library only.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from fractions import Fraction
import hashlib
import json
import sqlite3
import time

RULESET = "ah-quality-v2.0"
VIEW_ALGORITHM = "de-material-history-v1/eligible-v2/latest-per-30m-bucket"
REQUIRED_IDENTITY = ("server_id", "realm_id", "ah_pool", "market_epoch")


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(obj):
    return hashlib.sha256(canonical(obj).encode()).hexdigest()


def connect(path):
    db = sqlite3.connect(path, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("PRAGMA foreign_keys=ON")
    ensure_schema(db)
    return db


def ensure_schema(db):
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS market_identity_v2(
          scan_id TEXT PRIMARY KEY REFERENCES scans(scan_id),
          server_id TEXT NOT NULL,
          realm_id TEXT NOT NULL,
          ah_pool TEXT NOT NULL,
          market_epoch TEXT NOT NULL,
          identity_status TEXT NOT NULL,
          identity_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS scan_quality_v2(
          scan_id TEXT PRIMARY KEY REFERENCES scans(scan_id),
          ruleset TEXT NOT NULL,
          decision TEXT NOT NULL,
          reasons TEXT NOT NULL,
          metrics_json TEXT NOT NULL,
          evaluated_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS scan_quality_v2_decision ON scan_quality_v2(decision,ruleset);
        """
    )


def _events(db, scan_id):
    return [json.loads(r[0]) for r in db.execute(
        "SELECT payload FROM events WHERE scan_id=? ORDER BY seq", (scan_id,)
    )]


def _identity_from_events(events):
    candidates = []
    for e in events:
        value = e.get("market_identity")
        if isinstance(value, dict):
            candidates.append(value)
        evidence = e.get("market_evidence")
        if isinstance(evidence, dict) and evidence:
            candidates.append({
                "server_id": str(evidence.get("server_id", "")),
                "realm_id": str(evidence.get("realm_id", "")),
                "ah_pool": str(evidence.get("auction_house_id", "")),
                "market_epoch": str(evidence.get("market_epoch", "")),
                "identity_status": str(evidence.get("identity_status", "observed_not_reconciled")),
                "identity_source": "legacy_market_evidence",
            })
    if not candidates:
        return {k: "" for k in REQUIRED_IDENTITY} | {
            "identity_status": "missing",
            "identity_source": "none",
        }
    explicit = [c for c in candidates if all(str(c.get(k, "")).strip() for k in REQUIRED_IDENTITY)]
    chosen = dict(explicit[0] if explicit else candidates[0])
    for k in REQUIRED_IDENTITY:
        chosen[k] = str(chosen.get(k, "")).strip()
    chosen["identity_status"] = str(chosen.get("identity_status", "missing")).strip()
    chosen["identity_source"] = str(chosen.get("identity_source", "event")).strip()
    return chosen


def pagination_metrics_v2(events):
    pages = [e for e in events if e.get("event_type") == "PageObserved"]
    totals = [int(e.get("total", 0)) for e in pages]
    seen = {}
    duplicates = 0
    conflicts = 0
    adjacent_overlaps = 0
    suffix_prefix_boundaries = 0
    suffix_prefix_observations = 0
    previous = None
    for page in pages:
        rows = page.get("records") or []
        aids = [int(r["auction_id"]) for r in rows]
        for r in rows:
            aid = int(r["auction_id"])
            identity = (r.get("item_id"), r.get("count"), r.get("buyout_total_copper"), r.get("owner_token"))
            if aid in seen:
                duplicates += 1
                conflicts += seen[aid] != identity
            seen[aid] = identity
        if previous is not None:
            prev_aids = previous
            shared = set(prev_aids).intersection(aids)
            adjacent_overlaps += len(shared)
            if shared:
                k = len(shared)
                if k <= len(prev_aids) and k <= len(aids) and prev_aids[-k:] == aids[:k]:
                    suffix_prefix_boundaries += 1
                    suffix_prefix_observations += k
        previous = aids
    return {
        "page_count": len(pages),
        "observations": sum(len(e.get("records") or []) for e in pages),
        "unique_auction_ids": len(seen),
        "duplicate_observations": duplicates,
        "conflicting_identity_observations": conflicts,
        "adjacent_overlap_observations": adjacent_overlaps,
        "suffix_prefix_boundaries": suffix_prefix_boundaries,
        "suffix_prefix_observations": suffix_prefix_observations,
        "server_total_first": totals[0] if totals else None,
        "server_total_last": totals[-1] if totals else None,
        "server_total_min": min(totals) if totals else None,
        "server_total_max": max(totals) if totals else None,
        "last_page_records": len(pages[-1].get("records") or []) if pages else None,
    }


def evaluate_scan(db, scan_id, evaluated_ms=None):
    row = db.execute(
        "SELECT market,scope,status,quality,reasons FROM scans WHERE scan_id=?", (scan_id,)
    ).fetchone()
    if not row:
        raise ValueError("unknown scan_id")
    market, scope, status, _v1_quality, raw_reasons = row
    events = _events(db, scan_id)
    identity = _identity_from_events(events)
    metrics = pagination_metrics_v2(events)
    try:
        reasons = set(json.loads(raw_reasons))
    except Exception:
        reasons = {"invalid_v1_reasons"}
    if status != "completed":
        reasons.add("scan_not_completed")
    if scope != "full_market":
        reasons.add("partial_scope")
    missing = [k for k in REQUIRED_IDENTITY if not identity.get(k)]
    if missing:
        reasons.add("market_identity_incomplete:" + ",".join(missing))
    if identity.get("identity_status") != "verified":
        reasons.add("market_identity_not_verified")
    if metrics["conflicting_identity_observations"]:
        reasons.add("conflicting_auction_identity")
    if metrics["suffix_prefix_boundaries"]:
        reasons.add("pagination_suffix_prefix_overlap")
    if not metrics["page_count"] or metrics["last_page_records"] is None or metrics["last_page_records"] >= 50:
        reasons.add("no_terminal_page")
    decision = "eligible" if not reasons else "diagnostic_only"
    now = int(time.time() * 1000) if evaluated_ms is None else int(evaluated_ms)
    identity_json = canonical(identity)
    with db:
        db.execute(
            "INSERT OR REPLACE INTO market_identity_v2 VALUES(?,?,?,?,?,?,?)",
            (scan_id, identity["server_id"], identity["realm_id"], identity["ah_pool"],
             identity["market_epoch"], identity["identity_status"], identity_json),
        )
        db.execute(
            "INSERT OR REPLACE INTO scan_quality_v2 VALUES(?,?,?,?,?,?)",
            (scan_id, RULESET, decision, canonical(sorted(reasons)), canonical(metrics), now),
        )
    return {
        "scan_id": scan_id,
        "market_id": market,
        "ruleset": RULESET,
        "decision": decision,
        "reasons": sorted(reasons),
        "market_identity": identity,
        "metrics": metrics,
    }


def evaluate_all(db):
    return [evaluate_scan(db, r[0]) for r in db.execute("SELECT scan_id FROM scans ORDER BY started_ms,scan_id")]


def _weighted_price_percentile(offers, percentile):
    if not offers:
        return None
    offers = sorted(offers, key=lambda t: Fraction(t[0], t[1]))
    index = ((len(offers) - 1) * percentile) // 100
    buyout, units = offers[index]
    return {"numerator_copper": int(buyout), "denominator_units": int(units)}


def de_material_view(db, market, cutoff_ms, now_ms=None):
    """Shared DE-material history view from canonical observations only.

    No scan ending after cutoff_ms is visible, preventing future-data leakage.
    The view contains only quality-v2 eligible full-market scans and preserves
    provenance for every aggregate sample.
    """
    cutoff_ms = int(cutoff_ms)
    now_ms = cutoff_ms if now_ms is None else int(now_ms)
    evaluate_all(db)
    scans = db.execute(
        """
        SELECT s.scan_id,s.started_ms,s.ended_ms,s.unique_count,s.record_count,
               i.server_id,i.realm_id,i.ah_pool,i.market_epoch
        FROM scans s
        JOIN scan_quality_v2 q ON q.scan_id=s.scan_id AND q.ruleset=? AND q.decision='eligible'
        JOIN market_identity_v2 i ON i.scan_id=s.scan_id
        WHERE s.market=? AND s.scope='full_market' AND s.ended_ms<=?
        ORDER BY s.started_ms,s.scan_id
        """,
        (RULESET, market, cutoff_ms),
    ).fetchall()
    chosen = {}
    for row in scans:
        chosen[row[1] // 1_800_000] = row
    samples = []
    material_ids = set()
    for bucket, scan in sorted(chosen.items()):
        scan_id, _started_ms, _ended_ms, unique_count, record_count, server_id, realm_id, ah_pool, market_epoch = scan
        rows = db.execute(
            """SELECT auction_id,item_id,count,buyout,observed_ms,event_id,record_index
               FROM observations WHERE scan_id=? ORDER BY observed_ms,event_id,record_index""",
            (scan_id,),
        ).fetchall()
        auctions = {r[0]: r for r in rows}
        per_item = defaultdict(lambda: {"listings": 0, "units": 0, "offers": [], "last_ms": 0})
        for r in auctions.values():
            _, item_id, count, buyout, observed_ms, _, _ = r
            x = per_item[item_id]
            x["listings"] += 1
            x["units"] += count
            x["last_ms"] = max(x["last_ms"], observed_ms)
            if buyout > 0 and count > 0:
                x["offers"].append((buyout, count))
        for item_id, x in sorted(per_item.items()):
            material_ids.add(item_id)
            age_ms = max(0, now_ms - x["last_ms"])
            depth_score = min(1.0, len(x["offers"]) / 10.0)
            freshness_score = max(0.0, 1.0 - age_ms / (24 * 3600 * 1000))
            coverage_score = min(1.0, unique_count / max(record_count, 1))
            confidence = round(depth_score * 0.45 + freshness_score * 0.35 + coverage_score * 0.20, 6)
            samples.append({
                "item_id": item_id,
                "bucket_utc_ms": bucket * 1_800_000,
                "scan_id": scan_id,
                "observed_at_ms": x["last_ms"],
                "age_ms": age_ms,
                "freshness": "fresh" if age_ms <= 30 * 60 * 1000 else ("aging" if age_ms <= 6 * 3600 * 1000 else "stale"),
                "observed_listings": x["listings"],
                "observed_units": x["units"],
                "buyout_listings": len(x["offers"]),
                "offer_p10": _weighted_price_percentile(x["offers"], 10),
                "offer_p50": _weighted_price_percentile(x["offers"], 50),
                "offer_p90": _weighted_price_percentile(x["offers"], 90),
                "coverage": {"unique_auctions": unique_count, "raw_observations": record_count, "unique_ratio": round(unique_count / max(record_count, 1), 6)},
                "confidence": confidence,
                "provenance": {
                    "ruleset": RULESET,
                    "server_id": server_id,
                    "realm_id": realm_id,
                    "ah_pool": ah_pool,
                    "market_epoch": market_epoch,
                },
            })
    out = {
        "schema_version": 1,
        "algorithm_version": VIEW_ALGORITHM,
        "ruleset": RULESET,
        "market_id": market,
        "cutoff_ms": cutoff_ms,
        "eligible_scan_count": len(chosen),
        "material_count": len(material_ids),
        "samples": samples,
    }
    out["view_id"] = digest(out)
    return out


def shadow_price_map(view, max_age_ms=6 * 3600 * 1000, min_confidence=0.45):
    """Conservative point map for shadow comparison only; never a BUY authorization."""
    by_item = defaultdict(list)
    for s in view.get("samples", []):
        p = s.get("offer_p50")
        if not p or s.get("age_ms", 10**30) > max_age_ms or s.get("confidence", 0) < min_confidence:
            continue
        units = int(p["denominator_units"])
        if units <= 0:
            continue
        by_item[int(s["item_id"])].append(int(p["numerator_copper"]) // units)
    out = {}
    for item_id, values in by_item.items():
        values.sort()
        out[item_id] = values[len(values) // 2]
    return out


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("evaluate"); p.add_argument("db"); p.add_argument("--scan-id")
    p = sub.add_parser("de-view"); p.add_argument("db"); p.add_argument("market"); p.add_argument("--cutoff-ms", type=int, default=int(time.time()*1000))
    p = sub.add_parser("shadow-map"); p.add_argument("db"); p.add_argument("market"); p.add_argument("--cutoff-ms", type=int, default=int(time.time()*1000))
    args = ap.parse_args()
    db = connect(args.db)
    try:
        if args.command == "evaluate":
            result = evaluate_scan(db, args.scan_id) if args.scan_id else evaluate_all(db)
        else:
            view = de_material_view(db, args.market, args.cutoff_ms)
            result = view if args.command == "de-view" else {"view_id": view["view_id"], "prices": shadow_price_map(view)}
        print(canonical(result))
    finally:
        db.close()


if __name__ == "__main__":
    main()
