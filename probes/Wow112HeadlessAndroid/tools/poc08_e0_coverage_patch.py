from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_e0_coverage_patch.py INPUT_D OUTPUT_E0')

src = Path(sys.argv[1]).read_text(encoding='utf-8')


def replace_once(label: str, old: str, new: str) -> None:
    global src
    count = src.count(old)
    if count != 1:
        raise SystemExit(f'POC08-E0 {label} marker count expected=1 actual={count}')
    src = src.replace(old, new, 1)


replace_once(
    'candidate provenance fields',
    '    disenchant_id: u32,\n    heuristic_de_ev: u32,\n',
    '    disenchant_id: u32,\n    deid_status: &\'static str,\n    deid_source: &\'static str,\n    heuristic_de_ev: u32,\n',
)

replace_once(
    'decision provenance locals',
    '        let exact_de = poc08_exact_disenchant_id(record.item_id);\n        let disenchant_id = exact_de.unwrap_or(0);\n',
    '''        let exact_de = poc08_exact_disenchant_id(record.item_id);\n        let disenchant_id = exact_de.unwrap_or(0);\n        let deid_status = match exact_de {\n            Some(0) => "ZERO",\n            Some(_) => "POSITIVE",\n            None => "UNKNOWN",\n        };\n        let deid_source = poc08_exact_disenchant_source(record.item_id).unwrap_or("Unknown");\n''',
)

replace_once(
    'candidate init provenance',
    '                disenchant_id,\n                heuristic_de_ev,\n',
    '                disenchant_id,\n                deid_status,\n                deid_source,\n                heuristic_de_ev,\n',
)

replace_once(
    'candidate csv header',
    'vendor_unit,vendor_profit,disenchant_id,heuristic_de_ev',
    'vendor_unit,vendor_profit,disenchant_id,deid_status,deid_source,heuristic_de_ev',
)

replace_once(
    'candidate csv format',
    '            "{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",',
    '            "{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",',
)

replace_once(
    'candidate csv values',
    '            c.record.owner_guid,\n            c.vendor_unit,\n            c.vendor_profit,\n            c.disenchant_id,\n            c.heuristic_de_ev,\n',
    '            c.record.owner_guid,\n            c.vendor_unit,\n            c.vendor_profit,\n            c.disenchant_id,\n            c.deid_status,\n            c.deid_source,\n            c.heuristic_de_ev,\n',
)

replace_once(
    'rejected csv header',
    'vendor_unit,vendor_profit,disenchant_id,reference_de_ev,de_profit,reason\\n',
    'vendor_unit,vendor_profit,disenchant_id,deid_status,deid_source,reference_de_ev,safe_de_ev,de_profit,de_roi_bps,de_ploss_bps,de_risk_pass,reason\\n',
)

replace_once(
    'rejected csv format',
    '                "{},{},{},{},{},{},{},{},{},{},{},{}",',
    '                "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",',
)

replace_once(
    'rejected csv values',
    '                disenchant_id,\n                reference_de_ev,\n                de_profit,\n                reason,\n',
    '                disenchant_id,\n                deid_status,\n                deid_source,\n                reference_de_ev,\n                safe_de_ev,\n                de_profit,\n                de_roi_bps,\n                de_ploss_bps,\n                de_risk_pass,\n                reason,\n',
)

replace_once(
    'candidate log format',
    'deid={} heuristic_ev={}',
    'deid={} deid_status={} deid_source={} heuristic_ev={}',
)

replace_once(
    'candidate log args',
    '            c.vendor_profit,\n            c.disenchant_id,\n            c.heuristic_de_ev,\n',
    '            c.vendor_profit,\n            c.disenchant_id,\n            c.deid_status,\n            c.deid_source,\n            c.heuristic_de_ev,\n',
)

# Add unique-item provenance coverage next to the existing reference summary.
needle = '''    println!(\n        "[POC08-B-REFERENCE] PASS items={} deid_positive={} deid_zero={} deid_unknown={} ref_priced={} ref_model_missing={} ref_price_missing={} heuristic_reference_diff={} provenance=REFERENCE_CLASSIC_NOT_OCTO_VERIFIED",\n        item_ids.len(), ref_deid_positive, ref_deid_zero, ref_deid_unknown,\n        reference_de_values.len(), ref_model_missing, ref_price_missing,\n        heuristic_reference_diff\n    );\n'''
if needle not in src:
    raise SystemExit('POC08-E0 reference summary marker not found')
insert = needle + '''\n    let mut src_octowow = 0usize;\n    let mut src_capydb = 0usize;\n    let mut src_seed = 0usize;\n    let mut src_other = 0usize;\n    for item_id in item_ids.iter().copied() {\n        match poc08_exact_disenchant_source(item_id) {\n            Some("OctoWow") => src_octowow += 1,\n            Some("CapyDB") => src_capydb += 1,\n            Some("SeedLegacy") => src_seed += 1,\n            Some(_) => src_other += 1,\n            None => {}\n        }\n    }\n    println!(\n        "[POC08-E0-COVERAGE] PASS items={} positive={} zero={} unknown={} source_octowow={} source_capydb={} source_seed={} source_other={} cache_entries={}",\n        item_ids.len(), ref_deid_positive, ref_deid_zero, ref_deid_unknown,\n        src_octowow, src_capydb, src_seed, src_other, POC08_DE_CACHE_ENTRIES\n    );\n'''
src = src.replace(needle, insert, 1)

# E0 remains hard read-only.
replace_once(
    'mode banner',
    '[POC08-D] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=REFERENCE_CLASSIC_COMPARE mutation=DISABLED',
    '[POC08-E0] COVERAGE AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME provenance=TRACKED mutation=DISABLED',
)

Path(sys.argv[2]).write_text(src, encoding='utf-8', newline='\n')
print('[POC08-E0-PATCH] PASS provenance+unknown-safe audit export mutation=DISABLED')
