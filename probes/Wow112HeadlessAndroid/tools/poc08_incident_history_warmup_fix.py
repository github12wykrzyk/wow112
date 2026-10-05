from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc08_incident_history_warmup_fix.py GENERATED_F2_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

old_guard = '''            if raw_lowest == 0 || reference_price == 0 || safe_price == 0 || listing_count == 0 || unit_count == 0 || confidence < 2 { continue; }
            staged.push((item_id, unix_s, safe_price));'''
new_guard = '''            if raw_lowest == 0 || reference_price == 0 || listing_count == 0 || unit_count == 0 || confidence < 2 { continue; }
            // V2 history deliberately separates observation from decision.
            // A checksummed, complete market snapshot may warm the historical
            // reference even while LIVE DE remains fail-closed with safe_price=0.
            staged.push((item_id, unix_s, reference_price));'''

if s.count(old_guard) != 1:
    raise SystemExit(f'POC08 history warmup marker mismatch count={s.count(old_guard)}')
s = s.replace(old_guard, new_guard, 1)

for marker in [
    'staged.push((item_id, unix_s, reference_price));',
    'observation from decision',
    'reference even while LIVE DE remains fail-closed',
]:
    if marker not in s:
        raise SystemExit('POC08 history warmup required marker missing: ' + marker)

p.write_text(s, encoding='utf-8')
print('[POC08-HISTORY-WARMUP] PASS raw-reference-observation can warm history while safe price stays blocked')
