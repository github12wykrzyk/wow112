from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc08_b_compile_fix.py GENERATED_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
old = '"{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",'
new = '"{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",'
if old not in s:
    raise SystemExit('POC08-B formatter marker not found')
s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')
print('[POC08-B-FIX] PASS candidate CSV formatter columns=16')
