from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
old='''    for line in text.lines().skip(1) {
        let cols = line.split(',').collect::<Vec<_>>();
        if cols.len() < 3 { continue; }
        let Ok(item_id) = cols[1].trim().parse::<u32>() else { continue; };
        let Ok(price) = cols[2].trim().parse::<u32>() else { continue; };
        if item_id == 0 || price == 0 { continue; }
        let values = out.entry(item_id).or_default();
        values.push(price);
'''
new='''    for line in text.lines().skip(1) {
        let cols = line.split(',').collect::<Vec<_>>();
        if cols.len() < 7 { continue; }
        let Ok(item_id) = cols[1].trim().parse::<u32>() else { continue; };
        let Ok(safe_price) = cols[5].trim().parse::<u32>() else { continue; };
        let conf = cols[6].trim();
        if item_id == 0 || safe_price == 0 || !matches!(conf, "MEDIUM" | "HIGH") { continue; }
        let values = out.entry(item_id).or_default();
        values.push(safe_price);
'''
if s.count(old)!=1:
    raise SystemExit('history-fix marker mismatch')
s=s.replace(old,new,1)
for marker in ['cols.len() < 7','safe_price = cols[5]','matches!(conf, "MEDIUM" | "HIGH")','values.push(safe_price)']:
    if marker not in s:
        raise SystemExit('history-fix missing marker: '+marker)
p.write_text(s,encoding='utf-8')
print('[F2-HISTORY-FIX] PASS')
