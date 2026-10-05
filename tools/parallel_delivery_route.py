#!/usr/bin/env python3
"""Classify post-integration delivery from the exact feature diff.

The router is intentionally fail-closed.  STANDARD may be omitted only when all
changed paths are either validation-only or covered by delivery profiles already
declared by the task.  Unknown, native-core, shared-build, packaging-control and
mixed changes continue through STANDARD.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROUTING = ROOT / "runtime" / "parallel_delivery_routing.json"
TASK_DIR = ROOT / "runtime" / "parallel_tasks"


def _standard(reason, changed_paths=None, uncovered_paths=None):
    return {
        "require_standard": True,
        "fast_path": False,
        "standard_mode": "standard",
        "reason": reason,
        "changed_paths": sorted(changed_paths or []),
        "profile_covered_paths": [],
        "validation_only_paths": [],
        "uncovered_paths": sorted(uncovered_paths or []),
        "profiles_used": [],
    }


def _matches(path, rule):
    rule = str(rule).replace("\\", "/")
    return path.startswith(rule) if rule.endswith("/") else path == rule


def _normalize_paths(paths):
    return sorted({str(path).strip().replace("\\", "/") for path in paths if str(path).strip()})


def classify(task, config, task_id, changed_paths):
    changed = _normalize_paths(changed_paths)
    if not changed:
        return _standard("empty_diff")
    if not isinstance(config, dict) or config.get("schema_version") != 1:
        return _standard("routing_policy_invalid", changed, changed)

    validation_rules = config.get("validation_only_paths")
    coverage = config.get("profile_coverage")
    if not isinstance(validation_rules, list) or not isinstance(coverage, dict):
        return _standard("routing_policy_invalid", changed, changed)

    declared = {
        str(profile).strip()
        for profile in (task.get("delivery_profiles") or [])
        if str(profile).strip()
    }
    task_path = "runtime/parallel_tasks/" + task_id + ".json"

    validation_only = []
    profile_covered = []
    uncovered = []
    profiles_used = set()

    for path in changed:
        if path == task_path or any(_matches(path, rule) for rule in validation_rules):
            validation_only.append(path)
            continue

        path_profiles = []
        for profile in sorted(declared):
            rules = coverage.get(profile)
            if not isinstance(rules, list):
                continue
            if any(_matches(path, rule) for rule in rules):
                path_profiles.append(profile)

        if path_profiles:
            profile_covered.append(path)
            profiles_used.update(path_profiles)
        else:
            uncovered.append(path)

    if uncovered:
        result = _standard("uncovered_or_mixed_paths", changed, uncovered)
        result["profile_covered_paths"] = profile_covered
        result["validation_only_paths"] = validation_only
        result["profiles_used"] = sorted(profiles_used)
        return result

    reason = "profile_contained" if profile_covered else "validation_only"
    return {
        "require_standard": False,
        "fast_path": True,
        "standard_mode": "none",
        "reason": reason,
        "changed_paths": changed,
        "profile_covered_paths": profile_covered,
        "validation_only_paths": validation_only,
        "uncovered_paths": [],
        "profiles_used": sorted(profiles_used),
    }


def _git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True)


def _changed_paths(base):
    merge_base = _git("merge-base", base, "HEAD").strip()
    raw = _git("diff", "--name-only", merge_base, "HEAD")
    return merge_base, _normalize_paths(raw.splitlines())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", default="origin/parallel")
    ap.add_argument("--branch", required=True)
    ap.add_argument("--task-id", required=True)
    args = ap.parse_args()

    try:
        config = json.loads(ROUTING.read_text(encoding="utf-8"))
        task_path = TASK_DIR / (args.task_id + ".json")
        if not task_path.is_file():
            result = _standard("task_record_missing")
        else:
            task = json.loads(task_path.read_text(encoding="utf-8"))
            if task.get("id") != args.task_id or task.get("branch") != args.branch:
                result = _standard("task_identity_mismatch")
            else:
                merge_base, changed = _changed_paths(args.base)
                result = classify(task, config, args.task_id, changed)
                result["merge_base"] = merge_base
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError, TypeError) as exc:
        # Classifier errors may never create a shortcut.  A valid STANDARD result
        # lets the serialized queue continue safely instead of failing open.
        result = _standard("classifier_error:" + type(exc).__name__)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0


if __name__ == "__main__":
    sys.exit(main())
