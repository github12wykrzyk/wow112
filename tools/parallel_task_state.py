#!/usr/bin/env python3
"""Validate and summarize concurrency-safe Parallel task coordination records."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "runtime" / "parallel_thread_policy.json"
TASK_DIR = ROOT / "runtime" / "parallel_tasks"
SHA = re.compile(r"[0-9a-f]{40}\Z")
IDENT = re.compile(r"[a-z0-9][a-z0-9-]{1,79}\Z")
MODULE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,79}\Z")
PROFILE = re.compile(r"[a-z][a-z0-9-]{1,39}\Z")
RESOLVED_DEPENDENCY_STATUSES = {"integrated", "test_ready", "done"}
HISTORICAL_STATUSES = RESOLVED_DEPENDENCY_STATUSES | {"superseded"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_policy(path=POLICY):
    data = json.loads(path.read_text(encoding="utf-8"))
    require(data.get("schema_version") == 1, "unsupported parallel thread policy schema")
    require(data.get("branch") == "parallel", "parallel thread policy branch mismatch")
    require(data.get("task_dir") == "runtime/parallel_tasks", "parallel task directory mismatch")
    require(data.get("task_branch_prefix") == "feature/", "parallel task branch prefix mismatch")
    statuses = data.get("statuses")
    active = data.get("active_statuses")
    require(isinstance(statuses, list) and statuses and len(set(statuses)) == len(statuses),
            "parallel thread policy statuses must be unique")
    require(isinstance(active, list) and set(active).issubset(set(statuses)),
            "active statuses must be a subset of statuses")
    enforcement = data.get("task_record_enforcement")
    require(isinstance(enforcement, dict), "task_record_enforcement policy is required")
    marker = enforcement.get("marker_path")
    require(enforcement.get("mode") == "merge_base_marker", "unsupported task record enforcement mode")
    require(isinstance(marker, str) and marker.startswith("runtime/") and ".." not in marker,
            "invalid task record enforcement marker_path")
    profiles = data.get("delivery_profiles")
    require(isinstance(profiles, dict) and profiles, "delivery_profiles policy is required")
    for name, config in profiles.items():
        require(isinstance(name, str) and PROFILE.fullmatch(name), "invalid delivery profile name")
        require(isinstance(config, dict), "delivery profile config must be an object")
        workflow = config.get("workflow")
        paths = config.get("required_paths")
        require(isinstance(workflow, str) and workflow.endswith(".yml") and "/" not in workflow,
                "invalid delivery profile workflow for " + name)
        require(isinstance(paths, list) and paths and len(set(paths)) == len(paths)
                and all(isinstance(item, str) and item and ".." not in item for item in paths),
                "invalid required_paths for delivery profile " + name)
    return data


def validate_task(task, policy, filename=None):
    require(task.get("schema_version") == 1, "unsupported task schema")
    ident = task.get("id")
    require(isinstance(ident, str) and IDENT.fullmatch(ident), "invalid task id")
    if filename is not None:
        require(filename == ident + ".json", "task filename must match task id")
    goal = task.get("goal")
    require(isinstance(goal, str) and goal.strip(), "task goal is required")
    branch = task.get("branch")
    prefix = policy["task_branch_prefix"]
    require(isinstance(branch, str) and branch.startswith(prefix)
            and re.fullmatch(r"feature/[a-z0-9/-]+", branch), "invalid feature branch")
    base = task.get("base_parallel_sha")
    require(isinstance(base, str) and SHA.fullmatch(base), "base_parallel_sha must be a full SHA")
    status = task.get("status")
    require(status in policy["statuses"], "invalid task status")
    auto_integrate = task.get("auto_integrate", False)
    require(isinstance(auto_integrate, bool), "auto_integrate must be boolean")
    if auto_integrate:
        require(status == "ready_for_integration",
                "auto_integrate=true requires ready_for_integration status")
    integrated_feature_sha = task.get("integrated_feature_sha")
    if status == "integrated":
        require(isinstance(integrated_feature_sha, str) and SHA.fullmatch(integrated_feature_sha),
                "integrated status requires integrated_feature_sha")
        require(not auto_integrate, "integrated task cannot remain auto_integrate=true")
    elif integrated_feature_sha is not None:
        require(isinstance(integrated_feature_sha, str) and SHA.fullmatch(integrated_feature_sha),
                "integrated_feature_sha must be a full SHA when present")
    modules = task.get("modules")
    require(isinstance(modules, list) and modules and len(set(modules)) == len(modules)
            and all(isinstance(mod, str) and MODULE.fullmatch(mod) for mod in modules),
            "task modules must be unique valid module tokens")
    dependencies = task.get("dependencies")
    require(isinstance(dependencies, list) and len(set(dependencies)) == len(dependencies)
            and all(isinstance(dep, str) and IDENT.fullmatch(dep) for dep in dependencies),
            "task dependencies must be unique task ids")
    resources = task.get("shared_resources")
    require(isinstance(resources, list) and len(set(resources)) == len(resources)
            and all(isinstance(item, str) and item.strip() for item in resources),
            "shared_resources must be unique non-empty strings")
    profiles = task.get("delivery_profiles")
    require(isinstance(profiles, list) and len(set(profiles)) == len(profiles)
            and all(isinstance(item, str) and item.strip() for item in profiles),
            "delivery_profiles must be unique non-empty strings")
    if status not in HISTORICAL_STATUSES:
        supported = set(policy["delivery_profiles"])
        require(all(item in supported for item in profiles),
                "active delivery_profiles must use supported profile names")
    notes = task.get("notes")
    require(notes is None or isinstance(notes, str), "notes must be a string when present")
    return task


def load_tasks(policy, task_dir=TASK_DIR):
    if not task_dir.exists():
        return []
    tasks = []
    seen = set()
    branches = set()
    for path in sorted(task_dir.glob("*.json")):
        task = validate_task(json.loads(path.read_text(encoding="utf-8")), policy, path.name)
        require(task["id"] not in seen, "duplicate task id: " + task["id"])
        require(task["branch"] not in branches, "duplicate task branch: " + task["branch"])
        seen.add(task["id"])
        branches.add(task["branch"])
        tasks.append(task)
    ids = {task["id"] for task in tasks}
    for task in tasks:
        for dep in task["dependencies"]:
            require(dep in ids, "missing task dependency %s for %s" % (dep, task["id"]))
    return tasks


def summarize(tasks, policy):
    active_states = set(policy["active_statuses"])
    active = [task for task in tasks if task["status"] in active_states]
    by_status = {}
    by_module = {}
    by_resource = {}
    for task in active:
        by_status.setdefault(task["status"], []).append(task["id"])
        for module in task["modules"]:
            by_module.setdefault(module, []).append(task["id"])
        for resource in task["shared_resources"]:
            by_resource.setdefault(resource, []).append(task["id"])
    conflicts = {
        resource: sorted(ids)
        for resource, ids in sorted(by_resource.items())
        if len(ids) > 1
    }
    return {
        "schema_version": 1,
        "task_count": len(tasks),
        "active_task_count": len(active),
        "by_status": {key: sorted(value) for key, value in sorted(by_status.items())},
        "by_module": {key: sorted(value) for key, value in sorted(by_module.items())},
        "shared_resource_conflicts": conflicts,
        "integration_note": "Conflicts require ordered integration/arbitration; independent feature development may continue in parallel.",
    }


def route(tasks, policy, module):
    require(isinstance(module, str) and MODULE.fullmatch(module), "invalid module")
    active_states = set(policy["active_statuses"])
    matches = [task for task in tasks if task["status"] in active_states and module in task["modules"]]
    return {
        "module": module,
        "active_tasks": [
            {
                "id": task["id"],
                "branch": task["branch"],
                "status": task["status"],
                "auto_integrate": task.get("auto_integrate", False),
                "base_parallel_sha": task["base_parallel_sha"],
                "shared_resources": list(task["shared_resources"]),
                "delivery_profiles": list(task["delivery_profiles"]),
            }
            for task in matches
        ],
    }


def queue_check(tasks, branch):
    require(isinstance(branch, str) and branch.startswith("feature/"), "queue-check requires feature branch")
    matches = [task for task in tasks if task["branch"] == branch]
    require(len(matches) <= 1, "multiple task records own branch " + branch)
    if not matches:
        return {"eligible": False, "task_id": "", "reason": "no_task_record", "delivery_profiles": []}
    task = matches[0]
    if task["status"] != "ready_for_integration":
        return {"eligible": False, "task_id": task["id"], "reason": "status_" + task["status"], "delivery_profiles": list(task["delivery_profiles"])}
    if not task.get("auto_integrate", False):
        return {"eligible": False, "task_id": task["id"], "reason": "auto_integrate_disabled", "delivery_profiles": list(task["delivery_profiles"])}
    by_id = {item["id"]: item for item in tasks}
    for dep in task["dependencies"]:
        require(dep in by_id, "missing queue dependency " + dep)
        if by_id[dep]["status"] not in RESOLVED_DEPENDENCY_STATUSES:
            return {"eligible": False, "task_id": task["id"], "reason": "dependency_pending_" + dep, "delivery_profiles": list(task["delivery_profiles"])}
    return {"eligible": True, "task_id": task["id"], "reason": "opt_in_ready", "delivery_profiles": list(task["delivery_profiles"])}


def marker_present_at(policy, merge_base):
    require(isinstance(merge_base, str) and SHA.fullmatch(merge_base), "merge-base must be a full SHA")
    marker = policy["task_record_enforcement"]["marker_path"]
    result = subprocess.run(["git", "cat-file", "-e", merge_base + ":" + marker], cwd=ROOT,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def feature_check(tasks, policy, branch, merge_base, marker_present=None):
    require(isinstance(branch, str) and branch.startswith("feature/"), "feature-check requires feature branch")
    if marker_present is None:
        marker_present = marker_present_at(policy, merge_base)
    if not marker_present:
        return {"required": False, "task_id": "", "reason": "legacy_merge_base_without_marker"}
    matches = [task for task in tasks if task["branch"] == branch]
    require(len(matches) == 1,
            "feature %s requires exactly one runtime/parallel_tasks/<task-id>.json record because its merge-base contains the concurrency enforcement marker; found %d" % (branch, len(matches)))
    return {"required": True, "task_id": matches[0]["id"], "reason": "task_record_enforced"}


def path_matches_rule(path, rule):
    path = path.replace("\\", "/")
    rule = rule.replace("\\", "/")
    return path.startswith(rule) if rule.endswith("/") else path == rule


def required_profiles_for_paths(policy, changed_paths):
    required = []
    normalized = sorted({str(path).replace("\\", "/") for path in changed_paths if str(path).strip()})
    for name, config in policy["delivery_profiles"].items():
        if any(path_matches_rule(path, rule) for path in normalized for rule in config["required_paths"]):
            required.append(name)
    return sorted(required)


def profile_check(tasks, policy, branch, merge_base, changed_paths, marker_present=None):
    record = feature_check(tasks, policy, branch, merge_base, marker_present=marker_present)
    if not record["required"]:
        return {"required": False, "task_id": "", "required_profiles": [], "declared_profiles": [], "reason": record["reason"]}
    task = next(item for item in tasks if item["id"] == record["task_id"])
    required_profiles = required_profiles_for_paths(policy, changed_paths)
    declared = sorted(task["delivery_profiles"])
    missing = sorted(set(required_profiles) - set(declared))
    require(not missing,
            "feature %s touches profile-routed paths but task %s is missing delivery_profiles: %s" % (branch, task["id"], ",".join(missing)))
    return {"required": True, "task_id": task["id"], "required_profiles": required_profiles,
            "declared_profiles": declared, "reason": "profile_routes_satisfied"}


def mark_integrated(tasks, policy, task_id, feature_sha, task_dir=TASK_DIR):
    require(isinstance(feature_sha, str) and SHA.fullmatch(feature_sha), "feature_sha must be a full SHA")
    matches = [task for task in tasks if task["id"] == task_id]
    require(len(matches) == 1, "cannot resolve task for integration: " + task_id)
    task = dict(matches[0])
    require(task["status"] == "ready_for_integration", "mark-integrated requires ready_for_integration task")
    require(task.get("auto_integrate", False), "mark-integrated requires auto_integrate=true task")
    task["status"] = "integrated"
    task["auto_integrate"] = False
    task["integrated_feature_sha"] = feature_sha
    validate_task(task, policy, task_id + ".json")
    path = Path(task_dir) / (task_id + ".json")
    path.write_text(json.dumps(task, indent=2) + "\n", encoding="utf-8")
    return task


def write_github_output(path, result):
    lines = ["eligible=" + ("true" if result["eligible"] else "false"),
             "task_id=" + result["task_id"], "reason=" + result["reason"],
             "delivery_profiles=" + ",".join(result.get("delivery_profiles", []))]
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    sub.add_parser("summary")
    r = sub.add_parser("route"); r.add_argument("--module", required=True)
    q = sub.add_parser("queue-check"); q.add_argument("--branch", required=True); q.add_argument("--github-output")
    f = sub.add_parser("feature-check"); f.add_argument("--branch", required=True); f.add_argument("--merge-base", required=True)
    p = sub.add_parser("profile-check"); p.add_argument("--branch", required=True); p.add_argument("--merge-base", required=True); p.add_argument("--changed-json", required=True)
    m = sub.add_parser("mark-integrated"); m.add_argument("--task-id", required=True); m.add_argument("--feature-sha", required=True)
    args = parser.parse_args()
    try:
        policy = load_policy(); tasks = load_tasks(policy)
        if args.command == "validate":
            print("PARALLEL_TASK_STATE: PASS (%d tasks)" % len(tasks))
        elif args.command == "summary":
            print(json.dumps(summarize(tasks, policy), indent=2, sort_keys=True))
        elif args.command == "route":
            print(json.dumps(route(tasks, policy, args.module), indent=2, sort_keys=True))
        elif args.command == "queue-check":
            result = queue_check(tasks, args.branch)
            if args.github_output: write_github_output(args.github_output, result)
            print(json.dumps(result, sort_keys=True))
        elif args.command == "feature-check":
            print(json.dumps(feature_check(tasks, policy, args.branch, args.merge_base), sort_keys=True))
        elif args.command == "profile-check":
            changed = json.loads(args.changed_json); require(isinstance(changed, list), "changed-json must decode to a list")
            print(json.dumps(profile_check(tasks, policy, args.branch, args.merge_base, changed), sort_keys=True))
        else:
            task = mark_integrated(tasks, policy, args.task_id, args.feature_sha)
            print(json.dumps({"task_id": task["id"], "status": task["status"], "integrated_feature_sha": task["integrated_feature_sha"]}, sort_keys=True))
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("PARALLEL_TASK_STATE: FAIL: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
