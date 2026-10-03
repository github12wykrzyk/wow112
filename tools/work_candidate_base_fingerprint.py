#!/usr/bin/env python3
"""Compute a deterministic fingerprint for the reusable work-candidate native base."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
CURRENT = ROOT / "CURRENT.json"
WORK = ROOT / "runtime/work_candidate.json"


def digest_rows(rows):
    h = hashlib.sha256()
    for label, payload in sorted(rows, key=lambda x: x[0].lower()):
        h.update(label.encode("utf-8") + b"\0")
        h.update(payload)
        h.update(b"\0")
    return h.hexdigest()


def add_file(rows, seen, rel):
    rel = str(rel).replace("\\", "/")
    if rel in seen:
        return
    p = ROOT / rel
    if not p.is_file():
        raise SystemExit("missing base fingerprint input: " + rel)
    seen.add(rel)
    rows.append((rel, p.read_bytes()))


def add_tree(rows, seen, rel_dir):
    root = ROOT / rel_dir
    if not root.is_dir():
        raise SystemExit("missing base fingerprint directory: " + rel_dir)
    for p in root.rglob("*"):
        if p.is_file():
            add_file(rows, seen, p.relative_to(ROOT))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="dist/work_candidate_base_fingerprint.json")
    ap.add_argument("--github-output")
    args = ap.parse_args()

    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    current = json.loads(CURRENT.read_text(encoding="utf-8"))
    work = json.loads(WORK.read_text(encoding="utf-8"))
    active = {x.get("name"): x for x in runtime.get("active_dlls", []) if isinstance(x, dict)}

    rows = []
    seen = set()
    for rel in (
        "runtime/current.json",
        "CURRENT.json",
        "runtime/work_candidate.json",
        ".github/workflows/build_work_candidate.yml",
        "tools/build_active_module.py",
        "tools/build_changed_active.py",
        "tools/package_current.py",
        "tools/patch_autopp_fastscan_candidate.py",
        "tools/work_candidate_base_fingerprint.py",
        "tools/rehydrate_work_candidate_base.py",
    ):
        add_file(rows, seen, rel)

    exe_rel = (current.get("exe") or {}).get("path")
    if not exe_rel:
        raise SystemExit("CURRENT.json exe.path missing")
    add_file(rows, seen, exe_rel)

    for item in runtime.get("active_dlls", []):
        if not isinstance(item, dict):
            continue
        artifact = item.get("binary_artifact")
        if isinstance(artifact, dict) and artifact.get("path"):
            add_file(rows, seen, artifact["path"])

    names = work.get("source_overrides", [])
    if not isinstance(names, list) or any(not isinstance(x, str) for x in names):
        raise SystemExit("runtime/work_candidate.json source_overrides must be a list")
    for name in names:
        item = active.get(name)
        if item is None:
            raise SystemExit("unknown persistent candidate module: " + name)
        source = item.get("source_path")
        if not source:
            raise SystemExit("persistent candidate module has no source_path: " + name)
        source_path = ROOT / source
        add_tree(rows, seen, str(source_path.parent.relative_to(ROOT)).replace("\\", "/"))

    common = ROOT / "src/common"
    if common.is_dir():
        add_tree(rows, seen, "src/common")

    fingerprint = digest_rows(rows)
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    result = {
        "schema_version": 1,
        "kind": "work_candidate_native_base",
        "base_fingerprint": fingerprint,
        "input_count": len(rows),
        "inputs": [
            {"path": label, "sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)}
            for label, payload in sorted(rows, key=lambda x: x[0].lower())
        ],
    }
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as f:
            f.write("base_fingerprint=" + fingerprint + "\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
