#!/usr/bin/env python3
"""Emit compact deterministic FAST START context for one wow112 task/module.

This helper is read-only. Normal routing uses the compact experiment index and
only falls back to the full experiment ledger when the index is unavailable or
structurally invalid. Live GitHub refs and canonical manifests remain
authoritative before every write.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "runtime" / "ai_experiments.json"
INDEX = ROOT / "runtime" / "ai_experiment_index.json"
PARALLEL = ROOT / "runtime" / "parallel_candidate.json"
ECONOMY = ROOT / "runtime" / "parallel_economy.json"
RUNTIME = ROOT / "runtime" / "current.json"
THREAD_POLICY = ROOT / "runtime" / "parallel_thread_policy.json"
DEPENDENCY_REGISTRY = ROOT / "runtime" / "parallel_dependency_registry.json"
ACTIVE = {"planned", "in_progress", "awaiting_ci", "awaiting_game_test", "blocked"}

INTENT_TO_RISK = {
    "diagnostic": "HOT_DIAGNOSTIC",
    "addon-local": "ADDON_LOCAL",
    "addon-transactional": "ADDON_TRANSACTIONAL",
    "native-single": "NATIVE_SINGLE",
    "native-shared": "NATIVE_SHARED",
    "workflow-infra": "WORKFLOW_INFRA",
}

ANALYSIS_BUDGETS = {
    "HOT_DIAGNOSTIC": {
        "max_module_files_before_first_commit": 2,
        "max_dependency_files_before_first_commit": 1,
        "first_commit_rule": "commit_on_feature_after_packet_and_local_checks_unless_unresolved_risk",
    },
    "ADDON_LOCAL": {
        "max_module_files_before_first_commit": 3,
        "max_dependency_files_before_first_commit": 1,
        "first_commit_rule": "commit_on_feature_after_packet_and_local_checks_unless_unresolved_risk",
    },
    "ADDON_TRANSACTIONAL": {
        "max_module_files_before_first_commit": 5,
        "max_dependency_files_before_first_commit": 2,
        "first_commit_rule": "inspect_transaction_and_ownership_boundary_before_first_commit",
    },
    "NATIVE_SINGLE": {
        "max_module_files_before_first_commit": 4,
        "max_dependency_files_before_first_commit": 2,
        "first_commit_rule": "inspect_abi_hook_and_build_recipe_before_first_commit",
    },
    "NATIVE_SHARED": {
        "max_module_files_before_first_commit": 8,
        "max_dependency_files_before_first_commit": 4,
        "first_commit_rule": "inspect_shared_hooks_load_order_and_arbitration_before_first_commit",
    },
    "WORKFLOW_INFRA": {
        "max_module_files_before_first_commit": 6,
        "max_dependency_files_before_first_commit": 4,
        "first_commit_rule": "inspect_contract_and_control_plane_files_touched_by_the_change",
    },
}


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


def compact_ledger_experiment(exp):
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


def compact_index_experiment(ident, row):
    pkg = row.get("package")
    return {
        "id": ident,
        "branch": row["branch"],
        "status": row["status"],
        "observed_head": row.get("observed_head"),
        "verified_commit": row.get("verified_commit"),
        "dependencies": list(row.get("dependencies", [])),
        "artifact_id": pkg.get("artifact_id") if isinstance(pkg, dict) else None,
    }


def routing_from_index(module, limit):
    data = load_json(INDEX)
    if data.get("schema_version") != 1:
        raise ValueError("unsupported compact experiment index schema")
    experiments = data.get("experiments")
    modules = data.get("modules")
    if not isinstance(experiments, dict) or not isinstance(modules, dict):
        raise ValueError("compact experiment index is structurally invalid")
    active_ids = list(modules.get(module, {}).get("active", []))
    rows = []
    for ident in active_ids:
        row = experiments.get(ident)
        if not isinstance(row, dict):
            raise ValueError("compact experiment index references missing experiment " + ident)
        if row.get("status") in ACTIVE:
            rows.append(compact_index_experiment(ident, row))
    return rows[:limit]


def routing_from_ledger(module, limit):
    ledger = load_json(LEDGER)
    active = [
        exp for exp in ledger.get("experiments", [])
        if exp.get("status") in ACTIVE and module in exp.get("modules", [])
    ]
    return [compact_ledger_experiment(exp) for exp in reversed(active)[:limit]]


def routing_rows(module, limit):
    try:
        return routing_from_index(module, limit), "runtime/ai_experiment_index.json", False
    except (OSError, KeyError, ValueError, json.JSONDecodeError):
        return routing_from_ledger(module, limit), "runtime/ai_experiments.json", True


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

    needle = "/" + module.lower() + "/"
    for item in runtime.get("active_dlls", []):
        source = item.get("source_path")
        if source and needle in ("/" + source.lower()):
            add(source)

    for item in parallel.get("companions", []) + parallel.get("replacements", []):
        for source in item.get("sources", []):
            if needle in ("/" + source.lower()):
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


def normalized(path):
    return str(path).replace("\\", "/").lstrip("./")


def path_overlaps(a, b):
    a = normalized(a).rstrip("/")
    b = normalized(b).rstrip("/")
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def delivery_profiles(module, hints, economy, policy):
    profiles = []
    if economy_eligible(module, economy):
        profiles.append("economy")
    for name, config in policy.get("delivery_profiles", {}).items():
        if name in profiles:
            continue
        for required in config.get("required_paths", []):
            if any(path_overlaps(hint, required) for hint in hints):
                profiles.append(name)
                break
    return profiles


def ownership_context(module, hints, registry):
    records = []
    module_lc = module.lower()
    for hook in registry.get("hooks", []):
        owners = []
        for owner in hook.get("owners", []):
            paths = [
                owner.get("source"),
                owner.get("supporting_source"),
                owner.get("embedded_source"),
                owner.get("movement_adapter"),
                owner.get("embedded_adapter"),
            ]
            paths = [path for path in paths if path]
            owner_module = str(owner.get("module", ""))
            if module_lc in owner_module.lower() or any(
                path_overlaps(hint, path) for hint in hints for path in paths
            ):
                owners.append({
                    "module": owner_module,
                    "sources": paths,
                })
        if owners:
            records.append({
                "resource": hook.get("resource"),
                "policy": hook.get("policy"),
                "owners": owners,
            })
    return records


def classify_risk(module, intent, hints, parallel, ownership):
    if intent != "auto":
        return INTENT_TO_RISK[intent]

    if module.lower().startswith("ai") or module in {"Updater", "Loader"}:
        return "WORKFLOW_INFRA"

    if module in parallel.get("addons", {}).get("roots", []):
        return "ADDON_LOCAL"

    native_sources = [path for path in hints if path.lower().endswith((".c", ".cpp", ".cc"))]
    if native_sources:
        return "NATIVE_SHARED" if len(native_sources) > 1 or ownership else "NATIVE_SINGLE"

    # Unknown scope fails conservatively toward broader analysis.
    return "NATIVE_SHARED"


def edit_scope(hints):
    exact_files = [path for path in hints if Path(path).suffix]
    roots = [path for path in hints if not Path(path).suffix]
    return {
        "exact_files": exact_files,
        "editable_roots": roots,
        "scope_expansion_required": bool(roots),
        "rule": "do_not_expand_beyond_this_scope_without_a_concrete_unresolved_risk",
    }


def build_context(module, branch="parallel", limit=6, head=None, intent="auto"):
    if not module or any(c.isspace() for c in module):
        raise ValueError("module must be a non-empty token")
    if limit < 1 or limit > 20:
        raise ValueError("limit must be in range 1..20")
    if intent not in {"auto"} | set(INTENT_TO_RISK):
        raise ValueError("unsupported intent")

    parallel = load_json(PARALLEL)
    economy = load_json(ECONOMY) if ECONOMY.exists() else {}
    runtime = load_json(RUNTIME)
    policy = load_json(THREAD_POLICY) if THREAD_POLICY.exists() else {}
    dependency_registry = load_json(DEPENDENCY_REGISTRY) if DEPENDENCY_REGISTRY.exists() else {}

    active, routing_source, fallback_used = routing_rows(module, limit)
    hints = source_hints(module, runtime, parallel)
    ownership = ownership_context(module, hints, dependency_registry)
    eligible = economy_eligible(module, economy)
    profiles = delivery_profiles(module, hints, economy, policy)
    risk_class = classify_risk(module, intent, hints, parallel, ownership)

    branch_active = [exp for exp in active if exp.get("branch") == branch]
    feature_active = [
        exp for exp in active if str(exp.get("branch", "")).startswith("feature/")
    ]

    hot_policy = policy.get("diagnostic_hotfix_fast_path", {})
    hot_required_profiles = set(hot_policy.get("required_delivery_profiles", []))
    diagnostic_fastpath_potential = (
        risk_class == "HOT_DIAGNOSTIC"
        and module in hot_policy.get("allowed_modules", [])
        and hot_required_profiles.issubset(set(profiles))
    )

    workflows = {
        "feature_preflight": ".github/workflows/parallel_feature_preflight.yml",
        "parallel_candidate": parallel.get("workflow"),
        "economy": (
            economy.get("delivery", {}).get("workflow") if eligible else None
        ),
        "delivery_profiles": {
            name: policy.get("delivery_profiles", {}).get(name, {}).get("workflow")
            for name in profiles
        },
    }
    lifecycle = []
    if branch == "parallel":
        lifecycle = [
            "feature_exact_sha_preflight_pass",
            "serialized_cas_integration_into_current_parallel",
        ]
        if diagnostic_fastpath_potential:
            lifecycle.append("post_integration_standard_or_policy_fastpath")
        else:
            lifecycle.append("parallel_exact_sha_standard_pass")
        for profile in profiles:
            lifecycle.append("parallel_exact_sha_%s_pass" % profile)
        lifecycle.append("test_ready_exact_sha_artifact")

    return {
        "schema_version": 2,
        "module": module,
        "intent": intent,
        "risk_class": risk_class,
        "analysis_budget": ANALYSIS_BUDGETS[risk_class],
        "selected_branch": branch,
        "selected_branch_head": head if head is not None else resolve_head(branch),
        "source_hints": hints,
        "edit_scope": edit_scope(hints),
        "ownership": ownership,
        "routing": {
            "source": routing_source,
            "full_ledger_fallback_used": fallback_used,
            "active_count": len(active),
            "active_experiments": active,
            "recent_active": active,
            "selected_branch_active": branch_active,
            "feature_candidates": feature_active,
        },
        "delivery": {
            "economy_eligible": eligible,
            "profiles": profiles,
            "standard_gate": (
                "conditional_policy_check"
                if diagnostic_fastpath_potential else "required"
            ),
            "diagnostic_fastpath_potential": diagnostic_fastpath_potential,
            "diagnostic_fastpath_allowed_payload_paths": (
                list(hot_policy.get("allowed_payload_paths", []))
                if diagnostic_fastpath_potential else []
            ),
            "workflows": workflows,
            "lifecycle": lifecycle,
        },
        "verification": [
            "python tools/verify_current.py",
            "python tools/verify_runtime_artifacts.py",
            "python tools/verify_verified_symbols.py",
        ],
        "authority": {
            "routing_index": "runtime/ai_experiment_index.json",
            "ledger_fallback": "runtime/ai_experiments.json",
            "parallel_manifest": "runtime/parallel_candidate.json",
            "thread_policy": "runtime/parallel_thread_policy.json",
            "dependency_registry": "runtime/parallel_dependency_registry.json",
            "runtime_manifest": "runtime/current.json",
            "live_git_ref_required_before_write": True,
        },
    }


def render_text(ctx):
    budget = ctx["analysis_budget"]
    lines = [
        "AI_TASK_CONTEXT",
        "  module: %s" % ctx["module"],
        "  branch: %s @ %s" % (
            ctx["selected_branch"], ctx["selected_branch_head"] or "<unresolved>"
        ),
        "  intent: %s" % ctx["intent"],
        "  risk: %s" % ctx["risk_class"],
        "  routing source: %s%s" % (
            ctx["routing"]["source"],
            " (ledger fallback)" if ctx["routing"]["full_ledger_fallback_used"] else "",
        ),
        "  sources: %s" % (", ".join(ctx["source_hints"]) or "<inspect module>"),
        "  active experiments: %d" % ctx["routing"]["active_count"],
        "  analysis budget: %d module file(s) + %d dependency file(s) before first commit" % (
            budget["max_module_files_before_first_commit"],
            budget["max_dependency_files_before_first_commit"],
        ),
    ]
    for exp in ctx["routing"]["active_experiments"]:
        lines.append("    - %s | %s | %s" % (exp["id"], exp["branch"], exp["status"]))
    if ctx["ownership"]:
        lines.append("  shared/native ownership:")
        for item in ctx["ownership"]:
            lines.append("    - %s | %s" % (item["resource"], item["policy"]))
    delivery = ctx["delivery"]
    lines.append("  economy eligible: %s" % ("yes" if delivery["economy_eligible"] else "no"))
    lines.append("  delivery profiles: %s" % (", ".join(delivery["profiles"]) or "<none>"))
    lines.append("  standard gate: %s" % delivery["standard_gate"])
    lines.append("  lifecycle: " + " -> ".join(delivery["lifecycle"]))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True)
    parser.add_argument("--branch", default="parallel")
    parser.add_argument("--limit", type=int, default=6)
    parser.add_argument(
        "--intent",
        default="auto",
        choices=["auto"] + sorted(INTENT_TO_RISK),
        help="Optional explicit risk/analysis intent; auto is conservative.",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        ctx = build_context(args.module, args.branch, args.limit, intent=args.intent)
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
