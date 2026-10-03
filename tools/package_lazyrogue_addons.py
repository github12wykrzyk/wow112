#!/usr/bin/env python3
"""Deterministic repo-managed addon ZIP for the parallel candidate."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from ah_shadow_hot_bundle import transform_summonscout_host
from summonscout_hot_transform import transform_file as transform_summonscout_file

ROOT = Path(__file__).resolve().parents[1]
LAZY_BASE = ROOT / "src/LazyScript/upstream/Addons"
LOCAL_BASE = ROOT / "src/AddOns"
MANIFEST = ROOT / "runtime/parallel_candidate.json"
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


def declared_external_addons():
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    addons = data.get("addons")
    external = addons.get("external", []) if isinstance(addons, dict) else []
    if not isinstance(external, list):
        raise SystemExit("parallel candidate manifest has invalid external addons")
    out = []
    seen = set()
    for item in external:
        if not isinstance(item, dict):
            raise SystemExit("external addon entry must be an object")
        name = item.get("name")
        repo = item.get("repository")
        commit = item.get("commit")
        destination = item.get("destination")
        if not all(isinstance(x, str) and x for x in (name, repo, commit, destination)):
            raise SystemExit("external addon entry missing name/repository/commit/destination")
        if len(commit) != 40 or any(c not in "0123456789abcdefABCDEF" for c in commit):
            raise SystemExit("external addon commit must be full SHA: " + name)
        key = destination.lower()
        if key in seen:
            raise SystemExit("duplicate external addon destination: " + destination)
        seen.add(key)
        out.append(item)
    return out


def checkout_external_addons():
    sources = {}
    base = ROOT / "build/third_party_addons"
    for item in declared_external_addons():
        destination = item["destination"]
        repo = item["repository"]
        commit = item["commit"].lower()
        path = base / destination
        if path.exists():
            shutil.rmtree(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--quiet", "--no-checkout", "https://github.com/" + repo + ".git", str(path)],
            cwd=ROOT, check=True
        )
        subprocess.run(["git", "-C", str(path), "checkout", "--quiet", "--detach", commit], cwd=ROOT, check=True)
        actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip().lower()
        if actual != commit:
            raise SystemExit("external addon SHA mismatch: " + destination)
        if not has_root_toc(path):
            raise SystemExit("external addon has no root .toc: " + destination)
        sources[destination] = path
    return sources


def declared_addon_roots():
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    addons = data.get("addons")
    roots = addons.get("roots") if isinstance(addons, dict) else None
    if not isinstance(roots, list) or not roots or not all(isinstance(x, str) and x for x in roots):
        raise SystemExit("parallel candidate manifest has invalid addon roots")
    lowered = [x.lower() for x in roots]
    if len(lowered) != len(set(lowered)):
        raise SystemExit("parallel candidate manifest has duplicate addon roots")
    missing_core = [name for name in CORE_ADDONS if name.lower() not in set(lowered)]
    if missing_core:
        raise SystemExit("parallel candidate manifest omits required core addons: " + ",".join(missing_core))
    return roots


def discover_addons():
    sources = {}
    seen = set()
    roots = declared_addon_roots()

    for name in roots:
        key = name.lower()
        if key in seen:
            raise SystemExit("duplicate addon folder name: " + name)

        candidates = []
        lazy = LAZY_BASE / name
        local = LOCAL_BASE / name
        if lazy.is_dir():
            candidates.append(lazy)
        if local.is_dir():
            candidates.append(local)
        if len(candidates) != 1:
            raise SystemExit(
                "declared addon root must resolve to exactly one source directory: "
                + name + " -> " + ",".join(str(x) for x in candidates)
            )

        path = candidates[0]
        if not has_root_toc(path):
            raise SystemExit("declared addon has no root .toc: " + str(path))
        seen.add(key)
        sources[name] = path

    if set(name.lower() for name in sources) != set(name.lower() for name in roots):
        raise SystemExit("packaged addon roots differ from parallel candidate manifest")

    for folder, path in checkout_external_addons().items():
        key = folder.lower()
        if key in seen:
            raise SystemExit("external addon collides with declared addon root: " + folder)
        seen.add(key)
        sources[folder] = path
    return sources


def package_bytes(folder, path):
    data = path.read_bytes()
    if folder.lower() == "summonscout":
        data = transform_summonscout_file(path.name, data)
        data = transform_summonscout_host(path.name, data)
    return data


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
            rel = path.relative_to(root)
            if ".git" in rel.parts or path.name.startswith("."):
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
            z.writestr(info, package_bytes(folder, path))

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
