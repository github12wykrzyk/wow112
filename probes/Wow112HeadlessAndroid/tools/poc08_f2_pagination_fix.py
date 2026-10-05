from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

old_state = '''        let mut total_seen = 0u32;
        let mut truncated = false;

        loop {'''
new_state = '''        let mut total_seen = 0u32;
        let mut expected_total: Option<u32> = None;
        let mut truncated = false;

        loop {'''
if s.count(old_state) != 1:
    raise SystemExit(f'pagination state marker mismatch count={s.count(old_state)}')
s = s.replace(old_state, new_state, 1)

# Be resilient to nearby hardening patches: insert the total-stability gate directly
# after the unique total_seen assignment instead of matching the following loop body.
pattern = r'(?m)^(\s*)total_seen = total;\s*$'
matches = list(re.finditer(pattern, s))
if len(matches) != 1:
    raise SystemExit(f'pagination total marker mismatch count={len(matches)}')
indent = matches[0].group(1)
replacement = (
    f'{indent}total_seen = total;\n'
    f'{indent}if let Some(previous_total) = expected_total {{\n'
    f'{indent}    if previous_total != total {{\n'
    f'{indent}        truncated = true;\n'
    f'{indent}        break;\n'
    f'{indent}    }}\n'
    f'{indent}}} else {{\n'
    f'{indent}    expected_total = Some(total);\n'
    f'{indent}}}'
)
s = s[:matches[0].start()] + replacement + s[matches[0].end():]

old_completion = '''            let list_from = page.saturating_mul(50);
            let done = total == 0 || records.is_empty()
                || list_from.saturating_add(records.len() as u32) >= total;
            if done { break; }
            if page + 1 >= max_pages {
                truncated = true;
                break;
            }
            page = page.saturating_add(1);'''
new_completion = '''            let list_from = page.saturating_mul(50);
            let observed_end = list_from.saturating_add(records.len() as u32);
            if total == 0 { break; }
            if records.is_empty() {
                if list_from < total { truncated = true; }
                break;
            }
            if observed_end >= total { break; }
            if records.len() < 50 {
                truncated = true;
                break;
            }
            if page + 1 >= max_pages {
                truncated = true;
                break;
            }
            page = page.saturating_add(1);'''
if s.count(old_completion) != 1:
    raise SystemExit(f'pagination completion marker mismatch count={s.count(old_completion)}')
s = s.replace(old_completion, new_completion, 1)

for marker in [
    'expected_total: Option<u32>',
    'previous_total != total',
    'records.len() < 50',
    'if list_from < total { truncated = true; }',
]:
    if marker not in s:
        raise SystemExit('pagination safety marker missing: ' + marker)

p.write_text(s, encoding='utf-8')
print('[F2-PAGINATION-FIX] PASS')
