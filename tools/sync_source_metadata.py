#!/usr/bin/env python3
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
CURRENT = ROOT / "CURRENT.json"


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(
        description="Synchronize source_sha256/source_size promotion fingerprints from canonical source_path files."
    )
    ap.add_argument("--check", action="store_true", help="Do not write; fail if any tracked fingerprint is stale or missing.")
    args = ap.parse_args()

    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    current = json.loads(CURRENT.read_text(encoding="utf-8"))
    stale = []

    for item in runtime.get("active_dlls", []):
        if not isinstance(item, dict):
            continue
        rel = item.get("source_path")
        if not rel:
            continue
        path = ROOT / rel
        if not path.is_file():
            raise SystemExit(f"canonical source missing: {item.get('name')} -> {rel}")
        digest = sha256_file(path)
        size = path.stat().st_size
        old_hash = item.get("source_sha256")
        old_size = item.get("source_size")
        if old_hash != digest or old_size != size:
            stale.append(
                {
                    "name": item.get("name"),
                    "source_path": rel,
                    "old_sha256": old_hash,
                    "new_sha256": digest,
                    "old_size": old_size,
                    "new_size": size,
                }
            )
        item["source_sha256"] = digest
        item["source_size"] = size

    mc = current.get("movementcore")
    if isinstance(mc, dict) and mc.get("source_path"):
        rel = mc["source_path"]
        path = ROOT / rel
        if not path.is_file():
            raise SystemExit(f"CURRENT movementcore source missing: {rel}")
        mc["source_sha256"] = sha256_file(path)
        mc["source_size"] = path.stat().st_size

    if args.check:
        if stale:
            print(json.dumps({"stale_source_fingerprints": stale}, indent=2))
            print("RESULT: FAIL - run python tools/sync_source_metadata.py before stable promotion")
            return 1
        print("RESULT: PASS - source promotion fingerprints are synchronized")
        return 0

    RUNTIME.write_text(json.dumps(runtime, indent=2) + "\n", encoding="utf-8")
    CURRENT.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"updated": stale, "count": len(stale)}, indent=2))
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
