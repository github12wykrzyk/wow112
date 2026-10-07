#!/usr/bin/env python3
"""Calibrated, additive shadow-history admission for real full-market AH scans.

This module does not alter immutable captures and does not weaken the strict V0
history_worker quality flag. It adds a versioned reconciliation/admission layer
for real-market shadow statistics after market identity is explicitly mapped.
"""
from __future__ import annotations

import json
import math
import sqlite3
import urllib.parse
from collections import defaultdict
from fractions import Fraction
from typing import Iterable

import history_worker

SCHEMA_VERSION = 1
IDENTITY_VERSION = "market-identity-v2-reconciled"
QUALITY_RULE_VERSION = "ah-quality-v2-live-churn-calibrated"
MATERIAL_VIEW_VERSION = "de-material-history-v2-reconciled"

MAX_DUPLICATE_RATIO = 0.02
MAX_TOTAL_DRIFT_RATIO = 0.01
MAX_UNIQUE_TOTAL_GAP_RATIO = 0.02
MAX_OBS_TOTAL_GAP_RATIO = 0.01
ABS_COUNT_TOLERANCE_FLOOR = 10

# V0 reasons that V2 may supersede only after explicit reconciliation/calibration.
OVERRIDABLE_V0_REASONS = {"unique_total_mismatch", "unverified_market_identity"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _nonempty(value, name):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value.strip()


def canonical_market_id(identity):
    server = _nonempty(identity.get("server_id"), "server_id")
    realm = _nonempty(identity.get("realm_id"), "realm_id")
    pool = _nonempty(identity.get("ah_pool_id"), "ah_pool_id")
    epoch = _nonempty(identity.get("market_epoch"), "market_epoch")
    q = lambda s: urllib.parse.quote(s, safe="-_.")
    return f"market-v2:{q(server)}:realm={q(realm)}:ah={q(pool)}:epoch={q(epoch)}"


def ensure_schema(db: sqlite3.Connection) -> None:
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS quality_v2_market_identity(
          canonical_market_id TEXT PRIMARY KEY,
          server_id TEXT NOT NULL,
          realm_id TEXT NOT NULL,
          ah_pool_id TEXT NOT NULL,
          market_epoch TEXT NOT NULL,
          identity_version TEXT NOT NULL,
          first_seen_ms INTEGER NOT NULL,
          last_seen_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS quality_v2_rules(
          rule_version TEXT PRIMARY KEY,
          rules_json TEXT NOT NULL,
          activated_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS quality_v2_scan_admission(
          scan_id TEXT PRIMARY KEY REFERENCES scans(scan_id),
          raw_market_id TEXT NOT NULL,
          canonical_market_id TEXT NOT NULL REFERENCES quality_v2_market_identity(canonical_market_id),
          rule_version TEXT NOT NULL REFERENCES quality_v2_rules(rule_version),
          inclusion_reason TEXT NOT NULL,
          exclusion_reasons TEXT NOT NULL,
          metrics_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS quality_v2_market_scan
          ON quality_v2_scan_admission(canonical_market_id,inclusion_reason,scan_id);
        """
    )
    db.commit()


def quality_rules():
    return {
        "base_policy": "V0 remains immutable/strict; V2 is additive admission only",
        "overridable_v0_reasons": sorted(OVERRIDABLE_V0_REASONS),
        "max_duplicate_ratio": MAX_DUPLICATE_RATIO,
        "max_total_drift_ratio": MAX_TOTAL_DRIFT_RATIO,
        "max_unique_total_gap_ratio": MAX_UNIQUE_TOTAL_GAP_RATIO,
        "max_observation_total_gap_ratio": MAX_OBS_TOTAL_GAP_RATIO,
        "absolute_count_tolerance_floor": ABS_COUNT_TOLERANCE_FLOOR,
        "conflicting_identity_observations": 0,
        "requires_completed_full_market": True,
        "requires_terminal_page": True,
        "requires_explicit_market_reconciliation_for_live_test": True,
        "future_observations": "forbidden",
        "buy_decision_influence": "none",
    }


def register_rules(db, activated_ms):
    ensure_schema(db)
    with db:
        db.execute(
            "INSERT OR IGNORE INTO quality_v2_rules VALUES(?,?,?)",
            (QUALITY_RULE_VERSION, canonical(quality_rules()), int(activated_ms)),
        )


def register_identity(db, identity, observed_ms):
    ensure_schema(db)
    market = canonical_market_id(identity)
    fields = (
        _nonempty(identity.get("server_id"), "server_id"),
        _nonempty(identity.get("realm_id"), "realm_id"),
        _nonempty(identity.get("ah_pool_id"), "ah_pool_id"),
        _nonempty(identity.get("market_epoch"), "market_epoch"),
    )
    row = db.execute(
        "SELECT server_id,realm_id,ah_pool_id,market_epoch,identity_version,first_seen_ms,last_seen_ms "
        "FROM quality_v2_market_identity WHERE canonical_market_id=?",
        (market,),
    ).fetchone()
    if row and tuple(row[:5]) != (*fields, IDENTITY_VERSION):
        raise ValueError("canonical market identity conflict")
    observed_ms = int(observed_ms)
    with db:
        if row:
            db.execute(
                "UPDATE quality_v2_market_identity SET first_seen_ms=?,last_seen_ms=? WHERE canonical_market_id=?",
                (min(row[5], observed_ms), max(row[6], observed_ms), market),
            )
        else:
            db.execute(
                "INSERT INTO quality_v2_market_identity VALUES(?,?,?,?,?,?,?,?)",
                (market, *fields, IDENTITY_VERSION, observed_ms, observed_ms),
            )
    return market


def _ratio_gap(a, b):
    ref = max(int(a or 0), int(b or 0), 1)
    return abs(int(a or 0) - int(b or 0)) / ref


def _market_evidence(events):
    values = []
    for event in events[1:-1]:
        evidence = event.get("market_evidence")
        if evidence is not None:
            values.append(evidence)
    if not values:
        return None, ["market_evidence_missing"]
    normalized = []
    for value in values:
        if not isinstance(value, dict):
            return None, ["market_evidence_invalid"]
        try:
            realm = int(value["realm_id"])
            pool = int(value["auction_house_id"])
        except (KeyError, TypeError, ValueError):
            return None, ["market_evidence_invalid"]
        normalized.append((realm, pool))
    if len(set(normalized)) != 1:
        return None, ["market_evidence_changed_within_scan"]
    return normalized[0], []


def evaluate(events, identity):
    first, status, base_quality, base_reasons, _rows, _unique_count = history_worker.validate(events)
    metrics = history_worker.pagination_metrics(events)
    exclusions = []

    if status != "completed":
        exclusions.append("not_completed")
    if first["scope"] != "full_market":
        exclusions.append("not_full_market")

    hard_v0 = sorted(set(base_reasons) - OVERRIDABLE_V0_REASONS)
    exclusions.extend(f"v0:{reason}" for reason in hard_v0)

    observations = int(metrics["observations"])
    duplicates = int(metrics["duplicate_observations"])
    conflicts = int(metrics["conflicting_identity_observations"])
    last_total = metrics["server_total_last"]
    total_min = metrics["server_total_min"]
    total_max = metrics["server_total_max"]
    last_page = metrics["last_page_records"]

    duplicate_ratio = duplicates / max(observations, 1)
    total_drift_ratio = 0.0 if total_min is None or total_max is None else (total_max - total_min) / max(total_max, 1)
    unique_total_gap_ratio = 0.0 if last_total is None else _ratio_gap(metrics["unique_auction_ids"], last_total)
    observation_total_gap_ratio = 0.0 if last_total is None else _ratio_gap(observations, last_total)

    metrics.update({
        "duplicate_ratio": round(duplicate_ratio, 8),
        "server_total_drift_ratio": round(total_drift_ratio, 8),
        "unique_total_gap_ratio": round(unique_total_gap_ratio, 8),
        "observation_total_gap_ratio": round(observation_total_gap_ratio, 8),
        "quality_rule_version": QUALITY_RULE_VERSION,
        "v0_quality": base_quality,
        "v0_reasons": list(base_reasons),
    })

    if conflicts != 0:
        exclusions.append("conflicting_identity_observations")
    if duplicate_ratio > MAX_DUPLICATE_RATIO:
        exclusions.append("duplicate_churn_above_limit")
    if total_drift_ratio > MAX_TOTAL_DRIFT_RATIO:
        exclusions.append("server_total_drift_above_limit")
    if unique_total_gap_ratio > MAX_UNIQUE_TOTAL_GAP_RATIO:
        exclusions.append("unique_total_gap_above_limit")
    if observation_total_gap_ratio > MAX_OBS_TOTAL_GAP_RATIO:
        exclusions.append("observation_total_gap_above_limit")
    if last_page is None or last_page >= 50:
        exclusions.append("terminal_page_missing")

    if observations - int(metrics["unique_auction_ids"]) != duplicates:
        exclusions.append("duplicate_accounting_inconsistent")

    raw_market = first["market_id"]
    if first["source"] == "live" and raw_market.startswith("live-test:"):
        evidence, evidence_errors = _market_evidence(events)
        exclusions.extend(evidence_errors)
        if evidence is not None:
            try:
                expected_realm = int(_nonempty(identity.get("realm_id"), "realm_id"))
                expected_pool = int(_nonempty(identity.get("ah_pool_id"), "ah_pool_id"))
            except ValueError:
                exclusions.append("configured_identity_not_numeric")
            else:
                if evidence != (expected_realm, expected_pool):
                    exclusions.append("market_identity_evidence_mismatch")

    exclusions = sorted(set(exclusions))
    return {
        "eligible": not exclusions,
        "inclusion_reason": "eligible_for_decision_stats" if not exclusions else "diagnostic_only",
        "exclusion_reasons": exclusions,
        "metrics": metrics,
        "raw_market_id": raw_market,
        "canonical_market_id": canonical_market_id(identity),
        "quality_rule_version": QUALITY_RULE_VERSION,
    }


def reconcile_segment(db, events, identity):
    """Import immutable events via V0, then attach V2 market/admission provenance."""
    ensure_schema(db)
    result = history_worker.ingest_events(db, events)
    started = events[0]["observed_at_utc_ms"]
    ended = events[-1]["observed_at_utc_ms"]
    register_rules(db, started)
    market = register_identity(db, identity, started)
    register_identity(db, identity, ended)
    admission = evaluate(events, identity)
    if admission["canonical_market_id"] != market:
        raise RuntimeError("canonical market identity mismatch")
    with db:
        db.execute(
            "INSERT OR REPLACE INTO quality_v2_scan_admission VALUES(?,?,?,?,?,?,?)",
            (
                events[0]["scan_id"],
                events[0]["market_id"],
                market,
                QUALITY_RULE_VERSION,
                admission["inclusion_reason"],
                canonical(admission["exclusion_reasons"]),
                canonical(admission["metrics"]),
            ),
        )
    return {"base_ingest": result, "v2_admission": admission}


def _median_fraction(values):
    if not values:
        return None
    values = sorted(values)
    return values[len(values) // 2]


def material_history_view(
    db,
    canonical_market,
    item_ids: Iterable[int] | None,
    cutoff_ms,
    max_age_ms=48 * 60 * 60 * 1000,
    max_scans=12,
):
    """Point-in-time V2 view using only explicitly admitted, completed scans."""
    ensure_schema(db)
    cutoff_ms = int(cutoff_ms)
    max_age_ms = int(max_age_ms)
    wanted = None if item_ids is None else {int(x) for x in item_ids}
    scans = db.execute(
        "SELECT s.scan_id,s.started_ms,s.ended_ms,s.record_count,s.unique_count "
        "FROM quality_v2_scan_admission a JOIN scans s ON s.scan_id=a.scan_id "
        "WHERE a.canonical_market_id=? AND a.inclusion_reason='eligible_for_decision_stats' "
        "AND s.status='completed' AND s.scope='full_market' AND s.ended_ms<=? "
        "ORDER BY s.ended_ms DESC,s.scan_id DESC LIMIT ?",
        (canonical_market, cutoff_ms, int(max_scans)),
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
            per_item[item_id]["scan_samples"].append({
                "scan_id": scan_id,
                "ended_ms": ended_ms,
                "listings": len(listings),
                "units": total_units,
                "sellers": sellers,
                "median": _median_fraction(unit_prices),
                "min": min(unit_prices),
                "coverage": (unique_count / record_count) if record_count else 0.0,
            })
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
        confidence = max(0.0, min(
            1.0,
            0.35 * avg_coverage + 0.30 * freshness + 0.20 * scan_factor + 0.15 * depth_factor,
        ))
        out.append({
            "item_id": item_id,
            "unit_price": None if history_price is None else {
                "numerator_copper": history_price.numerator,
                "denominator_units": history_price.denominator,
            },
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
        "quality_rule_version": QUALITY_RULE_VERSION,
        "canonical_market_id": canonical_market,
        "cutoff_ms": cutoff_ms,
        "max_age_ms": max_age_ms,
        "items": out,
    }
    result["view_id"] = history_worker.digest(canonical(result).encode())
    return result
