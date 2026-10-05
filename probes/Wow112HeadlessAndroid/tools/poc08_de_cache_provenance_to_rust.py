from __future__ import annotations

import argparse
import csv
from pathlib import Path


def source_variant(raw: str) -> str:
    value = (raw or '').strip()
    if value == 'OctoWow':
        return 'OctoWow'
    if value == 'CapyDB':
        return 'CapyDB'
    if value == 'LEGACY_SEED':
        return 'LegacySeed'
    return 'Unknown'


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache-csv', required=True)
    ap.add_argument('--output-rs', required=True)
    args = ap.parse_args()

    rows: dict[int, tuple[int, str]] = {}
    with Path(args.cache_csv).open('r', encoding='utf-8-sig', newline='') as f:
        for row in csv.DictReader(f):
            item_id = int(row['item_id'])
            deid = int(row['disenchant_id'])
            source = source_variant(row.get('source', ''))
            if item_id <= 0 or deid < 0:
                raise SystemExit(f'invalid cache values item_id={item_id} deid={deid}')
            previous = rows.get(item_id)
            current = (deid, source)
            if previous is not None and previous != current:
                raise SystemExit(f'conflicting cache row item_id={item_id}: {previous} vs {current}')
            rows[item_id] = current

    for blocked in (20406, 20407, 20408):
        if rows.get(blocked, (-1, ''))[0] != 0:
            raise SystemExit(f'expected regression item {blocked} to have DisenchantID=0')
    if rows.get(41316, (0, ''))[0] <= 0:
        raise SystemExit('expected known-positive item 41316 to have DisenchantID>0')

    out = Path(args.output_rs)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open('w', encoding='utf-8', newline='\n') as f:
        f.write('// AUTO-GENERATED provenance-aware POC08 DE cache. DO NOT EDIT.\n')
        f.write('#[derive(Debug, Clone, Copy, PartialEq, Eq)]\n')
        f.write('enum Poc08DeIdSource { OctoWow, CapyDB, LegacySeed, Unknown }\n\n')
        f.write('fn poc08_exact_disenchant_id(item_id: u32) -> Option<u32> {\n')
        f.write('    match item_id {\n')
        for item_id in sorted(rows):
            f.write(f'        {item_id} => Some({rows[item_id][0]}),\n')
        f.write('        _ => None,\n')
        f.write('    }\n}\n\n')
        f.write('fn poc08_deid_source(item_id: u32) -> Poc08DeIdSource {\n')
        f.write('    match item_id {\n')
        for item_id in sorted(rows):
            f.write(f'        {item_id} => Poc08DeIdSource::{rows[item_id][1]},\n')
        f.write('        _ => Poc08DeIdSource::Unknown,\n')
        f.write('    }\n}\n\n')
        f.write(f'const POC08_DE_CACHE_ENTRIES: usize = {len(rows)};\n')

    counts = {'OctoWow': 0, 'CapyDB': 0, 'LegacySeed': 0, 'Unknown': 0}
    positive = zero = 0
    for deid, source in rows.values():
        counts[source] += 1
        if deid > 0:
            positive += 1
        else:
            zero += 1
    print(f'[POC08-DE-CACHE-PROVENANCE] PASS entries={len(rows)} positive={positive} zero={zero} sources={counts}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
