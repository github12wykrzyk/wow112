#!/usr/bin/env python3
"""Deterministic addon-only ZIP; separate from the root-only WoW.exe/DLL candidate."""
import argparse
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
LAZY_BASE = ROOT / "src/LazyScript/upstream/Addons"
ADDON_SOURCES = {
    "LazyScript": LAZY_BASE / "LazyScript",
    "LazyRogue": LAZY_BASE / "LazyRogue",
    "LazyWarlock": LAZY_BASE / "LazyWarlock",
    "SummonScout": ROOT / "src/AddOns/SummonScout",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="dist/WoW112_LAZYROGUE_HYBRID_ADDONS.zip")
    args = ap.parse_args()
    output = (ROOT / args.output).resolve()

    files = [
        (folder, root, path)
        for folder, root in ADDON_SOURCES.items()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    ]
    required = [root / (folder + ".toc") for folder, root in ADDON_SOURCES.items()]
    if len(files) < 22 or not all(path.is_file() for path in required):
        raise SystemExit("LazyScript/LazyRogue/LazyWarlock/SummonScout source incomplete")

    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w") as z:
        for folder, root, path in files:
            arc = "Interface/AddOns/" + folder + "/" + path.relative_to(root).as_posix()
            info = ZipInfo(arc, (2026, 9, 20, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            z.writestr(info, path.read_bytes())

    with ZipFile(output) as z:
        names = z.namelist()
        assert z.testzip() is None
        assert len(names) == len(files)
        assert len(names) == len(set(name.lower() for name in names))
        assert "Interface/AddOns/SummonScout/SummonScout.toc" in names
        assert "Interface/AddOns/SummonScout/SummonScout.lua" in names

    print(
        "ADDON_PACKAGE: PASS",
        output,
        "files",
        len(files),
        "sha256",
        hashlib.sha256(output.read_bytes()).hexdigest(),
    )


if __name__ == "__main__":
    main()
