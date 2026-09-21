#!/usr/bin/env python3
"""AI experiment ledger and deterministic branch-routing advice (no Git writes)."""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "runtime" / "ai_experiments.json"
SHA = re.compile(r"[0-9a-f]{40}\Z")
MODULE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,79}\Z")
ACTIVE = {"planned", "in_progress", "awaiting_ci", "awaiting_game_test", "blocked"}
STATES = ACTIVE | {"accepted", "rejected", "archived"}
RESULTS = {"passed", "failed", "inconclusive"}


def require(condition, description):
    if not condition:
        raise ValueError(description)


def validate(data):
    require(data.get("schema_version") == 1, "unsupported registry schema")
    require(data.get("repository") == "github12wykrzyk/wow112", "wrong repository")
    require(data.get("branches", {}).get("stable") == "main", "stable branch mismatch")
    require(data["branches"].get("development") == ["work", "parallel"], "development branch mismatch")
    require(data["branches"].get("feature_prefix") == "feature/", "feature branch pattern mismatch")
    require(data["branches"].get("promotion_prefix") == "promote/", "promotion branch pattern mismatch")
    entries = data.get("experiments")
    require(isinstance(entries, list), "experiments must be a list")
    ids = set()
    for exp in entries:
        ident = exp.get("id")
        require(isinstance(ident, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{1,79}", ident)
                and ident not in ids, "invalid or duplicate experiment id")
        ids.add(ident)
        branch = exp.get("branch", "")
        require(branch in ("work", "parallel") or
                (branch.startswith("feature/") and re.fullmatch(r"feature/[a-z0-9/-]+", branch)),
                "invalid experiment branch for " + ident)
        require(exp.get("status") in STATES, "invalid status for " + ident)
        mods = exp.get("modules")
        require(isinstance(mods, list) and mods and len(set(mods)) == len(mods)
                and all(isinstance(mod, str) and MODULE.fullmatch(mod) for mod in mods),
                "invalid modules for " + ident)
        for key in ("dependencies", "shared_resources", "tests"):
            require(isinstance(exp.get(key), list), "missing array " + key + " for " + ident)
        require(len(exp["dependencies"]) == len(set(exp["dependencies"])), "duplicate dependencies")
        for key in ("observed_head", "verified_commit"):
            val = exp.get(key)
            require(val is None or (isinstance(val, str) and SHA.fullmatch(val)),
                    "invalid SHA in " + key + " for " + ident)
        pkg = exp.get("package")
        require(pkg is None or (isinstance(pkg, dict) and pkg.get("verified") is True
                and isinstance(pkg.get("commit"), str) and SHA.fullmatch(pkg["commit"])
                and isinstance(pkg.get("artifact_id"), int) and pkg["artifact_id"] > 0),
                "only exact-SHA verified packages may be entered for " + ident)
        for event in exp["tests"]:
            require(event.get("kind") in ("ci", "game", "binary", "package")
                    and event.get("result") in RESULTS
                    and isinstance(event.get("commit"), str) and SHA.fullmatch(event["commit"])
                    and isinstance(event.get("date"), str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", event["date"])
                    and isinstance(event.get("evidence"), str) and event["evidence"].strip(),
                    "test record must identify kind, result, exact SHA, date and evidence")
    graph = {entry["id"]: entry["dependencies"] for entry in entries}
    visited, stack = set(), set()

    def walk(node):
        require(node not in stack, "dependency cycle at " + node)
        if node in visited:
            return
        stack.add(node)
        for dep in graph[node]:
            require(dep in graph and dep != node, "missing or self dependency for " + node)
            walk(dep)
        stack.remove(node)
        visited.add(node)

    for ident in graph:
        walk(ident)
    return entries


def route(entries, module, explicit=None):
    require(bool(MODULE.fullmatch(module)), "invalid module")
    require(explicit is None or explicit in ("work", "parallel") or
            (explicit.startswith("feature/") and re.fullmatch(r"feature/[a-z0-9/-]+", explicit)),
            "invalid selected branch (main/promote not allowed)")
    active = [e for e in entries if e["status"] in ACTIVE and module in e["modules"]]
    if explicit:
        matching = [e["id"] for e in active if e["branch"] == explicit]
        return {"decision": "continue_existing" if len(matching) == 1 else "inspect_explicit_branch",
                "branch": explicit, "experiments": matching}
    if len(active) == 1:
        return {"decision": "continue_existing", "branch": active[0]["branch"],
                "experiments": [active[0]["id"]]}
    if len(active) > 1:
        return {"decision": "ambiguous", "branch": None,
                "experiments": [e["id"] for e in active]}
    slug = re.sub(r"[^a-z0-9-]", "-", module.lower()).strip("-")
    return {"decision": "new_feature", "branch": None, "suggested_branch": "feature/" + slug,
            "possible_base": "work", "experiments": []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    r = sub.add_parser("route")
    r.add_argument("--module", required=True)
    r.add_argument("--branch", help="Explicit user-selected development branch")
    t = sub.add_parser("record-test")
    t.add_argument("--experiment", required=True)
    t.add_argument("--kind", choices=("ci", "game", "binary", "package"), required=True)
    t.add_argument("--result", choices=sorted(RESULTS), required=True)
    t.add_argument("--commit", required=True)
    t.add_argument("--date", required=True)
    t.add_argument("--evidence", required=True)
    t.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        data = json.loads(LEDGER.read_text(encoding="utf-8"))
        entries = validate(data)
        if args.command == "validate":
            print("AI_EXPERIMENTS: PASS (" + str(len(entries)) + " experiments)")
        elif args.command == "route":
            print(json.dumps(route(entries, args.module, args.branch), sort_keys=True))
        else:
            matches = [e for e in entries if e["id"] == args.experiment]
            require(len(matches) == 1, "unknown experiment")
            require(bool(SHA.fullmatch(args.commit)), "full exact commit SHA required")
            require(bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date)), "ISO date required")
            require(bool(args.evidence.strip()), "evidence is required")
            event = {"kind": args.kind, "result": args.result, "commit": args.commit,
                     "date": args.date, "evidence": args.evidence.strip()}
            require(event not in matches[0]["tests"], "duplicate evidence record")
            matches[0]["tests"].append(event)
            args.output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            print("AI_EXPERIMENTS: evidence staged locally, not committed or independently verified")
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print("AI_EXPERIMENTS: FAIL: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
