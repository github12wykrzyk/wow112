#!/usr/bin/env python3
import argparse, base64, hashlib, lzma, pathlib, re, subprocess, sys

ROOT=pathlib.Path(__file__).resolve().parents[1]
D='archives/V68_FULL_NO_EXE_BUNDLE_B64'
FIX='archives/V68_BUNDLE_FIXUPS/part015_0.txt'
DEFAULT_NAME='WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll'
DEFAULT_SHA='deab16a21ab201e8edc4d8a245a739a6b879e57f7c11efe922451ee0eea9823b'

def sh(*a,text=False): return subprocess.check_output(list(a),cwd=ROOT,text=text,stderr=subprocess.DEVNULL)
def clean(s): return ''.join(c for c in s if c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=')
def tar_octal(field): return int((field.split(b'\0',1)[0].strip() or b'0'),8)
def checksum_ok(h):
    if len(h)!=512: return False
    try: stored=tar_octal(h[148:156])
    except Exception: return False
    return stored==sum(h[:148])+sum(b'        ')+sum(h[156:])
def member_name(h):
    name=h[:100].split(b'\0',1)[0].decode('utf-8','replace')
    prefix=h[345:500].split(b'\0',1)[0].decode('utf-8','replace')
    return (prefix.rstrip('/')+'/'+name) if prefix else name

def find_member(blob,wanted,want_sha):
    # TAR headers are 512-byte aligned from archive offset 0.
    for off in range(0,max(0,len(blob)-511),512):
        h=blob[off:off+512]
        if not checksum_ok(h): continue
        n=member_name(h)
        if pathlib.PurePosixPath(n).name!=wanted: continue
        try: size=tar_octal(h[124:136])
        except Exception: continue
        a=off+512; b=a+size
        if b>len(blob): continue
        data=blob[a:b]; got=hashlib.sha256(data).hexdigest()
        print(f'candidate member={n} off={off} size={size} sha256={got}')
        if got==want_sha: return data,n,off
    return None

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--output',required=True)
    ap.add_argument('--name',default=DEFAULT_NAME)
    ap.add_argument('--sha256',default=DEFAULT_SHA)
    a=ap.parse_args(); wanted=a.name; want=a.sha256.lower()

    prefix=''.join(clean(sh('git','show',f'HEAD:{D}/part{i:03d}.txt').decode()) for i in range(15))
    fix=clean(sh('git','show','HEAD:'+FIX).decode())
    p15=f'{D}/part015.txt'
    revs=sh('git','log','--all','--format=%H','--',p15,text=True).splitlines()+['HEAD']
    variants=[]; seen=set()
    for rev in revs:
        try: v=clean(sh('git','show',f'{rev}:{p15}').decode())
        except Exception: continue
        key=hashlib.sha256(v.encode()).hexdigest()
        if key not in seen: seen.add(key); variants.append((rev,v))

    specs=[]; used=set()
    def add(label,c):
        if len(c)==10000 and '=' not in c:
            h=hashlib.sha256(c.encode()).hexdigest()
            if h not in used: used.add(h); specs.append((label,c))
    for rev,v in variants:
        if len(v)==10005:
            for off in (2702,2936,3667,5000): add(f'{rev[:12]}:10005:{off}',fix+v[off:off+5000])
        if len(v)==10593: add(f'{rev[:12]}:10593:5148',fix+v[5148:5148+5000])
        # Generic bounded fallback around historical corruption windows.
        for off in range(0,max(0,len(v)-4999)):
            w=v[off:off+5000]
            if '=' not in w: add(f'{rev[:8]}:scan:{off}',fix+w)

    print(f'recovery specs={len(specs)} prefix_chars={len(prefix)} fix_chars={len(fix)}')
    for label,c15 in specs:
        try:
            raw=base64.b64decode(prefix+c15,validate=True)
            d=lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
            blob=d.decompress(raw)
        except Exception: continue
        found=find_member(blob,wanted,want)
        if found:
            data,n,off=found
            out=pathlib.Path(a.output); out.parent.mkdir(parents=True,exist_ok=True); out.write_bytes(data)
            print(f'RECOVERED {wanted} via={label} tar={n} off={off} size={len(data)} sha256={want}')
            return 0
    raise SystemExit(f'exact {wanted} sha256={want} not recovered from verified V68 prefix variants')

if __name__=='__main__': raise SystemExit(main())
