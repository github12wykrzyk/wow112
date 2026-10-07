#!/usr/bin/env python3
"""Shared shadow-history extensions for AhHistoryTerminal.

This module deliberately does not place trades.  It extends the existing V0 SQLite
history in-place with market identity, versioned quality-policy provenance, a
point-in-time DE-material view and current-vs-history valuation audit rows.
"""
from __future__ import annotations

import json
import math
import sqlite3
import time
from collections import defaultdict
from fractions import Fraction
from typing import Iterable

import history_worker

SCHEMA_VERSION = 1
IDENTITY_VERSION = "market-identity-v1"
QUALITY_RULE_VERSION = "ah-quality-v1"
MATERIAL_VIEW_VERSION = "de-material-history-v1"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def ensure_schema(db: sqlite3.Connection) -> None:
    """Additive only: keep history_worker PRAGMA user_version=1 compatible."""
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS market_identity(
          market_id TEXT PRIMARY KEY,
          server_id TEXT NOT NULL,
          realm_id TEXT NOT NULL,
          ah_pool_id TEXT NOT NULL,
          market_epoch TEXT NOT NULL,
          identity_version TEXT NOT NULL,
          first_seen_ms INTEGER NOT NULL,
          last_seen_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS quality_rule_versions(
          rule_version TEXT PRIMARY KEY,
          rules_json TEXT NOT NULL,
          activated_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS scan_context(
          scan_id TEXT PRIMARY KEY REFERENCES scans(scan_id),
          rule_version TEXT NOT NULL REFERENCES quality_rule_versions(rule_version),
          capture_scope TEXT NOT NULL,
          inclusion_reason TEXT NOT NULL,
          exclusion_reasons TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS shadow_valuations(
          decision_id TEXT PRIMARY KEY,
          observed_ms INTEGER NOT NULL,
          market_id TEXT NOT NULL,
          target_auction_id INTEGER,
          target_item_id INTEGER NOT NULL,
          current_value_copper INTEGER NOT NULL,
          history_value_copper INTEGER,
          delta_copper INTEGER,
          material_view_version TEXT NOT NULL,
          cutoff_ms INTEGER NOT NULL,
          provenance_json TEXT NOT NULL,
          buy_decision_changed INTEGER NOT NULL CHECK(buy_decision_changed=0)
        );
        CREATE INDEX IF NOT EXISTS shadow_market_item_time
          ON shadow_valuations(market_id,target_item_id,observed_ms);
        """
    )
    db.commit()


def register_quality_rules(db, rule_version=QUALITY_RULE_VERSION, rules=None, activated_ms=None):
    ensure_schema(db)
    rules = rules or {
        "eligible_scan_requires": "history_worker quality=eligible",
        "incomplete_scans": "diagnostic_only",
        "future_observations": "forbidden",
        "auction_disappearance": "not_a_sale_signal",
        "dedupe": "latest_observation_per_auction_within_scan",
        "confidence": "coverage_freshness_depth_v1",
    }
    activated_ms = int(time.time() * 1000) if activated_ms is None else int(activated_ms)
    with db:
        db.execute(
            "INSERT OR IGNORE INTO quality_rule_versions VALUES(?,?,?)",
            (rule_version, canonical(rules), activated_ms),
        )
    return rule_version


def register_market_identity(
    db,
    market_id,
    server_id,
    realm_id,
    ah_pool_id,
    market_epoch,
    observed_ms,
    identity_version=IDENTITY_VERSION,
):
    ensure_schema(db)
    values = [market_id, server_id, realm_id, ah_pool_id, market_epoch, identity_version]
    if any(not isinstance(x, str) or not x.strip() for x in values):
        raise ValueError("market identity fields must be non-empty strings")
    observed_ms = int(observed_ms)
    row = db.execute(
        "SELECT server_id,realm_id,ah_pool_id,market_epoch,identity_version,first_seen_ms,last_seen_ms "
        "FROM market_identity WHERE market_id=?",
        (market_id,),
    ).fetchone()
    if row and tuple(row[:5]) != (server_id, realm_id, ah_pool_id, market_epoch, identity_version):
        raise ValueError("market_id identity conflict")
    with db:
        if row:
            db.execute(
                "UPDATE market_identity SET first_seen_ms=?,last_seen_ms=? WHERE market_id=?",
                (min(row[5], observed_ms), max(row[6], observed_ms), market_id),
            )
        else:
            db.execute(
                "INSERT INTO market_identity VALUES(?,?,?,?,?,?,?,?)",
                (market_id, server_id, realm_id, ah_pool_id, market_epoch, identity_version, observed_ms, observed_ms),
            )


def ingest_shared_segment(db, events, identity, rule_version=QUALITY_RULE_VERSION):
    """Ingest into the existing history tables and attach identity/policy provenance."""
    ensure_schema(db)
    register_quality_rules(db, rule_version=rule_version, activated_ms=events[0]["observed_at_utc_ms"])
    register_market_identity(db, observed_ms=events[0]["observed_at_utc_ms"], **identity)
    result = history_worker.ingest_events(db, events)
    scan_id = events[0]["scan_id"]
    scan = db.execute("SELECT scope,quality,reasons FROM scans WHERE scan_id=?", (scan_id,)).fetchone()
    if not scan:
        raise RuntimeError("scan missing after ingest")
    exclusion = json.loads(scan[2])
    inclusion = "eligible_for_decision_stats" if scan[1] == "eligible" else "diagnostic_only"
    with db:
        db.execute(
            "INSERT OR REPLACE INTO scan_context VALUES(?,?,?,?,?)",
            (scan_id, rule_version, scan[0], inclusion, canonical(exclusion)),
        )
    return result


def safe_ingest_shared_segment(db, events, identity, rule_version=QUALITY_RULE_VERSION):
    """Best-effort history sink. Storage/history failure never authorizes or retries BUY."""
    try:
        return {"history_sink": "ok", "result": ingest_shared_segment(db, events, identity, rule_version)}
    except Exception as exc:
        return {"history_sink": "failed_open_for_scan", "error_type": type(exc).__name__, "error": str(exc)}


def _median_fraction(values):
    if not values:
        return None
    values = sorted(values)
    return values[len(values) // 2]


def material_history_view(
    db,
    market_id,
    item_ids: Iterable[int] | None,
    cutoff_ms,
    max_age_ms=48 * 60 * 60 * 1000,
    max_scans=12,
):
    """Point-in-time shared DE-material view; never reads observations after cutoff_ms."""
    ensure_schema(db)
    cutoff_ms = int(cutoff_ms)
    max_age_ms = int(max_age_ms)
    wanted = None if item_ids is None else {int(x) for x in item_ids}
    scans = db.execute(
        "SELECT scan_id,started_ms,ended_ms,record_count,unique_count FROM scans "
        "WHERE market=? AND quality='eligible' AND scope='full_market' AND ended_ms<=? "
        "ORDER BY ended_ms DESC,scan_id DESC LIMIT ?",
        (market_id, cutoff_ms, int(max_scans)),
    ).fetchall()
    scans = [s for s in scans if cutoff_ms - s[2] <= max_age_ms]
    per_item = defaultdict(lambda: {"scan_samples": [], "scan_ids": []})
    for scan_id, _started, ended_ms, record_count, unique_count in scans:
        rows = db.execute(
            "SELECT auction_id,item_id,count,buyout,owner_token,observed_ms,event_id,record_index "
            "FROM observations WHERE scan_id=? AND observed_ms<=? "
            "ORDER BY observed_ms,event_id,record_index",
            (scan_id, cutoff_ms),
        ).fetchall()
        latest = {r[0]: r for r in rows}
        items = defaultdict(list)
        for r in latest.values():
            if wanted is not None and r[1] not in wanted:
                continue
            if r[2] <= 0 or r[3] <= 0:
                continue
            items[r[1]].append(r)
        for item_id, listings in items.items():
            unit_prices = [Fraction(r[3], r[2]) for r in listings]
            total_units = sum(r[2] for r in listings)
            sellers = len({r[4] for r in listings if r[4]})
            sample = {
                "scan_id": scan_id,
                "ended_ms": ended_ms,
                "listings": len(listings),
                "units": total_units,
                "sellers": sellers,
                "median": _median_fraction(unit_prices),
                "min": min(unit_prices),
                "coverage": (unique_count / record_count) if record_count else 0.0,
            }
            per_item[item_id]["scan_samples"].append(sample)
            per_item[item_id]["scan_ids"].append(scan_id)
    out = []
    for item_id in sorted(per_item):
        samples = per_item[item_id]["scan_samples"]
        newest = max(s["ended_ms"] for s in samples)
        age_ms = cutoff_ms - newest
        medians = [s["median"] for s in samples if s["median"] is not None]
        history_price = _median_fraction(medians)
        avg_units = sum(s["units"] for s in samples) / len(samples)
        avg_listings = sum(s["listings"] for s in samples) / len(samples)
        avg_coverage = sum(s["coverage"] for s in samples) / len(samples)
        freshness = max(0.0, 1.0 - age_ms / max_age_ms) if max_age_ms else 0.0
        scan_factor = min(1.0, len(samples) / 4.0)
        depth_factor = min(1.0, math.log2(1.0 + avg_units) / 6.0)
        confidence = max(0.0, min(1.0, 0.35 * avg_coverage + 0.30 * freshness + 0.20 * scan_factor + 0.15 * depth_factor))
        num = history_price.numerator if history_price is not None else None
        den = history_price.denominator if history_price is not None else None
        out.append({
            "item_id": item_id,
            "unit_price": None if history_price is None else {"numerator_copper": num, "denominator_units": den},
            "observed_supply_units_mean": round(avg_units, 3),
            "observed_depth_listings_mean": round(avg_listings, 3),
            "latest_observed_ms": newest,
            "age_ms": age_ms,
            "freshness": round(freshness, 6),
            "coverage": round(avg_coverage, 6),
            "confidence": round(confidence, 6),
            "sample_scans": len(samples),
            "provenance_scan_ids": sorted(per_item[item_id]["scan_ids"]),
        })
    result = {
        "schema_version": SCHEMA_VERSION,
        "material_view_version": MATERIAL_VIEW_VERSION,
        "market_id": market_id,
        "cutoff_ms": cutoff_ms,
        "max_age_ms": max_age_ms,
        "items": out,
    }
    result["view_id"] = history_worker.digest(canonical(result).encode())
    return result


def record_shadow_valuation(
    db,
    decision_id,
    observed_ms,
    market_id,
    target_item_id,
    current_value_copper,
    history_value_copper,
    cutoff_ms,
    provenance,
    target_auction_id=None,
):
    """Audit only. The DB constraint permanently records buy_decision_changed=0."""
    ensure_schema(db)
    current_value_copper = int(current_value_copper)
    history_value_copper = None if history_value_copper is None else int(history_value_copper)
    delta = None if history_value_copper is None else history_value_copper - current_value_copper
    with db:
        db.execute(
            "INSERT OR REPLACE INTO shadow_valuations VALUES(?,?,?,?,?,?,?,?,?,?,?,0)",
            (
                decision_id, int(observed_ms), market_id, target_auction_id, int(target_item_id),
                current_value_copper, history_value_copper, delta, MATERIAL_VIEW_VERSION,
                int(cutoff_ms), canonical(provenance),
            ),
        )
    return {"decision_id": decision_id, "current_value_copper": current_value_copper,
            "history_value_copper": history_value_copper, "delta_copper": delta,
            "buy_decision_changed": False}
