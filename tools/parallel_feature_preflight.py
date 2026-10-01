#!/usr/bin/env python3
"""Run fast gates and compile native sources changed relative to parallel."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
MANIFEST = ROOT / "runtime/parallel_candidate.json"

STATIC_GATES = [
    ["tools/verify_current.py"],
    ["tools/verify_runtime_artifacts.py"],
    ["tools/verify_verified_symbols.py"],
    ["tools/verify_parallel_dependency_registry.py"],
    ["tools/verify_candidate_source_scope.py"],
    ["tools/verify_parallel_candidate_manifest.py"],
    ["tools/verify_parallel_gui_abi.py"],
    ["tools/verify_parallel_gui_contract.py"],
    ["tools/ai_experiments.py", "validate"],
    ["tools/verify_summonscout_lua_upvalues.py"],
]

def run(args):
    cmd = [sys.executable, *args]
    print("RUN:", " ".join(cmd))
    result = subprocess.run(cmd, cwd=ROOT)
    if result.returncode:
        raise SystemExit(result.returncode)

def diff_paths(base):
    merge_base = subprocess.check_output(["git", "merge-base", base, "HEAD"], cwd=ROOT, text=True).strip()
    raw = subprocess.check_output(["git", "diff", "--name-only", merge_base, "HEAD"], cwd=ROOT, text=True)
    return sorted({x.strip().replace("\\", "/") for x in raw.splitlines() if x.strip()}), merge_base

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/parallel")
    args = ap.parse_args()

    changed, merge_base = diff_paths(args.base)
    print("PARALLEL_FEATURE_PREFLIGHT: merge_base=" + merge_base)
    print("PARALLEL_FEATURE_PREFLIGHT: changed=" + json.dumps(changed))

    for gate in STATIC_GATES:
        run(gate)
    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    force_active = any(
        p.startswith("src/common/") or p in ("tools/build_active_module.py", "runtime/current.json")
        for p in changed
    )
    active = []
    for item in runtime.get("active_dlls", []):
        source = item.get("source_path")
        recipe = item.get("build_recipe")
        if not source or not isinstance(recipe, dict) or not recipe.get("profile"):
            continue
        source = source.replace("\\", "/")
        if force_active or source in changed:
            active.append((source, item["name"]))

    for source, name in active:
        safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
        run([
            "tools/build_active_module.py", "--name", name,
            "--output", "build/preflight/" + name,
            "--metadata", "build/preflight/" + safe + ".json",
        ])

    force_companions = any(
        p in ("tools/build_parallel_companion.py", "runtime/parallel_candidate.json")
        or p.startswith("src/common/")
        for p in changed
    )
    companions = []
    for item in manifest.get("companions", []):
        sources = [x.replace("\\", "/") for x in item.get("sources", [])]
        if force_companions or any(x in changed for x in sources):
            companions.append(item["runtime_name"])

    for name in companions:
        safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
        run([
            "tools/build_parallel_companion.py", "--name", name,
            "--output", "build/preflight/" + name,
            "--metadata", "build/preflight/" + safe + ".json",
        ])

    print(
        "PARALLEL_FEATURE_PREFLIGHT: PASS "
        + f"(active_builds={len(active)}, companion_builds={len(companions)})"
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())
