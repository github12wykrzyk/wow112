#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_json(rel):
    path = ROOT / rel
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def build_status():
    index = load_json("AI_INDEX.json")
    current = load_json("CURRENT.json")
    runtime = load_json(current.get("runtime_manifest", "runtime/current.json"))

    modules = []
    for item in runtime.get("active_dlls", []):
        modules.append(
            {
                "name": item.get("name"),
                "sha256": item.get("sha256"),
                "source_state": item.get("source_state"),
                "source_origin": item.get("source_origin"),
                "source_path": item.get("source_path"),
                "source_restore_doc": item.get("source_restore_doc"),
                "binary_reproducer": item.get("binary_reproducer"),
            }
        )

    return {
        "target": {
            "version": current.get("wow_version"),
            "build": current.get("wow_build"),
            "architecture": current.get("architecture"),
        },
        "stable_baseline": current.get("stable_baseline"),
        "status": current.get("status"),
        "branches": {
            "stable": current.get("stable_branch"),
            "development": current.get("working_branch"),
        },
        "baseline_dir": current.get("baseline_dir"),
        "runtime_manifest": current.get("runtime_manifest"),
        "sha256_manifest": current.get("sha256_manifest"),
        "canonical_source_root": current.get("canonical_source_root", index.get("canonical", {}).get("source_root")),
        "exe": runtime.get("exe", {}),
        "modules": modules,
    }


def main():
    parser = argparse.ArgumentParser(description="Print compact canonical wow112 repository status.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    args = parser.parse_args()

    try:
        status = build_status()
    except Exception as exc:
        print("ERROR: could not read canonical repository metadata: %s" % exc, file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(status, indent=2, sort_keys=False))
        return 0

    target = status["target"]
    print("wow112 canonical status")
    print("  target: WoW %s build %s %s" % (
        target.get("version"), target.get("build"), target.get("architecture")
    ))
    print("  stable baseline: %s (%s)" % (status.get("stable_baseline"), status.get("status")))
    print("  branches: stable=%s development=%s" % (
        status["branches"].get("stable"), status["branches"].get("development")
    ))
    exe = status.get("exe", {})
    print("  EXE: %s" % exe.get("name"))
    print("  active DLLs: %d" % len(status.get("modules", [])))
    for idx, item in enumerate(status.get("modules", []), 1):
        source = item.get("source_path") or item.get("source_restore_doc") or "<no indexed source path>"
        print("    %d. %s" % (idx, item.get("name")))
        print("       source_state=%s source=%s" % (item.get("source_state"), source))
    return 0


if __name__ == "__main__":
    sys.exit(main())
