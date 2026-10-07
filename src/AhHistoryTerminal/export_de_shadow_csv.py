#!/usr/bin/env python3
"""Export a DE-material-only shadow price projection from canonical AH history.

The output is intentionally read-only input for POC08 shadow comparison. It does
not authorize or alter BUY decisions.
"""
import argparse
import csv
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import history_quality_v2 as history

DE_MATERIAL_IDS = {
    10938, 10939, 10940, 10978, 10998, 11082, 11083, 11084,
    11134, 11135, 11137, 11138, 11139, 11174, 11175, 11176,
    11177, 11178, 14343, 14344, 16202, 16203, 16204, 20725,
}


def export_shadow(db_path, market, output_path, cutoff_ms):
    db = history.connect(db_path)
    try:
        view = history.de_material_view(db, market, cutoff_ms, now_ms=cutoff_ms)
        prices = history.shadow_price_map(view)
    finally:
        db.close()
    rows = [(item_id, prices[item_id]) for item_id in sorted(prices) if item_id in DE_MATERIAL_IDS]
    output = pathlib.Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_suffix(output.suffix + '.partial')
    with temp.open('w', newline='', encoding='utf-8') as handle:
        writer = csv.writer(handle, lineterminator='\n')
        writer.writerow(['item_id', 'unit_copper', 'view_id', 'cutoff_ms', 'ruleset'])
        for item_id, unit_copper in rows:
            writer.writerow([item_id, unit_copper, view['view_id'], cutoff_ms, history.RULESET])
        handle.flush()
    temp.replace(output)
    return {
        'view_id': view['view_id'],
        'ruleset': history.RULESET,
        'cutoff_ms': cutoff_ms,
        'eligible_scan_count': view['eligible_scan_count'],
        'exported_materials': len(rows),
        'output': str(output),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('db')
    parser.add_argument('market')
    parser.add_argument('output')
    parser.add_argument('--cutoff-ms', type=int, required=True)
    args = parser.parse_args()
    print(history.canonical(export_shadow(args.db, args.market, args.output, args.cutoff_ms)))


if __name__ == '__main__':
    main()
