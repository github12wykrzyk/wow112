#!/usr/bin/env python3
"""Source-evidenced, fail-closed audit of explicitly registered PARALLEL hook owners.

This checks documented resource identity, source evidence, load order and export
dependencies; it cannot discover unknown binary hooks or simulate the game.
"""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message):
    raise SystemExit("PARALLEL_DLL_CONFLICT_AUDIT: FAIL: " + message)


def read_source(path):
    p = Path(path)
    if p.is_absolute() or ".." in p.parts or not p.parts or p.parts[0] != "src":
        fail("unsafe or noncanonical evidence path " + str(path))
    f = ROOT / p
    if not f.is_file():
        fail("missing evidence source " + str(path))
    return f.read_text(encoding="utf-8")


def evidence_in(text, fragments, label):
    for fragment in fragments:
        if not fragment or fragment not in text:
            fail(label + ": absent concrete source evidence " + repr(fragment))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="dist/dll_conflict_audit.json")
    args = ap.parse_args()
    registry = json.loads((ROOT / "runtime/parallel_dependency_registry.json").read_text(encoding="utf-8"))
    runtime = json.loads((ROOT / "runtime/current.json").read_text(encoding="utf-8"))
    active = {row["name"]: row["source_path"] for row in runtime["active_dlls"]}
    order = (ROOT / registry["active_loader_manifest"]).read_text(encoding="utf-8").splitlines()
    if registry["schema_version"] != 1 or registry["branch"] != "parallel" or registry["wow_build"] != 5875:
        fail("registry channel/build/schema mismatch")
    if len(order) != len(set(order)) or order != list(active):
        fail("active dlls.txt order differs from runtime/current.json")
    covered = set()
    for hook in registry["hooks"]:
        owners = hook["owners"]
        if not owners or hook["policy"] not in ("exclusive", "ordered_chain", "chainable"):
            fail("unknown ownership policy or empty owners for " + hook["resource"])
        if hook["policy"] == "exclusive" and len(owners) > 1:
            fail("multiple exclusive owners for " + hook["resource"])
        if hook["policy"] == "ordered_chain" and len(owners) < 2:
            fail("ordered chain has fewer than two documented owners")
        modules = [row["module"] for row in owners]
        if len(modules) != len(set(modules)) or any(name not in active for name in modules):
            fail("duplicate or missing hook-owning active module " + hook["resource"])
        for row in owners:
            if active[row["module"]] != row["source"]:
                fail("active source lineage drift for " + row["module"])
            text = read_source(row["source"])
            supporting = row.get("supporting_source")
            if supporting:
                if '#include "' + Path(supporting).name + '"' not in text:
                    fail("supporting movement source no longer included by canonical overlay")
                text += "\n" + read_source(supporting)
            evidence_in(text, row["evidence"], hook["resource"] + "/" + row["module"])
            covered.add(row["module"])
        if hook["policy"] == "ordered_chain":
            positions = [order.index(name) for name in modules]
            if positions != sorted(positions):
                fail("unsafe loader order at " + hook["resource"])
    for writer in registry["arbitrated_writers"]:
        provider, consumer = writer["provider_module"], writer["consumer_module"]
        if provider not in active or active[provider] != writer["provider_source"]:
            fail("missing arbitration provider " + provider)
        provider_source = read_source(writer["provider_source"])
        consumer_source = read_source(writer["consumer_source"])
        evidence_in(consumer_source, writer["consumer_evidence"], consumer)
        for export in writer["required_exports"]:
            evidence_in(provider_source, [export], provider)
            evidence_in(consumer_source, ['GetProcAddress(core,"' + export + '")'], consumer)
        if "if(!core)return 1;" not in consumer_source or "if(!flags)return 1;" not in consumer_source:
            fail("movement writer fails open without its arbitration provider")
        covered.add(provider)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    result = {"schema_version": 1, "result": "PASS", "branch": "parallel", "commit_sha": sha,
              "registered_hooks": len(registry["hooks"]),
              "registered_arbitrated_writers": len(registry["arbitrated_writers"]),
              "covered_active_modules": sorted(covered),
              "unreviewed_active_modules": sorted(set(active) - covered),
              "limitations": registry["exclusions"], "game_runtime_tested": False}
    path = ROOT / args.output
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("PARALLEL_DLL_CONFLICT_AUDIT: PASS (registered source evidence only)")


if __name__ == "__main__":
    main()
