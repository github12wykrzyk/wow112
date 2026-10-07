#!/usr/bin/env python3
import json
import sqlite3
import sys
from collections import Counter
from pathlib import Path

import history_worker as hw
import shadow_history as sh


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: DB LIVE_SUMMARY OUTPUT_JSON')
    db_path = Path(sys.argv[1])
    summary_path = Path(sys.argv[2])
    out_path = Path(sys.argv[3])
    summary = json.loads(summary_path.read_text())
    db = hw.connect(db_path)
    sh.ensure_schema(db)
    try:
        quality_counts = dict(db.execute('SELECT quality,COUNT(*) FROM scans GROUP BY quality').fetchall())
        status_counts = dict(db.execute('SELECT status,COUNT(*) FROM scans GROUP BY status').fetchall())
        scope_counts = dict(db.execute('SELECT scope,COUNT(*) FROM scans GROUP BY scope').fetchall())
        rows = db.execute('SELECT scan_id,market,status,quality,reasons,started_ms,ended_ms,record_count,unique_count FROM scans ORDER BY ended_ms').fetchall()
        reason_counts = Counter()
        for r in rows:
            for reason in json.loads(r[4]):
                reason_counts[reason] += 1
        latest = rows[-1] if rows else None
        market = summary.get('market_namespace')
        # Prefer the actual market string stored in the latest scan.
        market_id = latest[1] if latest else None
        cutoff = (latest[6] + 1) if latest else 0
        view = sh.material_history_view(db, market_id, None, cutoff) if latest else {"items": []}
        result = {
            'schema_version': 1,
            'mode': 'REAL_AH_SHADOW_READ_ONLY',
            'mutation': 'DISABLED',
            'buy_decision_changed': 0,
            'source_commit': summary.get('source_commit'),
            'live_scan': summary.get('live_scan'),
            'scan_id': summary.get('scan_id'),
            'latest_market_id': market_id,
            'market_namespace_label': market,
            'latest_scan': None if latest is None else {
                'scan_id': latest[0], 'market_id': latest[1], 'status': latest[2], 'quality': latest[3],
                'quality_reasons': json.loads(latest[4]), 'started_ms': latest[5], 'ended_ms': latest[6],
                'record_count': latest[7], 'unique_count': latest[8],
            },
            'pagination': summary.get('pagination'),
            'database': {
                'scans': len(rows),
                'observations': db.execute('SELECT COUNT(*) FROM observations').fetchone()[0],
                'quality_counts': quality_counts,
                'status_counts': status_counts,
                'scope_counts': scope_counts,
                'quality_reason_counts': dict(sorted(reason_counts.items())),
                'eligible_full_market_scans': db.execute("SELECT COUNT(*) FROM scans WHERE quality='eligible' AND scope='full_market'").fetchone()[0],
            },
            'point_in_time_history': {
                'cutoff_ms': cutoff,
                'material_view_version': view.get('material_view_version'),
                'view_id': view.get('view_id'),
                'item_count': len(view.get('items', [])),
                'items': view.get('items', [])[:100],
            },
            'live_validation_checks': summary.get('checks', {}),
            'live_quality': summary.get('quality'),
            'live_quality_reasons': summary.get('quality_reasons', []),
            'notes': [
                'History is audit-only and cannot authorize BUY.',
                'Point-in-time view excludes observations after cutoff.',
                'If no eligible full-market scans exist, material history remains empty by design.'
            ],
        }
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        db.close()

if __name__ == '__main__':
    main()
