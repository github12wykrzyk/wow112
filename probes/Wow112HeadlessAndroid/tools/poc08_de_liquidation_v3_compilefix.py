from pathlib import Path
import sys
if len(sys.argv)!=2: raise SystemExit('usage: UNIFIED_RS')
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

def rep(a,b,label):
    global s
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label}: expected 1 got {n}')
    s=s.replace(a,b,1)

rep('let absolute = if external_units>=500{8_500}else if external_units>=250{9_000}else if external_units>=100{9_500}else if external_units>=50{9_750}else{10_000};',
    'let absolute:u32 = if external_units>=500{8_500}else if external_units>=250{9_000}else if external_units>=100{9_500}else if external_units>=50{9_750}else{10_000};','absolute type')
rep('let clustered=if depth_share>=8_000{9_000}else if depth_share>=6_000{9_500}else if depth_share>=3_000{9_750}else{10_000};',
    'let clustered:u32=if depth_share>=8_000{9_000}else if depth_share>=6_000{9_500}else if depth_share>=3_000{9_750}else{10_000};','clustered type')
rep('''        if safe_price>0{\n            safe_price=(u64::from(safe_price).saturating_mul(u64::from(exposure_factor_bps))/10_000)\n                .saturating_mul(u64::from(saturation_factor_bps))/10_000;\n            safe_price=safe_price.min(u64::from(u32::MAX)) as u32;\n        }''',
'''        if safe_price>0{\n            let adjusted=(u64::from(safe_price).saturating_mul(u64::from(exposure_factor_bps))/10_000)\n                .saturating_mul(u64::from(saturation_factor_bps))/10_000;\n            safe_price=adjusted.min(u64::from(u32::MAX)) as u32;\n        }''','adjusted cast')

p.write_text(s,encoding='utf-8')
print('[POC08-DE-LIQUIDATION-V3-COMPILEFIX] PASS')
