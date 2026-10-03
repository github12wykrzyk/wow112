#!/usr/bin/env python3
"""Live control-plane reconciliation for Parallel feature tasks and leases."""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import parallel_task_state as pts

ROOT = Path(__file__).resolve().parents[1]


def run_git(args, check=True):
    proc = subprocess.run(["git"] + list(args), cwd=ROOT, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode != 0:
        raise ValueError("git %s failed: %s" % (" ".join(args), proc.stderr.strip()))
    return proc.stdout


def resolve_commit(ref):
    value = run_git(["rev-parse", "--verify", ref]).strip()
    pts.require(bool(pts.SHA.fullmatch(value)), "cannot resolve full SHA for " + ref)
    return value


def merge_base(feature_ref, base_ref):
    value = run_git(["merge-base", feature_ref, base_ref]).strip()
    pts.require(bool(pts.SHA.fullmatch(value)), "cannot resolve merge-base")
    return value


def ref_has_path(commit, path):
    proc = subprocess.run(["git", "cat-file", "-e", commit + ":" + path], cwd=ROOT,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc.returncode == 0


def branch_task_records(commit, policy, branch):
    prefix = policy["task_dir"].rstrip("/") + "/"
    names = run_git(["ls-tree", "-r", "--name-only", commit, prefix], check=False).splitlines()
    rows = []
    for name in names:
        if not name.startswith(prefix) or not name.endswith(".json"):
            continue
        raw = run_git(["show", commit + ":" + name])
        data = json.loads(raw)
        if data.get("branch") != branch:
            continue
        task = pts.validate_task(data, policy, Path(name).name)
        rows.append(task)
    return rows


def remote_feature_refs(policy):
    prefix = policy["reconciler"]["remote_ref_prefix"]
    raw = run_git(["for-each-ref", "--format=%(refname) %(objectname)", prefix], check=False)
    rows = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        ref, sha = line.split(None, 1)
        if not pts.SHA.fullmatch(sha):
            continue
        short = ref[len(prefix):]
        branch = "feature/" + short
        rows.append({"ref": ref, "branch": branch, "sha": sha})
    return sorted(rows, key=lambda row: row["branch"])


def pick_task_for_branch(records, branch):
    matches = [task for task in records if task.get("branch") == branch]
    pts.require(len(matches) <= 1, "multiple task records own branch " + branch)
    return matches[0] if matches else None


def lease_priority(task):
    lease = task.get("lease")
    if not isinstance(lease, dict):
        return ("9999-12-31T23:59:59Z", task["branch"], task["id"])
    return (lease.get("acquired_at", "9999-12-31T23:59:59Z"), task["branch"], task["id"])


def reconcile(policy, now=None):
    now = now or pts.utc_now()
    active_states = set(policy["active_statuses"])
    required_states = set(policy["lease_policy"]["required_statuses"])
    rows = []
    live_scope_owners = {}

    for item in remote_feature_refs(policy):
        records = branch_task_records(item["sha"], policy, item["branch"])
        task = pick_task_for_branch(records, item["branch"])
        if task is None:
            rows.append({
                "branch": item["branch"], "sha": item["sha"], "task_id": None,
                "status": "untracked", "lease_state": "missing", "owner": None,
                "scopes": [], "expires_at": None,
            })
            continue
        state = pts.lease_state(task, policy, now)
        row = {
            "branch": item["branch"], "sha": item["sha"], "task_id": task["id"],
            "status": task["status"], "lease_state": state["state"],
            "owner": state.get("owner"), "scopes": state.get("scopes", []),
            "expires_at": state.get("expires_at"),
            "requires_lease": task["status"] in required_states,
            "auto_integrate": task.get("auto_integrate", False),
            "delivery_profiles": list(task.get("delivery_profiles", [])),
            "modules": list(task.get("modules", [])),
            "shared_resources": list(task.get("shared_resources", [])),
        }
        rows.append(row)
        if task["status"] in active_states and state["state"] == "active":
            for scope in state["scopes"]:
                live_scope_owners.setdefault(scope, []).append(task)

    winners = {}
    conflicts = {}
    for scope, tasks in sorted(live_scope_owners.items()):
        if len(tasks) < 2:
            winners[scope] = tasks[0]["id"]
            continue
        ordered = sorted(tasks, key=lease_priority)
        winners[scope] = ordered[0]["id"]
        conflicts[scope] = {
            "winner": ordered[0]["id"],
            "contenders": [task["id"] for task in ordered],
            "policy": "oldest_live_lease_then_branch_then_task_id",
        }

    stale = []
    missing_required = []
    for row in rows:
        if row.get("task_id") is None:
            continue
        if row.get("requires_lease") and row["lease_state"] != "active":
            missing_required.append(row["task_id"])
        if row["lease_state"] == "expired":
            stale.append(row["task_id"])

    return {
        "schema_version": 1,
        "generated_at": pts.utc_text(now),
        "feature_branch_count": len(rows),
        "tracked_task_count": sum(1 for row in rows if row.get("task_id")),
        "active_lease_count": sum(1 for row in rows if row.get("lease_state") == "active"),
        "expired_lease_count": len(stale),
        "missing_required_lease_count": len(missing_required),
        "scope_conflict_count": len(conflicts),
        "scope_winners": winners,
        "scope_conflicts": conflicts,
        "stale_tasks": sorted(stale),
        "missing_required_leases": sorted(missing_required),
        "tasks": rows,
    }


def branch_gate(report, branch, feature_commit, merge_base_sha, policy):
    lease_marker = policy["lease_policy"]["marker_path"]
    if not ref_has_path(merge_base_sha, lease_marker):
        return {
            "allowed": True, "branch": branch, "task_id": None,
            "reason": "legacy_merge_base_without_control_plane_marker",
            "merge_base": merge_base_sha,
        }

    rows = [row for row in report["tasks"] if row["branch"] == branch and row["sha"] == feature_commit]
    pts.require(len(rows) == 1, "control plane could not resolve exactly one live row for " + branch)
    row = rows[0]
    pts.require(row.get("task_id"), "feature branch has no task coordination record: " + branch)

    if row.get("requires_lease"):
        pts.require(row["lease_state"] == "active",
                    "task %s has no active lease; claim/heartbeat before preflight" % row["task_id"])
        for scope in row.get("scopes", []):
            winner = report["scope_winners"].get(scope)
            pts.require(winner in (None, row["task_id"]),
                        "lease scope %s currently belongs to %s; %s must wait or use a non-conflicting scope"
                        % (scope, winner, row["task_id"]))

    return {
        "allowed": True, "branch": branch, "task_id": row["task_id"],
        "reason": "control_plane_gate_pass", "merge_base": merge_base_sha,
        "lease_state": row["lease_state"], "owner": row.get("owner"),
        "scopes": row.get("scopes", []),
    }


def write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def markdown_summary(report):
    lines = [
        "# Parallel Control Plane",
        "",
        "- feature branches: %d" % report["feature_branch_count"],
        "- tracked tasks: %d" % report["tracked_task_count"],
        "- active leases: %d" % report["active_lease_count"],
        "- expired leases: %d" % report["expired_lease_count"],
        "- missing required leases: %d" % report["missing_required_lease_count"],
        "- live scope conflicts: %d" % report["scope_conflict_count"],
    ]
    if report["scope_conflicts"]:
        lines += ["", "## Scope conflicts"]
        for scope, item in sorted(report["scope_conflicts"].items()):
            lines.append("- `%s`: winner `%s`; contenders %s" %
                         (scope, item["winner"], ", ".join("`%s`" % x for x in item["contenders"])))
    if report["stale_tasks"]:
        lines += ["", "## Expired leases", "- " + ", ".join("`%s`" % x for x in report["stale_tasks"])]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    rec = sub.add_parser("reconcile")
    rec.add_argument("--output")
    rec.add_argument("--summary-output")

    gate = sub.add_parser("gate")
    gate.add_argument("--branch", required=True)
    gate.add_argument("--base", default="origin/parallel")
    gate.add_argument("--output")

    args = parser.parse_args()
    try:
        policy = pts.load_policy()
        report = reconcile(policy)
        if args.command == "reconcile":
            if args.output:
                write_json(args.output, report)
            if args.summary_output:
                Path(args.summary_output).write_text(markdown_summary(report), encoding="utf-8")
            print(json.dumps(report, indent=2, sort_keys=True))
        else:
            feature_ref = "HEAD"
            feature_commit = resolve_commit(feature_ref)
            base_commit = resolve_commit(args.base)
            mb = merge_base(feature_ref, args.base)
            result = branch_gate(report, args.branch, feature_commit, mb, policy)
            result["base_commit"] = base_commit
            result["feature_commit"] = feature_commit
            if args.output:
                write_json(args.output, result)
            print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("PARALLEL_CONTROL_PLANE: FAIL: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
