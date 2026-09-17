#!/usr/bin/env python3
"""Verify exact-byte recovery for every active runtime DLL."""

import json
import sys
from pathlib import Path

from exact_runtime_artifacts import load_registry, resolve_exact_bytes

ROOT = Path(__file__).resolve().parents[1]
ERRORS = []


def error(msg):
    ERRORS.append(msg)
    print("ERROR: " + msg)


def load_json(rel):
    try:
        return json.loads((ROOT / rel).read_text(encoding="utf-8"))
    except Exception as exc:
        error(f"cannot load {rel}: {exc}")
        return {}


def main():
    current = load_json("CURRENT.json")
    runtime = load_json(current.get("runtime_manifest", "runtime/current.json"))
    if ERRORS:
        return 1

    try:
        registry, registry_rel = load_registry(current)
    except Exception as exc:
        error(str(exc))
        return 1

    items = runtime.get("active_dlls", [])
    verified = 0
    print(f"Exact-artifact registry: {registry_rel} ({len(registry)} explicit recipes)")

    for item in items:
        if not isinstance(item, dict):
            error("runtime active_dlls contains non-object entry")
            continue
        try:
            _, meta = resolve_exact_bytes(item, current, registry)
        except Exception as exc:
            error(str(exc))
            continue
        verified += 1
        source = meta.get("source")
        if isinstance(source, list):
            source = f"{len(source)} parts"
        print(
            f"OK: {meta['name']} source={meta['source_kind']} encoding={meta['encoding_kind']} "
            f"size={meta['size']} sha256={meta['sha256']} ({source})"
        )

    print("\nRuntime artifact verification summary")
    print(f"  active DLLs: {len(items)}")
    print(f"  verified artifacts: {verified}")
    print(f"  errors: {len(ERRORS)}")
    if ERRORS:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
