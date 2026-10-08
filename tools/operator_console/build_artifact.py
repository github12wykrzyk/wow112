from __future__ import annotations
import argparse, hashlib, json, os, zipfile
from pathlib import Path

def main():
    p=argparse.ArgumentParser(); p.add_argument('--sha',default=os.getenv('GITHUB_SHA','LOCAL')); p.add_argument('--out',default='dist'); a=p.parse_args()
    root=Path(__file__).resolve().parent; out=root/a.out; out.mkdir(parents=True,exist_ok=True)
    short=a.sha[:12]; zip_path=out/f'WoW112-Summon-Console-Service-Adapter-V1-{short}.zip'
    include=['README.md','ARCHITECTURE.md','CONTRACT.md','protocol.py','store.py','service_adapter.py','mock_service.py','build_artifact.py','ci.py','web/index.html']
    include += [str(p.relative_to(root)) for p in sorted((root/'tests').glob('test_*.py'))]
    manifest={'schema_version':1,'source_sha':a.sha,'files':{}}
    for rel in include:
        data=(root/rel).read_bytes(); manifest['files'][rel]=hashlib.sha256(data).hexdigest()
    with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for rel in include: z.write(root/rel,rel)
        z.writestr('manifest.json',json.dumps(manifest,indent=2,sort_keys=True))
    print(zip_path)
    print('sha256',hashlib.sha256(zip_path.read_bytes()).hexdigest())
if __name__=='__main__': main()
