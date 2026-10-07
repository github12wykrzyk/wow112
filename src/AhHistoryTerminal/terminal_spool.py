#!/usr/bin/env python3
"""Convert Vendor/DE terminal RawAhPageObserved spool rows into canonical history events."""
import json
from pathlib import Path
import shadow_history

SCOPES = {"full_market", "targeted_item", "revalidation_window"}


def read_spool(path):
    out = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        row = json.loads(raw)
        if row.get("event_type") != "RawAhPageObserved" or row.get("capture_scope") not in SCOPES:
            raise ValueError("unsupported spool row")
        if row.get("record_count") != len(row.get("records", [])):
            raise ValueError("record_count mismatch")
        if row.get("listfrom") != row.get("page") * 50:
            raise ValueError("listfrom mismatch")
        out.append(row)
    return out


def identity(row):
    return {k: row[k] for k in ("market_id", "server_id", "realm_id", "ah_pool_id", "market_epoch")}


def split_captures(rows):
    groups, current = [], []
    for row in rows:
        if row["capture_scope"] != "full_market":
            if current:
                groups.append(current); current = []
            groups.append([row]); continue
        new = (not current or row["page"] == 0 or row["page"] != current[-1]["page"] + 1
               or row["session_id"] != current[-1]["session_id"] or identity(row) != identity(current[-1]))
        if new and current:
            groups.append(current); current = []
        current.append(row)
        if row["record_count"] < 50:
            groups.append(current); current = []
    if current:
        groups.append(current)
    return groups


def to_segment(group, ordinal):
    first = group[0]
    scope = first["capture_scope"]
    status = "completed" if scope != "full_market" or group[-1]["record_count"] < 50 else "truncated"
    scan_id = f"terminal-shadow:{first['session_id']}:{scope}:{ordinal:06d}"
    common = dict(schema_version=1, scan_id=scan_id, market_id=first["market_id"],
                  producer_id="vendor-de-terminal-shadow-v1", source="live", scope=scope)
    events = [dict(common, event_id=f"{scan_id}:1", producer_seq=1, event_type="ScanStarted",
                   observed_at_utc_ms=first["observed_at_utc_ms"])]
    for seq, row in enumerate(group, 2):
        records = []
        for idx, rec in enumerate(row["records"]):
            rec = dict(rec); rec["record_index"] = idx; records.append(rec)
        events.append(dict(common, event_id=f"{scan_id}:{seq}", producer_seq=seq,
                           event_type="PageObserved", observed_at_utc_ms=row["observed_at_utc_ms"],
                           page=row["page"], listfrom=row["listfrom"], total=row["total"],
                           record_count=len(records), records=records))
    seq = len(events) + 1
    events.append(dict(common, event_id=f"{scan_id}:{seq}", producer_seq=seq, event_type="ScanFinished",
                       observed_at_utc_ms=group[-1]["observed_at_utc_ms"], status=status, pages=len(group)))
    return events, identity(first)


def import_spool(db, path):
    results = []
    for n, group in enumerate(split_captures(read_spool(path)), 1):
        events, ident = to_segment(group, n)
        results.append(shadow_history.safe_ingest_shared_segment(db, events, ident))
    return results
