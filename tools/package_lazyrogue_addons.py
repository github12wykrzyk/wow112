#!/usr/bin/env python3
"""Deterministic addon-only ZIP; separate from the root-only WoW.exe/DLL candidate."""
import argparse
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "src/LazyScript/upstream/Addons"
ADDONS = ("LazyScript", "LazyRogue", "LazyWarlock")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="dist/WoW112_LAZYROGUE_HYBRID_ADDONS.zip")
    args = ap.parse_args()
    output = (ROOT / args.output).resolve()
    files = [(folder, p) for folder in ADDONS
             for p in sorted((BASE / folder).rglob("*")) if p.is_file()]
    if len(files) < 20 or not all((BASE/f/(f+".toc")).is_file() for f in ADDONS):
        raise SystemExit("LazyScript/LazyRogue source incomplete")
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w") as z:
        for folder, p in files:
            arc = "Interface/AddOns/" + folder + "/" + p.relative_to(BASE/folder).as_posix()
            info = ZipInfo(arc, (2026, 9, 20, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            z.writestr(info, p.read_bytes())
    with ZipFile(output) as z:
        assert z.testzip() is None and len(z.namelist()) == len(files)
    print("ADDON_PACKAGE: PASS", output, "files", len(files),
          "sha256", hashlib.sha256(output.read_bytes()).hexdigest())

if __name__ == "__main__":
    main()
