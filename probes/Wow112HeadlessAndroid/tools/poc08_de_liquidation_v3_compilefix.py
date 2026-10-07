from pathlib import Path
import subprocess
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

# V3.2 FAST is deliberately chained here so the existing V3.1 workflow remains the
# canonical build/publish lane. It runs before the V3.1 F0 patch; final compilation
# occurs only after V3.1 adds the liquidation-decision helper referenced by V3.2 logging.
v32=Path(__file__).with_name('poc08_de_fast_prefilter_v32_patch.py')
subprocess.run([sys.executable, str(v32), str(p)], check=True)
print('[POC08-DE-LIQUIDATION-V3-COMPILEFIX] V3.2 FAST CHAIN PASS')
