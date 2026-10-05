from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

fn_start = s.find('fn poc08_collect_material_pricebook(')
fn_end = s.find('fn poc08_safe_ev_from_outcomes(', fn_start)
if fn_start < 0 or fn_end < 0:
    raise SystemExit('pagination pricebook function bounds not found')

prefix = s[:fn_start]
block = s[fn_start:fn_end]
suffix = s[fn_end:]

old_state = '''        let mut total_seen = 0u32;
        let mut truncated = false;

        loop {'''
new_state = '''        let mut total_seen = 0u32;
        let mut expected_total: Option<u32> = None;
        let mut truncated = false;

        loop {'''
if block.count(old_state) != 1:
    raise SystemExit(f'pagination state marker mismatch in pricebook count={block.count(old_state)}')
block = block.replace(old_state, new_state, 1)

old_total = '''            total_seen = total;
            for record in records.iter().copied() {'''
new_total = '''            total_seen = total;
            if let Some(previous_total) = expected_total {
                if previous_total != total {
                    truncated = true;
                    break;
                }
            } else {
                expected_total = Some(total);
            }
            for record in records.iter().copied() {'''
if block.count(old_total) != 1:
    raise SystemExit(f'pagination total marker mismatch in pricebook count={block.count(old_total)}')
block = block.replace(old_total, new_total, 1)

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
if block.count(old_completion) != 1:
    raise SystemExit(f'pagination completion marker mismatch in pricebook count={block.count(old_completion)}')
block = block.replace(old_completion, new_completion, 1)

for marker in [
    'expected_total: Option<u32>',
    'previous_total != total',
    'records.len() < 50',
    'if list_from < total { truncated = true; }',
]:
    if marker not in block:
        raise SystemExit('pagination safety marker missing in pricebook: ' + marker)

p.write_text(prefix + block + suffix, encoding='utf-8')
print('[F2-PAGINATION-FIX] PASS scoped=pricebook')
