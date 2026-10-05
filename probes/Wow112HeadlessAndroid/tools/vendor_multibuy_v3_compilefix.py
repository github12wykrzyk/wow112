from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: vendor_multibuy_v3_compilefix.py V3_SOURCE')

p = Path(sys.argv[1])
src = p.read_text(encoding='utf-8')

# V3 audit patch intentionally changes the turbo valuation accounting, but its first
# declaration replacement can hit the older sequential helper. Restore that helper.
wrong_decl = '''    let mut zero_vendor = 0usize;\n    let mut missing_template = 0usize;\n    let mut zero_vendor_ids = Vec::<u32>::new();\n    let mut missing_template_ids = Vec::<u32>::new();\n'''
if wrong_decl not in src:
    raise SystemExit('compilefix: sequential wrong declaration not found')
src = src.replace(wrong_decl, '    let mut zero_or_missing = 0usize;\n', 1)

# Add the split counters to the actual turbo valuation function only.
turbo_start = src.index('fn poc07_fill_live_vendor_values_turbo(')
turbo_end = src.index('pub fn login_poc07_vendorlive_multibuy_v3(', turbo_start)
prefix = src[:turbo_start]
turbo = src[turbo_start:turbo_end]
suffix = src[turbo_end:]
old = '    let mut zero_or_missing = 0usize;\n'
new = '''    let mut zero_vendor = 0usize;\n    let mut missing_template = 0usize;\n    let mut zero_vendor_ids = Vec::<u32>::new();\n    let mut missing_template_ids = Vec::<u32>::new();\n'''
if old not in turbo:
    raise SystemExit('compilefix: turbo zero_or_missing declaration not found')
turbo = turbo.replace(old, new, 1)

out = prefix + turbo + suffix
# Sanity markers: sequential helper still has legacy counter, turbo has split accounting.
if 'zero_or_missing += 1;' not in out:
    raise SystemExit('compilefix: sequential counter sanity failed')
if '[POC07-AUDIT] VALUATION coverage=' not in out:
    raise SystemExit('compilefix: V3 audit valuation marker missing')
if 'let mut zero_vendor_ids = Vec::<u32>::new();' not in turbo:
    raise SystemExit('compilefix: turbo split declarations missing')

p.write_text(out, encoding='utf-8')
