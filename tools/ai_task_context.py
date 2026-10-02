#!/usr/bin/env python3
"""Emit compact deterministic context for one wow112 task/module.

This is a read-only routing helper. It does not replace live GitHub refs,
canonical startup authority, the experiment ledger, or any verification gate.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "runtime" / "ai_experiments.json"
PARALLEL = ROOT / "runtime" / "parallel_candidate.json"
ECONOMY = ROOT / "runtime" / "parallel_economy.json"
RUNTIME = ROOT / "runtime" / "current.json"
ACTIVE = {"planned", "in_progress", "awaiting_ci", "awaiting_game_test", "blocked"}


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_head(branch):
    for ref in (branch, "origin/" + branch):
        try:
            value = subprocess.check_output(
                ["git", "rev-parse", "--verify", ref], cwd=ROOT, text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            continue
        if len(value) == 40:
            return value
    return None


def compact_experiment(exp):
    pkg = exp.get("package")
    return {
        "id": exp["id"],
        "branch": exp["branch"],
        "status": exp["status"],
        "observed_head": exp.get("observed_head"),
        "verified_commit": exp.get("verified_commit"),
        "dependencies": list(exp.get("dependencies", [])),
        "artifact_id": pkg.get("artifact_id") if isinstance(pkg, dict) else None,
    }


def source_hints(module, runtime, parallel):
    hints = []

    def add(path):
        path = str(path).replace("\\", "/")
        if path and path not in hints:
            hints.append(path)

    direct = ROOT / "src" / module
    if direct.exists():
        add(direct.relative_to(ROOT))
    addon = ROOT / "src" / "AddOns" / module
    if addon.exists():
        add(addon.relative_to(ROOT))

    for item in runtime.get("active_dlls", []):
        source = item.get("source_path")
        if source and ("/" + module.lower() + "/") in ("/" + source.lower()):
            add(source)

    for item in parallel.get("companions", []) + parallel.get("replacements", []):
        for source in item.get("sources", []):
            if ("/" + module.lower() + "/") in ("/" + source.lower()):
                add(source)

    if module in parallel.get("addons", {}).get("roots", []):
        add("src/AddOns/" + module)
    return hints


def economy_eligible(module, economy):
    if module in economy.get("addons", {}).get("roots", []):
        return True
    needle = "/" + module.lower() + "/"
    return any(
        needle in ("/" + str(item.get("source", "")).lower())
        for item in economy.get("dlls", [])
    )


def build_context(module, branch="parallel", limit=6, head=None):
    if not module or any(c.isspace() for c in module):
        raise ValueError("module must be a non-empty token")
    if limit < 1 or limit > 20:
        raise ValueError("limit must be in range 1..20")

    ledger = load_json(LEDGER)
    parallel = load_json(PARALLEL)
    economy = load_json(ECONOMY) if ECONOMY.exists() else {}
    runtime = load_json(RUNTIME)

    active = [
        exp for exp in ledger.get("experiments", [])
        if exp.get("status") in ACTIVE and module in exp.get("modules", [])
    ]
    recent = list(reversed(active))[:limit]
    branch_active = [exp for exp in reversed(active) if exp.get("branch") == branch][:limit]
    feature_active = [
        exp for exp in reversed(active)
        if str(exp.get("branch", "")).startswith("feature/")
    ][:limit]

    eligible = economy_eligible(module, economy)
    workflows = {
        "feature_preflight": ".github/workflows/parallel_feature_preflight.yml",
        "parallel_candidate": parallel.get("workflow"),
        "economy": economy.get("delivery", {}).get("workflow") if eligible else None,
    }
    lifecycle = []
    if branch == "parallel":
        lifecycle = [
            "feature_exact_sha_preflight_pass",
            "integrate_verified_feature_into_current_parallel",
            "parallel_exact_sha_build_candidate_pass",
        ]
        if eligible:
            lifecycle.append("parallel_exact_sha_economy_pass")
        lifecycle.append("test_ready_exact_sha_artifact")

    return {
        "schema_version": 1,
        "module": module,
        "selected_branch": branch,
        "selected_branch_head": head if head is not None else resolve_head(branch),
        "source_hints": source_hints(module, runtime, parallel),
        "routing": {
            "active_count": len(active),
            "recent_active": [compact_experiment(exp) for exp in recent],
            "selected_branch_active": [compact_experiment(exp) for exp in branch_active],
            "feature_candidates": [compact_experiment(exp) for exp in feature_active],
        },
        "delivery": {
            "economy_eligible": eligible,
            "workflows": workflows,
            "lifecycle": lifecycle,
        },
        "verification": [
            "python tools/verify_current.py",
            "python tools/verify_runtime_artifacts.py",
            "python tools/verify_verified_symbols.py",
        ],
        "authority": {
            "ledger": "runtime/ai_experiments.json",
            "parallel_manifest": "runtime/parallel_candidate.json",
            "runtime_manifest": "runtime/current.json",
            "live_git_ref_required_before_write": True,
        },
    }


def render_text(ctx):
    lines = [
        "AI_TASK_CONTEXT",
        "  module: %s" % ctx["module"],
        "  branch: %s @ %s" % (ctx["selected_branch"], ctx["selected_branch_head"] or "<unresolved>"),
        "  sources: %s" % (", ".join(ctx["source_hints"]) or "<inspect module>"),
        "  active experiments: %d" % ctx["routing"]["active_count"],
    ]
    for exp in ctx["routing"]["recent_active"]:
        lines.append("    - %s | %s | %s" % (exp["id"], exp["branch"], exp["status"]))
    delivery = ctx["delivery"]
    lines.append("  economy eligible: %s" % ("yes" if delivery["economy_eligible"] else "no"))
    lines.append("  lifecycle: " + " -> ".join(delivery["lifecycle"]))
    lines.append("  workflows:")
    for key, value in delivery["workflows"].items():
        if value:
            lines.append("    - %s: %s" % (key, value))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True)
    parser.add_argument("--branch", default="parallel")
    parser.add_argument("--limit", type=int, default=6)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        ctx = build_context(args.module, args.branch, args.limit)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("AI_TASK_CONTEXT: FAIL: " + str(exc), file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(ctx, indent=2, sort_keys=True))
    else:
        sys.stdout.write(render_text(ctx))
    return 0


if __name__ == "__main__":
    sys.exit(main())
