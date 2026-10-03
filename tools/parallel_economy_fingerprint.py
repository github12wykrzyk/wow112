#!/usr/bin/env python3
"""Compute deterministic native/addon/profile fingerprints for Parallel ECONOMY."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime/parallel_economy.json"


def digest_rows(rows):
    h = hashlib.sha256()
    for label, payload in sorted(rows, key=lambda x: x[0].lower()):
        h.update(label.encode("utf-8") + b"\0")
        h.update(payload)
        h.update(b"\0")
    return h.hexdigest()


def file_rows(paths):
    out = []
    for path in paths:
        p = ROOT / path
        if not p.is_file():
            raise SystemExit("missing fingerprint input: " + path)
        out.append((path.replace("\\", "/"), p.read_bytes()))
    return out


def root_rows(paths):
    out = []
    for value in paths:
        root = ROOT / value
        if not root.is_dir():
            raise SystemExit("missing fingerprint root: " + value)
        for p in root.rglob("*"):
            if p.is_file():
                out.append((str(p.relative_to(ROOT)).replace("\\", "/"), p.read_bytes()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="dist/economy_fingerprint.json")
    ap.add_argument("--github-output")
    args = ap.parse_args()
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    native_paths = [x["source"] for x in data["dlls"]] + [
        "tools/build_parallel_companion.py",
        "tools/build_active_module.py",
        "runtime/parallel_candidate.json",
        "runtime/parallel_economy.json",
    ]
    common = ROOT / "src/common"
    if common.is_dir():
        native_paths.extend(str(x.relative_to(ROOT)).replace("\\", "/") for x in common.rglob("*") if x.is_file())
    native = digest_rows(file_rows(native_paths))

    addon_rows = []
    for name in data["addons"]["roots"]:
        root = ROOT / "src/AddOns" / name
        for p in root.rglob("*"):
            if p.is_file():
                addon_rows.append((str(p.relative_to(ROOT)).replace("\\", "/"), p.read_bytes()))
    for item in data["addons"].get("external", []):
        addon_rows.append(("external:" + item["destination"], (item["repository"] + "@" + item["commit"]).encode("utf-8")))
    for item in data.get("hot_hosts", []):
        addon_rows.extend(file_rows([item["source"]] + list(item.get("fingerprint_files", []))))
        addon_rows.extend(root_rows(item.get("fingerprint_roots", [])))
        addon_rows.append(("hot-host-runtime:" + item["runtime_path"], json.dumps(item.get("transforms", []), separators=(",", ":")).encode("utf-8")))
    addon = digest_rows(addon_rows)
    profile = digest_rows([
        ("native", native.encode("ascii")),
        ("addon", addon.encode("ascii")),
        ("manifest", MANIFEST.read_bytes()),
        ("packager", (ROOT / "tools/package_parallel_economy_overlay.py").read_bytes()),
    ])
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    except Exception:
        head = ""
    out = {
        "schema_version": 1,
        "profile": "ECONOMY",
        "git_head": head,
        "native_fingerprint": native,
        "addon_fingerprint": addon,
        "profile_fingerprint": profile,
    }
    dest = ROOT / args.output
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as f:
            f.write("native_fingerprint=" + native + "\n")
            f.write("addon_fingerprint=" + addon + "\n")
            f.write("profile_fingerprint=" + profile + "\n")
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
