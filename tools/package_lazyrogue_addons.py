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

SUMMONSCOUT_ROOT = LOCAL_BASE / "SummonScout"
SUMMONSCOUT_TOC = SUMMONSCOUT_ROOT / "SummonScout.toc"
HOT_FANOUT_HOST = "SummonScout_WhisperConfirmSpam.lua"
HOT_PAYLOAD_CAP = 262144
FANOUT_BEGIN_MARKER = b"W112_SUMMONSCOUT_HOT_FANOUT_BEGIN:v1"
FANOUT_END_MARKER = b"W112_SUMMONSCOUT_HOT_FANOUT_END:v1"
DIRECT_WATCHED_OR_HOSTED = {
    "SummonScout_PostPaymentOfferHot.lua",
    HOT_FANOUT_HOST,
    "SummonScout_TimingHot.lua",
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


def hot_fanout_modules():
    if not SUMMONSCOUT_TOC.is_file():
        raise RuntimeError("SummonScout HOT fanout: missing SummonScout.toc")

    ordered = []
    seen = set()
    for raw in SUMMONSCOUT_TOC.read_text(encoding="utf-8").splitlines():
        name = raw.strip()
        if not name or name.startswith("##"):
            continue
        if not (name.startswith("SummonScout_") and name.endswith("Hot.lua")):
            continue
        if name in seen:
            raise RuntimeError("SummonScout HOT fanout: duplicate TOC entry: " + name)
        seen.add(name)
        if name not in DIRECT_WATCHED_OR_HOSTED:
            ordered.append(name)

    discovered = {
        path.name
        for path in SUMMONSCOUT_ROOT.glob("SummonScout_*Hot.lua")
        if path.name not in DIRECT_WATCHED_OR_HOSTED
    }
    if set(ordered) != discovered:
        missing = sorted(discovered - set(ordered))
        stale = sorted(set(ordered) - discovered)
        raise RuntimeError(
            "SummonScout HOT fanout TOC/source mismatch: missing="
            + ",".join(missing) + " stale=" + ",".join(stale)
        )
    return ordered


def append_summonscout_hot_fanout(data):
    if FANOUT_BEGIN_MARKER in data or FANOUT_END_MARKER in data:
        raise RuntimeError("SummonScout HOT fanout already appended")

    guard = (
        'local __w112_hot_fanout_reload = W112_SUMMONSCOUT_HOT '
        'and W112_SUMMONSCOUT_HOT.modules '
        'and W112_SUMMONSCOUT_HOT.modules["whisperconfirm"] ~= nil\n'
    ).encode("utf-8")
    prepare = (
        'if __w112_hot_fanout_reload and W112_SUMMONSCOUT_HOT '
        'and type(W112_SUMMONSCOUT_HOT.PrepareFanoutReload) == "function" then '
        'W112_SUMMONSCOUT_HOT.PrepareFanoutReload() end\n'
    ).encode("utf-8")
    rows = [
        guard,
        prepare,
        data.rstrip(b"\r\n"),
        b"\n\n-- " + FANOUT_BEGIN_MARKER + b"\n",
        b"if __w112_hot_fanout_reload then\n",
    ]

    for index, name in enumerate(hot_fanout_modules(), start=1):
        path = SUMMONSCOUT_ROOT / name
        payload = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        if not payload.strip() or b"\x00" in payload:
            raise RuntimeError("SummonScout HOT fanout invalid payload: " + name)
        wrapper = "__w112_hot_fanout_module_" + str(index)
        rows.extend([
            ("    -- W112 HOT FANOUT BEGIN " + name + "\n").encode("utf-8"),
            ("    local function " + wrapper + "()\n").encode("utf-8"),
            payload.rstrip(b"\n"),
            ("\n    end\n    " + wrapper + "()\n").encode("utf-8"),
            ("    -- W112 HOT FANOUT END " + name + "\n").encode("utf-8"),
        ])

    rows.extend([
        b"end\n",
        b"-- " + FANOUT_END_MARKER + b"\n",
    ])
    out = b"".join(rows)
    if b"\n    (function()\n" in out:
        raise RuntimeError("SummonScout HOT fanout emitted Lua 5.0 ambiguous IIFE syntax")
    if b"PrepareFanoutReload()" not in out:
        raise RuntimeError("SummonScout HOT fanout missing pre-reload wrapper reset")
    if len(out) >= HOT_PAYLOAD_CAP:
        raise RuntimeError(
            "SummonScout HOT fanout exceeds native watcher payload cap: "
            + str(len(out)) + "/" + str(HOT_PAYLOAD_CAP)
        )
    return out


def package_bytes(folder, path):
    data = path.read_bytes()
    if folder.lower() == "summonscout":
        data = transform_summonscout_file(path.name, data)
        if path.name == HOT_FANOUT_HOST:
            data = append_summonscout_hot_fanout(data)
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
