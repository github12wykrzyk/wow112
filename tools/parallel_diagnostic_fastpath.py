#!/usr/bin/env python3
"""Fail-closed classifier for the Parallel diagnostic ECONOMY hotfix fast path.

This helper never authorizes arbitrary Lua changes.  It only allows an explicitly
opted-in task to omit the post-integration STANDARD build when the feature diff
is limited to the task record plus an allowlisted AuxEconomyShadow hot-bundle
payload, with no added high-risk auction/ownership/transaction tokens.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "runtime" / "parallel_thread_policy.json"
TASK_DIR = ROOT / "runtime" / "parallel_tasks"


def _standard(reason, changed_paths=None):
    return {
        "require_standard": True,
        "fast_path": False,
        "reason": reason,
        "changed_paths": sorted(changed_paths or []),
    }


def classify(task, config, task_id, changed_paths, added_text_by_path):
    changed = sorted({str(path).replace("\\", "/") for path in changed_paths if str(path).strip()})
    if task.get(config.get("opt_in_field", "diagnostic_hotfix_fast_path")) is not True:
        return _standard("not_opted_in", changed)

    required_profiles = sorted(config.get("required_delivery_profiles") or [])
    declared_profiles = sorted(task.get("delivery_profiles") or [])
    if not required_profiles or declared_profiles != required_profiles:
        return _standard("delivery_profile_mismatch", changed)

    allowed_modules = set(config.get("allowed_modules") or [])
    modules = set(task.get("modules") or [])
    if not modules or not allowed_modules or not modules.issubset(allowed_modules):
        return _standard("module_not_allowlisted", changed)

    payload_paths = set(config.get("allowed_payload_paths") or [])
    task_path = "runtime/parallel_tasks/" + task_id + ".json"
    permitted = payload_paths | {task_path}
    if not changed:
        return _standard("empty_diff", changed)
    if any(path not in permitted for path in changed):
        return _standard("path_not_allowlisted", changed)

    changed_payloads = [path for path in changed if path in payload_paths]
    if not changed_payloads:
        return _standard("no_hot_payload_change", changed)
    if any(not path.endswith(".lua") for path in changed_payloads):
        return _standard("non_lua_payload", changed)

    forbidden = [str(token).lower() for token in (config.get("forbidden_added_tokens") or []) if str(token).strip()]
    if not forbidden:
        return _standard("missing_forbidden_token_policy", changed)
    for path in changed_payloads:
        added = str(added_text_by_path.get(path, "")).lower()
        for token in forbidden:
            if token in added:
                return _standard("forbidden_added_token:" + token, changed)

    return {
        "require_standard": False,
        "fast_path": True,
        "reason": "allowlisted_diagnostic_economy_hotfix",
        "changed_paths": changed,
    }


def _git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True)


def _changed_paths(base):
    merge_base = _git("merge-base", base, "HEAD").strip()
    raw = _git("diff", "--name-only", merge_base, "HEAD")
    changed = sorted({line.strip().replace("\\", "/") for line in raw.splitlines() if line.strip()})
    return merge_base, changed


def _added_text(merge_base, path):
    raw = _git("diff", "--unified=0", "--no-ext-diff", merge_base, "HEAD", "--", path)
    rows = []
    for line in raw.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            rows.append(line[1:])
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", default="origin/parallel")
    ap.add_argument("--branch", required=True)
    ap.add_argument("--task-id", required=True)
    args = ap.parse_args()

    try:
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        config = policy.get("diagnostic_hotfix_fast_path")
        if not isinstance(config, dict):
            result = _standard("policy_missing")
        else:
            task_path = TASK_DIR / (args.task_id + ".json")
            if not task_path.is_file():
                result = _standard("task_record_missing")
            else:
                task = json.loads(task_path.read_text(encoding="utf-8"))
                if task.get("id") != args.task_id or task.get("branch") != args.branch:
                    result = _standard("task_identity_mismatch")
                else:
                    merge_base, changed = _changed_paths(args.base)
                    payload_paths = set(config.get("allowed_payload_paths") or [])
                    added = {path: _added_text(merge_base, path) for path in changed if path in payload_paths}
                    result = classify(task, config, args.task_id, changed, added)
                    result["merge_base"] = merge_base
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError) as exc:
        # Classifier failures must never create a shortcut.  Emit a valid fallback
        # result so the queue can continue through the full STANDARD path.
        print(json.dumps(_standard("classifier_error:" + type(exc).__name__), sort_keys=True, separators=(",", ":")))
        return 0


if __name__ == "__main__":
    sys.exit(main())
