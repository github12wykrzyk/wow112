from __future__ import annotations
import subprocess, sys
from pathlib import Path

def main():
    root=Path(__file__).resolve().parent
    cmd=[sys.executable,'-m','unittest','discover','-s',str(root/'tests'),'-p','test_*.py','-v']
    rc=subprocess.run(cmd,cwd=root).returncode
    if rc: raise SystemExit(rc)
    if '--artifact' in sys.argv:
        subprocess.check_call([sys.executable,str(root/'build_artifact.py')],cwd=root)
if __name__=='__main__': main()
