#!/usr/bin/env python3
"""Fail closed on candidate source-fingerprint drift outside explicit work overrides."""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CURRENT = ROOT / "CURRENT.json"
WORK_CANDIDATE = ROOT / "runtime/work_candidate.json"


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fail(msg):
    print("ERROR: " + msg)
    return 1


def main():
    current = json.loads(CURRENT.read_text(encoding="utf-8"))
    if current.get("status") != "candidate":
        print("Candidate source-fingerprint scope: stable state -> strict verify_current rules apply")
        print("RESULT: PASS")
        return 0

    if not WORK_CANDIDATE.is_file():
        return fail("candidate state requires runtime/work_candidate.json")

    work = json.loads(WORK_CANDIDATE.read_text(encoding="utf-8"))
    allowed = work.get("source_fingerprint_warning_allowlist")
    if allowed is None:
        allowed = work.get("source_overrides") or []
    if not isinstance(allowed, list) or any(not isinstance(x, str) or not x for x in allowed):
        return fail("source_fingerprint_warning_allowlist/source_overrides must be a list of DLL names")
    allowed_set = {x.lower() for x in allowed}

    runtime_path = ROOT / current.get("runtime_manifest", "runtime/current.json")
    runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
    items = [x for x in runtime.get("active_dlls", []) if isinstance(x, dict)]
    active_names = {str(x.get("name", "")).lower() for x in items if x.get("name")}
    unknown = sorted(x for x in allowed if x.lower() not in active_names)
    if unknown:
        return fail("fingerprint warning allowlist contains non-active DLLs: %s" % ", ".join(unknown))

    drifted = []
    errors = []
    for item in items:
        name = item.get("name", "<unnamed>")
        source_path = item.get("source_path")
        if not source_path:
            continue
        path = ROOT / source_path
        if not path.is_file():
            errors.append("canonical source missing: %s -> %s" % (name, source_path))
            continue

        expected_hash = str(item.get("source_sha256", "")).lower()
        expected_size = item.get("source_size")
        reasons = []
        if len(expected_hash) != 64:
            reasons.append("missing/invalid source_sha256")
        elif sha256_file(path) != expected_hash:
            reasons.append("source_sha256 mismatch")
        if not isinstance(expected_size, int) or expected_size <= 0:
            reasons.append("missing/invalid source_size")
        elif path.stat().st_size != expected_size:
            reasons.append("source_size mismatch")

        if reasons:
            drifted.append(name)
            if name.lower() not in allowed_set:
                errors.append("unapproved candidate fingerprint drift: %s (%s)" % (name, ", ".join(reasons)))
            else:
                print("ALLOW: %s (%s)" % (name, ", ".join(reasons)))

    if errors:
        for msg in errors:
            print("ERROR: " + msg)
        print("Candidate source-fingerprint scope summary")
        print("  allowlisted DLLs: %d" % len(allowed_set))
        print("  drifted DLLs: %d" % len(drifted))
        print("  errors: %d" % len(errors))
        print("RESULT: FAIL")
        return 1

    print("Candidate source-fingerprint scope summary")
    print("  allowlisted DLLs: %d" % len(allowed_set))
    print("  drifted DLLs: %d" % len(drifted))
    print("  drifted: %s" % (", ".join(drifted) if drifted else "(none)"))
    print("  errors: 0")
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
