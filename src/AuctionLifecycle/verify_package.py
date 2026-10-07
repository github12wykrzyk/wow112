"""Headless product gate (injected-game DLL package validator does not apply)."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

root=Path(sys.argv[1]);sha=sys.argv[2]
assert re.fullmatch('[0-9a-f]{40}',sha), 'invalid exact commit'
exes=list(root.glob('*.exe'));assert len(exes)==1,'one root EXE required'
p=exes[0];data=p.read_bytes();assert data[:2]==b'MZ'
pe=struct.unpack_from('<I',data,0x3c)[0];assert data[pe:pe+4]==b'PE\0\0'
assert struct.unpack_from('<H',data,pe+4)[0]==0x14c,'x86 required'
assert struct.unpack_from('<H',data,pe+24)[0]==0x10b,'PE32 required'
assert struct.unpack_from('<I',data,pe+40)[0]>0,'entrypoint required'
info=(root/'BUILD_INFO.txt').read_text(encoding='utf-8-sig')
assert f'EXACT_SHA={sha}' in info
assert 'BRANCH=feature/ah-auction-lifecycle-v1' in info
assert hashlib.sha256(data).hexdigest() in info
for name in ('coordinator.rs','adapter.rs','world_poc08_unified.rs'):
    assert (root/'source'/name).is_file(),name
assert (root/'LIFECYCLE_README.md').is_file()
files={str(p.relative_to(root)).replace('\\','/'):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file() and p.name!='LIFECYCLE_PACKAGE.json'}
manifest={'branch':'feature/ah-auction-lifecycle-v1','commit':sha,'base_commit':'99d0a45b1b62a98214f927f960156ba313de252b','platform':'windows-x86','files':files,'live_validation':'NOT_RUN','final_package':'PASS'}
(root/'LIFECYCLE_PACKAGE.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('FINAL_PACKAGE: PASS (headless Lifecycle V1 Windows x86)')
