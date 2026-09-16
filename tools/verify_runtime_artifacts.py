#!/usr/bin/env python3
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


def main():
    runtime_path = ROOT / "runtime/current.json"
    try:
        runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
    except Exception as exc:
        error(f"cannot load runtime/current.json: {exc}")
        return 1

    items = runtime.get("active_dlls", [])
    verified = 0

    for item in items:
        if not isinstance(item, dict):
            error("runtime active_dlls contains non-object entry")
            continue

        name = item.get("name", "<unnamed>")
        expected = str(item.get("sha256", "")).lower()
        artifact = item.get("binary_artifact")
        if not isinstance(artifact, dict):
            error(f"active DLL missing binary_artifact: {name}")
            continue
        if artifact.get("kind") != "xz":
            error(f"unsupported binary_artifact kind for {name}: {artifact.get('kind')!r}")
            continue

        rel = artifact.get("path")
        if not rel:
            error(f"binary_artifact path missing: {name}")
            continue
        if str(artifact.get("sha256", "")).lower() != expected:
            error(f"binary_artifact SHA metadata differs from runtime SHA: {name}")
            continue

        path = ROOT / rel
        if not path.is_file():
            error(f"binary_artifact missing: {name} -> {rel}")
            continue

        try:
            data = lzma.decompress(path.read_bytes())
        except Exception as exc:
            error(f"binary_artifact XZ decode failed: {name} -> {rel}: {exc}")
            continue

        expected_size = artifact.get("size")
        if not isinstance(expected_size, int) or expected_size <= 0:
            error(f"binary_artifact size metadata invalid: {name}")
            continue
        if len(data) != expected_size:
            error(f"binary_artifact size mismatch: {name} got={len(data)} expected={expected_size}")
            continue

        got = hashlib.sha256(data).hexdigest()
        if got != expected:
            error(f"binary_artifact hash mismatch: {name} got={got} expected={expected}")
            continue

        verified += 1
        print(f"OK: {name} size={len(data)} sha256={got}")

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
