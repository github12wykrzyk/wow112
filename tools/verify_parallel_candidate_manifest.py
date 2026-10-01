#!/usr/bin/env python3
"""Validate the declarative inventory for the parallel aggregate candidate."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime/parallel_candidate.json"

def fail(message):
    print("PARALLEL_CANDIDATE_MANIFEST: FAIL:", message, file=sys.stderr)
    raise SystemExit(1)

def require(condition, message):
    if not condition:
        fail(message)

def rel_exists(path):
    return (ROOT / path).is_file()

def main():
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    require(data.get("schema_version") == 1, "unsupported schema")
    require(data.get("branch") == "parallel", "branch must be parallel")

    base_path = data.get("base_loader_manifest")
    require(isinstance(base_path, str) and rel_exists(base_path), "missing base loader manifest")
    base = data.get("base_dlls")
    require(isinstance(base, list) and base and len(base) == len(set(base)), "base_dlls must be unique")
    require(all(isinstance(x, str) and x.lower().endswith(".dll") for x in base), "invalid base DLL name")
    actual = [x.strip() for x in (ROOT / base_path).read_text(encoding="utf-8").splitlines() if x.strip()]
    require(actual == base, "runtime/work_base_dlls.txt differs from parallel_candidate.json")

    replacements = data.get("replacements")
    companions = data.get("companions")
    require(isinstance(replacements, list), "replacements must be a list")
    require(isinstance(companions, list), "companions must be a list")

    seen = set()
    for section, entries in (("replacement", replacements), ("companion", companions)):
        for item in entries:
            name = item.get("runtime_name")
            builder = item.get("builder")
            sources = item.get("sources")
            require(isinstance(name, str) and name.lower().endswith(".dll"), f"invalid {section} runtime_name")
            require(name not in seen, f"duplicate candidate module: {name}")
            seen.add(name)
            if section == "replacement":
                require(name in base, f"replacement is not a base DLL: {name}")
            else:
                require(name not in base, f"companion duplicates base DLL: {name}")
            require(isinstance(builder, str) and rel_exists(builder), f"missing builder for {name}: {builder}")
            require(isinstance(sources, list) and sources, f"missing sources for {name}")
            for source in sources:
                require(isinstance(source, str) and rel_exists(source), f"missing source for {name}: {source}")

    addons = data.get("addons")
    require(isinstance(addons, dict), "addons must be an object")
    require(rel_exists(addons.get("packager", "")), "addon packager missing")
    roots = addons.get("roots")
    require(isinstance(roots, list) and roots and len(roots) == len(set(roots)), "invalid addon roots")
    for addon in roots:
        require((ROOT / "src/AddOns" / addon).is_dir() or (ROOT / "src/LazyScript/upstream/Addons" / addon).is_dir(),
                f"addon root missing: {addon}")

    external = addons.get("external", [])
    require(isinstance(external, list), "external addons must be a list")
    external_destinations = set()
    for item in external:
        require(isinstance(item, dict), "external addon entry must be an object")
        name = item.get("name")
        repository = item.get("repository")
        commit = item.get("commit")
        destination = item.get("destination")
        require(all(isinstance(x, str) and x for x in (name, repository, commit, destination)),
                "external addon entry missing fields")
        require(len(commit) == 40 and all(c in "0123456789abcdefABCDEF" for c in commit),
                f"external addon commit must be full SHA: {name}")
        key = destination.lower()
        require(key not in external_destinations, f"duplicate external addon destination: {destination}")
        require(key not in set(x.lower() for x in roots), f"external addon collides with repo addon: {destination}")
        external_destinations.add(key)

    workflow_path = data.get("workflow")
    require(isinstance(workflow_path, str) and rel_exists(workflow_path), "candidate workflow missing")
    workflow = (ROOT / workflow_path).read_text(encoding="utf-8")
    for item in replacements + companions:
        require(item["builder"] in workflow, f"workflow does not reference builder: {item['builder']}")
    for gate in data.get("gates", []):
        require(isinstance(gate, str) and rel_exists(gate), f"gate missing: {gate}")
        require(gate in workflow or gate in (
            "tools/verify_current.py",
            "tools/verify_runtime_artifacts.py",
            "tools/verify_verified_symbols.py",
        ), f"workflow does not reference gate: {gate}")
    for tool in data.get("comparison_candidates", []):
        require(isinstance(tool, str) and rel_exists(tool), f"comparison builder missing: {tool}")
        require(tool in workflow, f"workflow does not reference comparison builder: {tool}")

    print(
        "PARALLEL_CANDIDATE_MANIFEST: PASS "
        f"(base={len(base)}, replacements={len(replacements)}, companions={len(companions)}, addons={len(roots)})"
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())
