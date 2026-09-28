#!/usr/bin/env python3
"""Deterministic repo-managed addon ZIP for the parallel candidate."""
import argparse
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
LAZY_BASE = ROOT / "src/LazyScript/upstream/Addons"
LOCAL_BASE = ROOT / "src/AddOns"
CORE_ADDONS = ("LazyScript", "LazyRogue", "LazyWarlock")
ALLOWED_EXTENSIONS = {
    ".lua", ".toc", ".xml",
    ".tga", ".blp", ".ttf",
    ".txt", ".md",
    ".wav", ".mp3", ".ogg",
    ".jpg", ".jpeg", ".png",
}


def has_root_toc(root):
    return any(path.is_file() and path.suffix.lower() == ".toc" for path in root.iterdir())


def discover_addons():
    sources = {}
    seen = set()

    def add(name, path, required):
        key = name.lower()
        if key in seen:
            raise SystemExit("duplicate addon folder name: " + name)
        if not path.is_dir():
            if required:
                raise SystemExit("required addon source missing: " + str(path))
            return
        if not has_root_toc(path):
            if required:
                raise SystemExit("required addon has no root .toc: " + str(path))
            return
        seen.add(key)
        sources[name] = path

    for name in CORE_ADDONS:
        add(name, LAZY_BASE / name, True)

    if LOCAL_BASE.is_dir():
        for path in sorted(LOCAL_BASE.iterdir(), key=lambda p: p.name.lower()):
            if path.is_dir():
                add(path.name, path, False)

    return sources


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="dist/WoW112_LAZYROGUE_HYBRID_ADDONS.zip")
    args = ap.parse_args()
    output = (ROOT / args.output).resolve()
    sources = discover_addons()

    files = []
    for folder, root in sources.items():
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix.lower() not in ALLOWED_EXTENSIONS:
                raise SystemExit("unsupported addon file type: " + str(path.relative_to(ROOT)))
            files.append((folder, root, path))

    if not files:
        raise SystemExit("no addon files discovered")

    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w") as z:
        for folder, root, path in files:
            arc = "Interface/AddOns/" + folder + "/" + path.relative_to(root).as_posix()
            info = ZipInfo(arc, (2026, 9, 20, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            z.writestr(info, path.read_bytes())

    with ZipFile(output) as z:
        names = z.namelist()
        lowered = [name.lower() for name in names]
        if z.testzip() is not None:
            raise SystemExit("addon ZIP CRC failure")
        if len(names) != len(set(lowered)):
            raise SystemExit("case-insensitive duplicate addon path")
        for folder in sources:
            prefix = ("Interface/AddOns/" + folder + "/").lower()
            if not any(name.lower().startswith(prefix) and
                       "/" not in name[len(prefix):] and
                       name.lower().endswith(".toc")
                       for name in names):
                raise SystemExit("packaged addon has no root .toc: " + folder)

    print(
        "ADDON_PACKAGE: PASS",
        output,
        "addons",
        ",".join(sorted(sources, key=str.lower)),
        "files",
        len(files),
        "sha256",
        hashlib.sha256(output.read_bytes()).hexdigest(),
    )


if __name__ == "__main__":
    main()
