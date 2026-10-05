from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
old='''        if raw_lowest > 0 { raw_prices.insert(material_id, raw_lowest); }
        if safe_price > 0 { safe_prices.insert(material_id, safe_price); }
        let final_conf = if truncated { 0u8 } else { effective_conf };
        if truncated { safe_price = 0; }
        confidence.insert(material_id, final_conf);
'''
new='''        let final_conf = if truncated { 0u8 } else { effective_conf };
        if truncated { safe_price = 0; }
        if raw_lowest > 0 { raw_prices.insert(material_id, raw_lowest); }
        if safe_price > 0 { safe_prices.insert(material_id, safe_price); }
        confidence.insert(material_id, final_conf);
'''
if s.count(old)!=1:
    raise SystemExit('order-fix marker mismatch')
s=s.replace(old,new,1)
if s.index('if truncated { safe_price = 0; }') >= s.index('if safe_price > 0 { safe_prices.insert(material_id, safe_price); }'):
    raise SystemExit('unsafe order remains')
p.write_text(s,encoding='utf-8')
print('[F2-ORDER-FIX] PASS')
