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
branch_lines=[line for line in info.splitlines() if line.startswith('BRANCH=')]
assert len(branch_lines)==1,'exactly one BRANCH marker required'
build_branch=branch_lines[0].split('=',1)[1]
allowed_branches={
    'feature/ah-auction-lifecycle-v1',
    'feature/ah-auction-lifecycle-v2-baseline-fasttrack',
}
assert build_branch in allowed_branches,f'unexpected lifecycle build branch: {build_branch}'
assert hashlib.sha256(data).hexdigest() in info
for name in ('coordinator.rs','adapter.rs','auto_v2.rs','inventory_baseline.rs','world_poc08_unified.rs'):
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

# Temporary live diagnostic wrapper: it only pins the mailbox GUID that previously
# worked on the target server and delegates the single mutation to the same canary.
# It contains no retry loop and does not bypass MutationCoordinatorV1.
settle_src=Path('src/AuctionLifecycle/RUN_SETTLE_ONE_PROVEN_MAILBOX.ps1')
assert settle_src.is_file(),'proven-mailbox settle canary missing'
settle=settle_src.read_text(encoding='utf-8')
assert '0xF11002A4A5002A0C' in settle,'expected proven mailbox default missing'
assert 'SettleOne' in settle and 'LIFECYCLE_CANARY_ONCE' in settle
assert 'Start-Sleep' not in settle,'settle wrapper must not retry'
shutil.copy2(settle_src,root/'RUN_SETTLE_ONE_PROVEN_MAILBOX.ps1')

# AUTO V2 baseline-fix launcher: one EXE invocation, explicit AUTO2 arm, no retry loop.
for name in ('START_AUTO_V2_BASELINE_FIX.ps1','START_AUTO_V2_BASELINE_FIX.bat'):
    src=Path('src/AuctionLifecycle')/name
    assert src.is_file(),name
    txt=src.read_text(encoding='utf-8')
    if name.endswith('.ps1'):
        assert txt.count('& $Exe')==1 and 'Start-Sleep' not in txt and "-cne 'AUTO2'" in txt
        assert "WOW112_LIFECYCLE_AUTO_FLOORS='10998:4000'" in txt and "WOW112_LIFECYCLE_AUTO_LIMIT='2'" in txt
        assert "WOW112_AH_HELLO_TIMEOUT_SECS='120'" in txt
    shutil.copy2(src,root/name)

files={str(p.relative_to(root)).replace('\\','/'):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file() and p.name!='LIFECYCLE_PACKAGE.json'}
manifest={'branch':build_branch,'commit':sha,'base_commit':'99d0a45b1b62a98214f927f960156ba313de252b','platform':'windows-x86','files':files,'live_validation':'NOT_RUN','local_mutation_runner':'SAME_HOST_SINGLE_INVOCATION_NO_RETRY','final_package':'PASS'}
(root/'LIFECYCLE_PACKAGE.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'FINAL_PACKAGE: PASS (headless Lifecycle AUTO V2 Windows x86; branch={build_branch}; same-host single invocation)')
