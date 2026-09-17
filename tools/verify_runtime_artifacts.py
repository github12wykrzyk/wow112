#!/usr/bin/env python3
"""Verify exact-byte recovery for every active runtime DLL."""

import hashlib
import json
import lzma
import sys
from pathlib import Path

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

    cache_root = ROOT / (current.get("runtime_binary_cache") or "artifacts/runtime_cache")
    items = runtime.get("active_dlls", [])
    verified = 0

    for item in items:
        if not isinstance(item, dict):
            error("runtime active_dlls contains non-object entry")
            continue

        name = item.get("name", "<unnamed>")
        expected = str(item.get("sha256", "")).lower()
        expected_size = item.get("size")
        if len(expected) != 64:
            error(f"invalid runtime SHA256: {name}")
            continue

        artifact = item.get("binary_artifact")
        source_kind = "content_addressed_cache"
        if isinstance(artifact, dict) and artifact.get("path"):
            rel = artifact.get("path")
            fmt = artifact.get("kind") or artifact.get("format") or "xz"
            source_kind = "runtime_binary_artifact"
            artifact_hash = str(artifact.get("sha256", "")).lower()
            if artifact_hash and artifact_hash != expected:
                error(f"binary_artifact SHA metadata differs from runtime SHA: {name}")
                continue
            artifact_size = artifact.get("size")
            if isinstance(artifact_size, int) and isinstance(expected_size, int) and artifact_size != expected_size:
                error(f"binary_artifact size metadata differs from runtime size: {name}")
                continue
            path = ROOT / rel
        else:
            fmt = "xz"
            path = cache_root / f"{expected}.dll.xz"
            rel = str(path.relative_to(ROOT)).replace("\\", "/")

        if fmt != "xz":
            error(f"unsupported exact artifact format for {name}: {fmt!r}")
            continue
        if not path.is_file():
            error(f"no exact-byte artifact for active DLL: {name} -> {rel}")
            continue

        try:
            data = lzma.decompress(path.read_bytes())
        except Exception as exc:
            error(f"exact artifact XZ decode failed: {name} -> {rel}: {exc}")
            continue

        if not isinstance(expected_size, int) or expected_size <= 0:
            error(f"runtime DLL size metadata invalid: {name}")
            continue
        if len(data) != expected_size:
            error(f"exact artifact size mismatch: {name} got={len(data)} expected={expected_size}")
            continue

        got = hashlib.sha256(data).hexdigest()
        if got != expected:
            error(f"exact artifact hash mismatch: {name} got={got} expected={expected}")
            continue

        verified += 1
        print(f"OK: {name} source={source_kind} size={len(data)} sha256={got}")

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
