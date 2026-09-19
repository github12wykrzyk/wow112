#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
EXE=ROOT/"WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe"
OLD_SHA="0a5ecb0023f9ba1dddecb25f4a636a0bcd1706db70583d9db3ad69ba51f9f227"
PATCH=0x35D401
OLD_HEAD=bytes.fromhex("8B 44 24 04 8B D0 83 E2 FC 81 FA F8 06 00 00 75 1A C7 44 24 10 88 13 00 00 81 7C 24 1C 88 13 00 00")
NEW_HEAD=bytes.fromhex("8B 44 24 04 8B D0 83 E2 FE 81 FA 40 07 00 00 75 1A C7 44 24 10 50 34 03 00 81 7C 24 1C 50 34 03 00")
OLD_CAT=bytes.fromhex("C7 44 24 1C 88 13 00 00")
NEW_CAT=bytes.fromhex("C7 44 24 1C 50 34 03 00")

def sha(b): return hashlib.sha256(b).hexdigest()

data=bytearray(EXE.read_bytes())
if sha(data)!=OLD_SHA:
    raise SystemExit(f"unexpected source EXE sha256: {sha(data)}")
if bytes(data[PATCH:PATCH+len(OLD_HEAD)])!=OLD_HEAD:
    raise SystemExit("unexpected hard-cooldown cave head")
data[PATCH:PATCH+len(NEW_HEAD)]=NEW_HEAD
lo=PATCH+len(NEW_HEAD); hi=PATCH+96
p=bytes(data).find(OLD_CAT,lo,hi)
if p<0:
    raise SystemExit("category clamp write not found in expected cave window")
data[p:p+len(NEW_CAT)]=NEW_CAT
new_sha=sha(data)
EXE.write_bytes(data)

for rel in ("CURRENT.json","runtime/current.json"):
    path=ROOT/rel
    obj=json.loads(path.read_text(encoding="utf-8"))
    if rel=="CURRENT.json":
        assert obj["exe"]["sha256"]==OLD_SHA
        obj["exe"]["sha256"]=new_sha
    else:
        assert obj["exe"]["sha256"]==OLD_SHA
        obj["exe"]["sha256"]=new_sha
    path.write_text(json.dumps(obj,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")

m=ROOT/"manifests/SHA256SUMS_WORK.txt"
txt=m.read_text(encoding="utf-8")
if OLD_SHA not in txt: raise SystemExit("old EXE hash absent from work manifest")
m.write_text(txt.replace(OLD_SHA,new_sha,1),encoding="utf-8")

doc=ROOT/"artifacts/StealthCD/VANISH210_HARD_EXE.txt"
doc.write_text(f"""VANISH 3:30 HARD EXE PATCH — WORK CANDIDATE
Target: World of Warcraft 1.12.1 build 5875 x86

Central cooldown insertion hook: 0x006E12C0 -> code cave 0x0075D401.
The existing EXE hard-cooldown selector was repurposed from Stealth ranks
1784..1787 to Vanish ranks 1856..1857:
  (spellId & 0xFFFFFFFE) == 0x00000740

Forced cooldown:
  recovery = 210000 ms
  category recovery = min(category recovery, 210000 ms)

Stealth remains handled by active WoWStealthCDGuardian v2 runtime layer.

Old EXE SHA256:
  {OLD_SHA}
New EXE SHA256:
  {new_sha}
Size:
  {len(data)}

Reproducer:
  python tools/patch_vanish210_exe.py
""",encoding="utf-8")
print(new_sha)
