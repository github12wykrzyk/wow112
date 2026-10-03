#!/usr/bin/env python3
"""Validate and summarize concurrency-safe Parallel task coordination records."""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "runtime" / "parallel_thread_policy.json"
TASK_DIR = ROOT / "runtime" / "parallel_tasks"
SHA = re.compile(r"[0-9a-f]{40}\Z")
IDENT = re.compile(r"[a-z0-9][a-z0-9-]{1,79}\Z")
MODULE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,79}\Z")


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
    require(task.get("status") in policy["statuses"], "invalid task status")
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
            "delivery_profiles must be unique strings")
    notes = task.get("notes")
    require(notes is None or isinstance(notes, str), "notes must be a string when present")
    return task


def load_tasks(policy, task_dir=TASK_DIR):
    if not task_dir.exists():
        return []
    tasks = []
    seen = set()
    for path in sorted(task_dir.glob("*.json")):
        task = validate_task(json.loads(path.read_text(encoding="utf-8")), policy, path.name)
        require(task["id"] not in seen, "duplicate task id: " + task["id"])
        seen.add(task["id"])
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
                "base_parallel_sha": task["base_parallel_sha"],
                "shared_resources": list(task["shared_resources"]),
            }
            for task in matches
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    sub.add_parser("summary")
    r = sub.add_parser("route")
    r.add_argument("--module", required=True)
    args = parser.parse_args()
    try:
        policy = load_policy()
        tasks = load_tasks(policy)
        if args.command == "validate":
            print("PARALLEL_TASK_STATE: PASS (%d tasks)" % len(tasks))
        elif args.command == "summary":
            print(json.dumps(summarize(tasks, policy), indent=2, sort_keys=True))
        else:
            print(json.dumps(route(tasks, policy, args.module), indent=2, sort_keys=True))
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("PARALLEL_TASK_STATE: FAIL: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
