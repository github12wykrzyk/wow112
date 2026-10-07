"""Headless product gate (injected-game DLL package validator does not apply)."""
import hashlib
import json
from pathlib import Path
import re
import shutil
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

# Ship a same-host runner rather than pretending a GitHub-hosted runner can share
# the character coordinator with a local BUY process. It reuses canonical DPAPI
# profile storage and intentionally invokes the tested EXE exactly once.
canary_src=Path('src/AuctionLifecycle/RUN_LIFECYCLE_LOCAL_CANARY.ps1')
assert canary_src.is_file(),'local canary runner missing'
canary=canary_src.read_text(encoding='utf-8')
assert 'LOCAL_CANARY_SINGLE_INVOCATION=YES' in canary
assert canary.count('& $Exe')==1,'canary must invoke lifecycle EXE exactly once'
assert 'Start-Sleep' not in canary,'canary must not contain retry delay'
assert 'LIFECYCLE_CANARY_ONCE' in canary,'mutation arm missing'
assert "WOW112_LIFECYCLE_MAIL_LIMIT='1'" in canary,'mail canary must be bounded to one action'
assert 'Existing same-host coordinator lock/pending state is authoritative' in canary
shutil.copy2(canary_src,root/'RUN_LIFECYCLE_LOCAL_CANARY.ps1')

files={str(p.relative_to(root)).replace('\\','/'):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file() and p.name!='LIFECYCLE_PACKAGE.json'}
manifest={'branch':'feature/ah-auction-lifecycle-v1','commit':sha,'base_commit':'99d0a45b1b62a98214f927f960156ba313de252b','platform':'windows-x86','files':files,'live_validation':'NOT_RUN','local_mutation_runner':'SAME_HOST_SINGLE_INVOCATION_NO_RETRY','final_package':'PASS'}
(root/'LIFECYCLE_PACKAGE.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('FINAL_PACKAGE: PASS (headless Lifecycle V1 Windows x86 + same-host canary)')
