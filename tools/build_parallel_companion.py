#!/usr/bin/env python3
"""Compile one declared parallel companion DLL without packaging the aggregate candidate."""
import argparse
import json
import sys
from pathlib import Path

from build_active_module import build_one, sha256_file

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime/parallel_candidate.json"

def fail(message):
    print("PARALLEL_COMPANION_BUILD: FAIL:", message, file=sys.stderr)
    raise SystemExit(1)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="Exact runtime DLL name from parallel_candidate.json companions")
    ap.add_argument("--output", required=True)
    ap.add_argument("--metadata", required=True)
    args = ap.parse_args()

    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    matches = [x for x in data.get("companions", []) if x.get("runtime_name") == args.name]
    if len(matches) != 1:
        fail("unknown or duplicate companion: " + args.name)
    item = matches[0]
    sources = item.get("sources")
    profile = item.get("profile")
    if not isinstance(sources, list) or len(sources) != 1:
        fail("compile-only helper supports exactly one source per companion")
    if not isinstance(profile, str) or not profile:
        fail("missing verified build profile")

    source = ROOT / sources[0]
    if not source.is_file():
        fail("source missing: " + sources[0])
    output = Path(args.output).resolve()
    metadata = Path(args.metadata).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    metadata.parent.mkdir(parents=True, exist_ok=True)
    obj = output.with_suffix(".obj")

    timing, pe = build_one(profile, source, obj, output)
    result = {
        "schema_version": 1,
        "result": "PASS",
        "runtime_name": args.name,
        "source": sources[0],
        "profile": profile,
        "sha256": sha256_file(output),
        "size": output.stat().st_size,
        "pe_machine": pe.get("machine"),
        "entrypoint_rva": pe.get("entrypoint_rva"),
        "timings_ms": timing,
    }
    metadata.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("PARALLEL_COMPANION_BUILD: PASS", args.name, result["sha256"])
    return 0

if __name__ == "__main__":
    sys.exit(main())
