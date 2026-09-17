#!/usr/bin/env python3
import hashlib
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


def file_sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def exact_archived_source_fingerprints(runtime):
    out = set()
    for item in runtime.get("active_dlls", []):
        if not isinstance(item, dict) or item.get("source_state") != "exact_source_archived":
            continue
        digest = str(item.get("source_sha256", "")).lower()
        size = item.get("source_size")
        if len(digest) == 64 and isinstance(size, int) and size > 0:
            out.add((digest, size))
    return out


def is_exact_restored_archived_source(path, archived_fingerprints):
    if not path.is_file() or not archived_fingerprints:
        return False
    size = path.stat().st_size
    candidates = {digest for digest, expected_size in archived_fingerprints if expected_size == size}
    if not candidates:
        return False
    return file_sha256(path) in candidates


def verify_provenance(owner, rows, active_sources, archived_fingerprints):
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
            if not is_exact_restored_archived_source(path, archived_fingerprints):
                error(f"{owner}: source provenance is not an active canonical source_path/include or exact archived-source restore: {rel}")
        if not isinstance(evidence, list) or not evidence:
            error(f"{owner}: provenance[{i}] missing evidence snippets")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for snippet in evidence:
            if not isinstance(snippet, str) or not snippet:
                error(f"{owner}: empty/non-string evidence snippet in {rel}")
            elif snippet not in text:
                error(f"{owner}: evidence not found in {rel}: {snippet!r}")


def local_source_includes(rel):
    path = ROOT / rel
    if not path.is_file():
        return []
    out = []
    parent = path.parent
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line.startswith('#include "'):
            continue
        end = line.find('"', len('#include "'))
        if end < 0:
            continue
        name = line[len('#include "'):end]
        resolved = (parent / name).resolve()
        try:
            child = resolved.relative_to(ROOT.resolve()).as_posix()
        except ValueError:
            continue
        if child.startswith("src/") and resolved.is_file():
            out.append(child)
    return out


def collect_active_sources(runtime):
    active = set()
    pending = []
    for item in runtime.get("active_dlls", []):
        if not isinstance(item, dict):
            continue
        source_path = item.get("source_path")
        if source_path:
            active.add(source_path)
            pending.append(source_path)
        includes = item.get("source_includes", [])
        if includes is None:
            includes = []
        if not isinstance(includes, list):
            error(f"{item.get('name', '<unnamed>')}: source_includes must be a list")
            continue
        for rel in includes:
            if not isinstance(rel, str) or not rel:
                error(f"{item.get('name', '<unnamed>')}: source_includes contains an invalid path")
                continue
            if not rel.replace('\\', '/').startswith("src/"):
                error(f"{item.get('name', '<unnamed>')}: source_includes must live under src/: {rel}")
                continue
            if not (ROOT / rel).is_file():
                error(f"{item.get('name', '<unnamed>')}: source include missing: {rel}")
                continue
            if rel not in active:
                active.add(rel)
                pending.append(rel)

    # A canonical wrapper source may directly include its exact ancestor source.
    # Follow only repository-local quoted includes under src/, so provenance stays
    # tied to files that actually participate in the candidate translation unit.
    while pending:
        parent = pending.pop()
        for child in local_source_includes(parent):
            if child not in active:
                active.add(child)
                pending.append(child)
    return active


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

    active_sources = collect_active_sources(runtime)
    archived_fingerprints = exact_archived_source_fingerprints(runtime)

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
        verify_provenance(sid, row.get("provenance"), active_sources, archived_fingerprints)

    for i, row in enumerate(registry.get("omitted_unresolved", [])):
        if not isinstance(row, dict):
            error(f"omitted_unresolved[{i}] is not an object")
            continue
        if row.get("provenance"):
            verify_provenance(f"omitted_unresolved[{i}]", row["provenance"], active_sources, archived_fingerprints)

    print("\nVerified-symbol registry summary")
    print("  target: WoW 1.12.1 build 5875 Windows x86")
    print(f"  verified symbols: {len(symbols)}")
    print(f"  omitted unresolved topics: {len(registry.get('omitted_unresolved', []))}")
    print(f"  exact archived source fingerprints: {len(archived_fingerprints)}")
    print(f"  errors: {len(ERRORS)}")
    if ERRORS:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
