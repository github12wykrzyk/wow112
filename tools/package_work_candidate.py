#!/usr/bin/env python3
import argparse, base64, hashlib, json, lzma, shutil, subprocess, sys, tempfile, zipfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
STEALTH='WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll'
SOURCE='src/StealthCDGuardian/WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c'
POSITIONAL='WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll'

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def dec64(s):
    s=''.join(s.split()); s+='='*((-len(s))%4); return base64.b64decode(s,validate=True)
def xzparts(pattern):
    parts=sorted(ROOT.glob(pattern));
    if not parts: raise RuntimeError('missing '+pattern)
    texts=[p.read_text(encoding='ascii') for p in parts]
    errs=[]
    for label,fn in (
        ('joined',lambda:lzma.decompress(dec64(''.join(texts)))),
        ('chunks',lambda:lzma.decompress(b''.join(dec64(x) for x in texts))),
    ):
        try:return fn()
        except Exception as e:errs.append(f'{label}:{e}')
    raise RuntimeError(pattern+' '+' | '.join(errs))
def xzone(rel): return lzma.decompress(dec64((ROOT/rel).read_text(encoding='ascii')))
def patch(script,src,dst): subprocess.run([sys.executable,str(ROOT/script),str(src),str(dst)],cwd=ROOT,check=True)
def zipdet(out,files):
    Path(out).parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for p in files:
            i=zipfile.ZipInfo(Path(p).name,date_time=(1980,1,1,0,0,0)); i.compress_type=zipfile.ZIP_DEFLATED; i.external_attr=0o100644<<16
            z.writestr(i,Path(p).read_bytes(),compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--candidate-dll',required=True); ap.add_argument('--output',required=True); ap.add_argument('--metadata',required=True); a=ap.parse_args()
    runtime=json.loads((ROOT/'runtime/current.json').read_text(encoding='utf-8')); current=json.loads((ROOT/'CURRENT.json').read_text(encoding='utf-8'))
    items=runtime['active_dlls']; expected={x['name']:x['sha256'].lower() for x in items}; names=[x['name'] for x in items]
    cand=Path(a.candidate_dll).resolve()
    if sha(cand)!=expected[STEALTH]: raise SystemExit(f'candidate hash mismatch {sha(cand)} != {expected[STEALTH]}')
    sources={}
    with tempfile.TemporaryDirectory(prefix='wow112-work-') as td:
        s=Path(td)
        pos=s/POSITIONAL
        subprocess.run([sys.executable,str(ROOT/'tools/recover_positional_from_v68.py'),'--output',str(pos),'--sha256',expected[POSITIONAL]],cwd=ROOT,check=True)
        sources[POSITIONAL]='verified V68 TAR-prefix recovery'
        direct={
          'WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll':xzparts('artifacts/V67/runtime/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll.xz.b64.part*'),
          'PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll':xzone('artifacts/V67/runtime/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll.xz.b64'),
          'MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll':xzparts('artifacts/V68/runtime/MovementCore_V68.dll.xz.b64.part*'),
          'WoWPlayerESP_v1_2_range_sweep.dll':lzma.decompress((ROOT/'artifacts/V67/runtime/WoWPlayerESP_v1_2_range_sweep.dll.xz').read_bytes()),
        }
        for n,b in direct.items():(s/n).write_bytes(b);sources[n]='canonical runtime artifact'
        v13=s/'WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll'; v13.write_bytes(xzparts('artifacts/V67/runtime/WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll.xz.b64.part*'))
        auto='WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll'; patch('artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py',v13,s/auto); v13.unlink(); sources[auto]='v0.13 + deterministic reproducer'
        v09=s/'WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll'; v09.write_bytes(xzparts('artifacts/V67/runtime/WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll.xz.b64.part*'))
        lng='WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll'; patch('artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py',v09,s/lng); v09.unlink(); sources[lng]='v0.9 + deterministic reproducer'
        shutil.copy2(cand,s/STEALTH); sources[STEALTH]='fresh deterministic x86 build'
        for n in names:
            p=s/n
            if not p.is_file(): raise SystemExit('missing '+n)
            got=sha(p)
            if got!=expected[n]: raise SystemExit(f'{n} hash {got} != {expected[n]}')
        exe=runtime['exe']['name']; shutil.copy2(ROOT/current['exe']['path'],s/exe)
        if sha(s/exe)!=runtime['exe']['sha256'].lower(): raise SystemExit('EXE hash mismatch')
        zipdet(Path(a.output).resolve(),[s/exe]+[s/n for n in names])
    out=Path(a.output).resolve(); src=ROOT/SOURCE
    meta={'candidate_dll':STEALTH,'candidate_sha256':sha(cand),'candidate_size':cand.stat().st_size,'source_path':SOURCE,'source_sha256':sha(src),'source_size':src.stat().st_size,'package':out.name,'package_sha256':sha(out),'package_size':out.stat().st_size,'active_dll_count':len(names),'exe':runtime['exe']['name'],'recovery_sources':sources}
    mp=Path(a.metadata).resolve(); mp.parent.mkdir(parents=True,exist_ok=True); mp.write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8'); print(json.dumps(meta,indent=2))
if __name__=='__main__': main()
