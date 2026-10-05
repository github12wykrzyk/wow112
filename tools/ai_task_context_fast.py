#!/usr/bin/env python3
"""Compact canonical-main task context without experiment-ledger archaeology."""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime" / "current.json"
PARALLEL = ROOT / "runtime" / "parallel_candidate.json"
POLICY = ROOT / "runtime" / "parallel_thread_policy.json"

def load(path):
    return json.loads(path.read_text(encoding="utf-8"))

def norm(value):
    return str(value).replace("\\", "/").strip("/")

def overlaps(a, b):
    a, b = norm(a), norm(b)
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")

def resolve_head(branch):
    for ref in (branch, "origin/" + branch):
        try:
            value = subprocess.check_output(
                ["git", "rev-parse", "--verify", ref], cwd=ROOT, text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            if len(value) == 40:
                return value
        except Exception:
            pass
    return None

def source_hints(module, runtime, candidate):
    out = []
    def add(path):
        path = norm(path)
        if path and path not in out and (ROOT / path).exists():
            out.append(path)
    add("src/" + module)
    add("src/AddOns/" + module)
    needle = "/" + module.lower() + "/"
    for item in runtime.get("active_dlls", []):
        path = item.get("source_path")
        if path and needle in ("/" + path.lower()):
            add(path)
    for item in candidate.get("companions", []) + candidate.get("replacements", []):
        for path in item.get("sources", []):
            if needle in ("/" + str(path).lower()):
                add(path)
    return out

def profiles(hints, policy):
    out = []
    for name, cfg in policy.get("delivery_profiles", {}).items():
        if any(overlaps(hint, required)
               for hint in hints
               for required in cfg.get("required_paths", [])):
            out.append(name)
    return out

def risk(module, hints):
    if module.lower().startswith("ai") or module in {"Updater", "Loader"}:
        return "WORKFLOW_INFRA"
    if any(norm(h).startswith("src/AddOns/") for h in hints):
        return "ADDON_LOCAL"
    if any(str(h).lower().endswith((".c", ".cc", ".cpp")) for h in hints):
        return "NATIVE"
    return "UNKNOWN_FAIL_CLOSED"

def build(module, branch="main"):
    runtime = load(RUNTIME)
    candidate = load(PARALLEL)
    policy = load(POLICY)
    hints = source_hints(module, runtime, candidate)
    return {
        "schema_version": 1,
        "module": module,
        "selected_branch": branch,
        "selected_branch_head": resolve_head(branch),
        "source_hints": hints,
        "risk": risk(module, hints),
        "delivery_profiles": profiles(hints, policy),
        "lifecycle": [
            "feature_exact_sha_preflight",
            "required_exact_feature_sha_profiles",
            "optimistic_cas_revalidate_against_live_main",
            "atomic_main_parallel_update",
            "path_risk_routed_exact_sha_delivery",
        ],
        "analysis_rule": "open_owner_files_then_implement; expand_only_for_concrete_unresolved_risk",
        "experiment_ledger_read": False,
    }

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--module", required=True)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    ctx = build(args.module, args.branch)
    if args.json:
        print(json.dumps(ctx, indent=2, sort_keys=True))
    else:
        print("AI_TASK_CONTEXT_FAST")
        print("  module:", ctx["module"])
        print("  branch:", ctx["selected_branch"], "@", ctx["selected_branch_head"] or "<unresolved>")
        print("  risk:", ctx["risk"])
        print("  sources:", ", ".join(ctx["source_hints"]) or "<known path/search required>")
        print("  profiles:", ", ".join(ctx["delivery_profiles"]) or "<none>")
        print("  lifecycle:", " -> ".join(ctx["lifecycle"]))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
