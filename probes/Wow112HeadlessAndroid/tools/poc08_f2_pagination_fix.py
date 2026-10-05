from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
old_state='''        let mut total_seen = 0u32;
        let mut truncated = false;

        loop {'''
new_state='''        let mut total_seen = 0u32;
        let mut expected_total: Option<u32> = None;
        let mut truncated = false;

        loop {'''
if s.count(old_state)!=1:
    raise SystemExit('pagination state marker mismatch')
s=s.replace(old_state,new_state,1)
old='''            total_seen = total;
            for record in records.iter().copied() {'''
new='''            total_seen = total;
            if let Some(previous_total) = expected_total {
                if previous_total != total {
                    truncated = true;
                    break;
                }
            } else {
                expected_total = Some(total);
            }
            for record in records.iter().copied() {'''
if s.count(old)!=1:
    raise SystemExit('pagination total marker mismatch')
s=s.replace(old,new,1)
old='''            let list_from = page.saturating_mul(50);
            let done = total == 0 || records.is_empty()
                || list_from.saturating_add(records.len() as u32) >= total;
            if done { break; }
            if page + 1 >= max_pages {
                truncated = true;
                break;
            }
            page = page.saturating_add(1);'''
new='''            let list_from = page.saturating_mul(50);
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
if s.count(old)!=1:
    raise SystemExit('pagination completion marker mismatch')
s=s.replace(old,new,1)
for marker in ['expected_total: Option<u32>','previous_total != total','records.len() < 50','if list_from < total { truncated = true; }']:
    if marker not in s:
        raise SystemExit('pagination safety marker missing: '+marker)
p.write_text(s,encoding='utf-8')
print('[F2-PAGINATION-FIX] PASS')
