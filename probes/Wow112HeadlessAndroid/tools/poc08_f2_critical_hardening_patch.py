from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: INPUT_F2 OUTPUT_F2_HARDENED')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

def rep(label: str, old: str, new: str) -> None:
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit(f'POC08-F2-HARDEN {label} expected=1 actual={n}')
    src = src.replace(old, new, 1)

# Critical safety fix: material pages are not guaranteed to be price-sorted.
# If the configured page cap is reached before the complete result set is read,
# do not value that material at all for SAFE EV / P(loss).
rep(
    'pricebook truncate state',
    '        let mut total_seen = 0u32;\n\n        loop {',
    '        let mut total_seen = 0u32;\n        let mut truncated = false;\n\n        loop {',
)

rep(
    'pricebook cap handling',
    '            let done = total == 0 || records.is_empty()\n                || list_from.saturating_add(records.len() as u32) >= total;\n            if done || page + 1 >= max_pages { break; }\n            page = page.saturating_add(1);',
    '            let done = total == 0 || records.is_empty()\n                || list_from.saturating_add(records.len() as u32) >= total;\n            if done { break; }\n            if page + 1 >= max_pages {\n                truncated = true;\n                break;\n            }\n            page = page.saturating_add(1);',
)

rep(
    'pricebook fail closed',
    '        let mut safe_price = if effective_conf >= 2 { raw_lowest } else { 0 };',
    '        let mut safe_price = if effective_conf >= 2 && !truncated { raw_lowest } else { 0 };',
)

rep(
    'pricebook confidence fail closed',
    '        confidence.insert(material_id, effective_conf);\n        points.push(Poc08MaterialBookPoint {',
    '        let final_conf = if truncated { 0u8 } else { effective_conf };\n        if truncated { safe_price = 0; }\n        confidence.insert(material_id, final_conf);\n        points.push(Poc08MaterialBookPoint {',
)

rep(
    'point confidence',
    '            history_median,\n            confidence: effective_conf,\n        });',
    '            history_median,\n            confidence: final_conf,\n        });',
)

rep(
    'diagnostic output',
    '            "[POC08-C-PRICEBOOK] item_id={} name={:?} raw={} safe={} listings={} units={} self_excluded={} total_name_matches={} pages={} history_n={} history_median={} confidence={}",',
    '            "[POC08-C-PRICEBOOK] item_id={} name={:?} raw={} safe={} listings={} units={} self_excluded={} total_name_matches={} pages={} history_n={} history_median={} confidence={} truncated={}",',
)
rep(
    'diagnostic args',
    '            poc08_material_confidence_name(effective_conf)\n        );',
    '            poc08_material_confidence_name(final_conf), truncated\n        );',
)

# F2 pilot provenance hardening: require at least Octo-web confidence (2), not Capy/legacy only.
rep(
    'pilot provenance gate',
    '                    && c.de_risk_pass\n                    && c.safe_de_ev > 0',
    '                    && poc08_de_source_confidence(c.record.item_id) >= 2\n                    && c.de_risk_pass\n                    && c.safe_de_ev > 0',
)

for marker in [
    'let mut truncated = false;',
    'if page + 1 >= max_pages',
    'safe_price = 0;',
    'truncated={}',
    'poc08_de_source_confidence(c.record.item_id) >= 2',
]:
    if marker not in src:
        raise SystemExit(f'POC08-F2-HARDEN missing marker: {marker}')

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-F2-HARDEN] PASS material-book truncation fail-closed + provenance>=2')
