from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc08_f2_capy_agreement_patch.py GENERATED_F2')

p = Path(sys.argv[1])
src = p.read_text(encoding='utf-8')
old = '                    && poc08_de_source_confidence(c.record.item_id) >= 2\n                    && c.de_risk_pass'
new = '                    && (poc08_de_source_confidence(c.record.item_id) >= 2 || (poc08_de_source(c.record.item_id) == Some("CapyDB") && poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) == 0))\n                    && c.de_risk_pass'
if src.count(old) != 1:
    raise SystemExit(f'Capy agreement gate marker expected=1 actual={src.count(old)}')
src = src.replace(old, new, 1)
marker = 'poc08_de_source(c.record.item_id) == Some("CapyDB") && poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) == 0'
if marker not in src:
    raise SystemExit('Capy exact-agreement marker missing after patch')
p.write_text(src, encoding='utf-8')
print('[POC08-F2-CAPY-CROSSCHECK] PASS capy_requires_reference_agreement_bps=0 legacy_still_blocked=YES')
