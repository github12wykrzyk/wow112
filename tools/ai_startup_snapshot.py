#!/usr/bin/env python3
"""Generate/check the compact fail-closed AI startup snapshot."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "runtime" / "ai_startup_snapshot.json"
SOURCES = (
    "AGENTS.md",
    "AI_START_HERE.md",
    "AI_INDEX.json",
    "CURRENT.json",
    "runtime/current.json",
)


def require(condition, description):
    if not condition:
        raise ValueError(description)


def git_blob_sha1(data):
    header = ("blob %d\0" % len(data)).encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def source_meta(relpath):
    data = (ROOT / relpath).read_bytes()
    return {"git_blob_sha1": git_blob_sha1(data)}


def build_snapshot():
    ai_index = json.loads((ROOT / "AI_INDEX.json").read_text(encoding="utf-8"))
    current = json.loads((ROOT / "CURRENT.json").read_text(encoding="utf-8"))
    runtime = json.loads((ROOT / "runtime" / "current.json").read_text(encoding="utf-8"))
    fast = ai_index.get("startup_fast_path")
    require(isinstance(fast, dict) and fast.get("schema_version") == 1,
            "AI_INDEX.json startup_fast_path is missing or invalid")
    require(tuple(fast.get("source_files", [])) == SOURCES,
            "startup_fast_path source_files must match canonical startup sources")

    chat_policy = ai_index.get("chat_execution_policy")
    require(isinstance(chat_policy, dict),
            "AI_INDEX.json chat_execution_policy is missing or invalid")

    active = []
    for dll in runtime.get("active_dlls", []):
        active.append({
            "name": dll.get("name"),
            "source_state": dll.get("source_state"),
            "source_path": dll.get("source_path"),
            "build_tool": (dll.get("build_recipe") or {}).get("tool"),
            "build_profile": (dll.get("build_recipe") or {}).get("profile"),
        })

    return {
        "schema_version": 1,
        "purpose": "Verified compact startup context; generated cache only, never canonical authority.",
        "source_files": {path: source_meta(path) for path in SOURCES},
        "chat_execution_policy": chat_policy,
        "fast_path": fast,
        "target": ai_index.get("target"),
        "branches": ai_index.get("branches"),
        "state": {
            "stable_baseline": current.get("stable_baseline"),
            "candidate_status": current.get("status"),
            "canonical_source_root": current.get("canonical_source_root"),
            "runtime_manifest": current.get("runtime_manifest"),
            "runtime_baseline": runtime.get("baseline"),
            "exe": runtime.get("exe"),
            "active_dlls": active,
        },
        "routing": {
            "experiment_fast_index": ai_index.get("canonical", {}).get("experiment_fast_index"),
            "parallel_candidate_manifest": ai_index.get("canonical", {}).get("parallel_candidate_manifest"),
            "parallel_feature_preflight": ai_index.get("canonical", {}).get("parallel_feature_preflight"),
            "promotion_workflow": ai_index.get("canonical", {}).get("promotion_workflow"),
        },
        "verification": {
            "fast_verify": ai_index.get("commands", {}).get("fast_verify"),
            "runtime_verify": ai_index.get("commands", {}).get("runtime_verify"),
            "verified_symbols_verify": ai_index.get("commands", {}).get("verified_symbols_verify"),
            "parallel_feature_preflight": ai_index.get("commands", {}).get("parallel_feature_preflight"),
            "check_experiment_fast_index": ai_index.get("commands", {}).get("check_experiment_fast_index"),
        },
    }


def render_snapshot():
    return json.dumps(build_snapshot(), indent=2, sort_keys=True) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        rendered = render_snapshot()
        if args.check:
            require(SNAPSHOT.exists(), "startup snapshot is missing")
            require(SNAPSHOT.read_text(encoding="utf-8") == rendered,
                    "startup snapshot is stale; run: python tools/ai_startup_snapshot.py")
            print("AI_STARTUP_SNAPSHOT: PASS")
        else:
            SNAPSHOT.write_text(rendered, encoding="utf-8")
            print("AI_STARTUP_SNAPSHOT: wrote " + str(SNAPSHOT))
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print("AI_STARTUP_SNAPSHOT: FAIL: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
