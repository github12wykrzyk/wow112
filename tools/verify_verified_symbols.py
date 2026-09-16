#!/usr/bin/env python3
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "runtime/verified_symbols_5875.json"
RUNTIME = ROOT / "runtime/current.json"
ERRORS = []


def error(msg):
    ERRORS.append(msg)
    print("ERROR: " + msg)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        error(f"cannot load {path.relative_to(ROOT)}: {exc}")
        return None


def verify_provenance(owner, rows, active_sources):
    if not isinstance(rows, list) or not rows:
        error(f"{owner}: provenance must be a non-empty list")
        return
    for i, row in enumerate(rows):
        if not isinstance(row, dict):
            error(f"{owner}: provenance[{i}] is not an object")
            continue
        rel = row.get("path")
        evidence = row.get("evidence")
        if not rel:
            error(f"{owner}: provenance[{i}] missing path")
            continue
        path = ROOT / rel
        if not path.is_file():
            error(f"{owner}: provenance file missing: {rel}")
            continue
        if rel.startswith("src/") and rel not in active_sources:
            error(f"{owner}: source provenance is not an active canonical source_path: {rel}")
        if not isinstance(evidence, list) or not evidence:
            error(f"{owner}: provenance[{i}] missing evidence snippets")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for snippet in evidence:
            if not isinstance(snippet, str) or not snippet:
                error(f"{owner}: empty/non-string evidence snippet in {rel}")
            elif snippet not in text:
                error(f"{owner}: evidence not found in {rel}: {snippet!r}")


def main():
    registry = load_json(REGISTRY)
    runtime = load_json(RUNTIME)
    if registry is None or runtime is None:
        return 1

    target = registry.get("target", {})
    if (
        target.get("version") != "1.12.1"
        or target.get("build") != 5875
        or target.get("platform") != "Windows"
        or target.get("architecture") != "x86"
    ):
        error("registry target must be WoW 1.12.1 build 5875 Windows x86")

    active_sources = {
        item.get("source_path")
        for item in runtime.get("active_dlls", [])
        if isinstance(item, dict) and item.get("source_path")
    }

    seen = set()
    symbols = registry.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        error("symbols must be a non-empty list")
        symbols = []

    for row in symbols:
        if not isinstance(row, dict):
            error("symbol entry is not an object")
            continue
        sid = row.get("id")
        if not sid:
            error("symbol missing id")
            continue
        if sid in seen:
            error(f"duplicate symbol id: {sid}")
        seen.add(sid)
        if row.get("status") != "verified":
            error(f"{sid}: only status=verified is allowed in symbols")
        if row.get("kind") not in {"absolute_address", "offset", "constant", "function"}:
            error(f"{sid}: unsupported kind {row.get('kind')!r}")
        if not isinstance(row.get("value_u32"), int):
            error(f"{sid}: value_u32 must be an integer")
        value_hex = row.get("value_hex")
        if not isinstance(value_hex, str) or not value_hex.startswith("0x"):
            error(f"{sid}: value_hex must be a 0x-prefixed string")
        if row.get("kind") == "function":
            if not row.get("calling_convention"):
                error(f"{sid}: function missing calling_convention")
            if not row.get("c_signature"):
                error(f"{sid}: function missing c_signature")
        verify_provenance(sid, row.get("provenance"), active_sources)

    for i, row in enumerate(registry.get("omitted_unresolved", [])):
        if not isinstance(row, dict):
            error(f"omitted_unresolved[{i}] is not an object")
            continue
        if row.get("provenance"):
            verify_provenance(f"omitted_unresolved[{i}]", row["provenance"], active_sources)

    print("\nVerified-symbol registry summary")
    print("  target: WoW 1.12.1 build 5875 Windows x86")
    print(f"  verified symbols: {len(symbols)}")
    print(f"  omitted unresolved topics: {len(registry.get('omitted_unresolved', []))}")
    print(f"  errors: {len(ERRORS)}")
    if ERRORS:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
