#!/usr/bin/env python3
"""Validate and retarget a cached work-candidate native base to the current commit."""
import argparse
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git_has_commit(ref):
    if not ref or set(ref) == {"0"}:
        return False
    proc = subprocess.run(
        ["git", "cat-file", "-e", f"{ref}^{{commit}}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def git_text(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--fingerprint", default="dist/work_candidate_base_fingerprint.json")
    ap.add_argument("--base")
    args = ap.parse_args()

    package = ROOT / args.package
    metadata_path = ROOT / args.metadata
    summary_path = ROOT / args.summary
    fingerprint_path = ROOT / args.fingerprint
    for p in (package, metadata_path, summary_path, fingerprint_path):
        if not p.is_file():
            raise SystemExit("cached candidate base input missing: " + str(p.relative_to(ROOT)))

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    fingerprint = json.loads(fingerprint_path.read_text(encoding="utf-8"))
    expected_fingerprint = fingerprint.get("base_fingerprint")
    if not isinstance(expected_fingerprint, str) or len(expected_fingerprint) != 64:
        raise SystemExit("invalid work-candidate base fingerprint")

    package_sha = sha256_file(package)
    if metadata.get("package_sha256") != package_sha or summary.get("package_sha256") != package_sha:
        raise SystemExit("cached candidate base package SHA mismatch")
    if metadata.get("all_active_dlls_in_zip_root") is not True:
        raise SystemExit("cached candidate base metadata lost active DLL root gate")
    if summary.get("result") != "PASS" or summary.get("ready_for_test") is not True:
        raise SystemExit("cached candidate base summary is not PASS/ready_for_test")

    with zipfile.ZipFile(package) as zf:
        names = [x.filename for x in zf.infolist() if not x.is_dir()]
        if zf.testzip() is not None:
            raise SystemExit("cached candidate base ZIP CRC failure")
        if len(names) != len(set(x.lower() for x in names)):
            raise SystemExit("cached candidate base ZIP has duplicate paths")
        expected_names = metadata.get("zip_root_entries") or []
        if names != expected_names:
            raise SystemExit("cached candidate base ZIP entries differ from metadata")

    head = git_text("rev-parse", "HEAD")
    base = args.base if git_has_commit(args.base) else None
    if not base:
        base = git_text("rev-parse", "HEAD^")
    changed = [
        x.strip().replace("\\", "/")
        for x in git_text("diff", "--name-only", base, "HEAD").splitlines()
        if x.strip()
    ]
    cached_from = metadata.get("git_head") or summary.get("head")

    metadata["git_head"] = head
    metadata["base_cache"] = {
        "hit": True,
        "fingerprint": expected_fingerprint,
        "cached_from_head": cached_from,
        "validated_package_sha256": package_sha,
    }
    summary["head"] = head
    summary["base"] = base
    summary["changed_files"] = changed
    summary["base_cache"] = {
        "hit": True,
        "fingerprint": expected_fingerprint,
        "cached_from_head": cached_from,
        "validated_package_sha256": package_sha,
    }
    timings = summary.setdefault("driver_timings_ms", {})
    timings["base_cache_hit"] = True
    timings["build_subprocess_wall"] = 0.0
    verification = summary.setdefault("verification", {})
    verification["base_cache"] = {
        "result": "PASS",
        "fingerprint": expected_fingerprint,
        "package_sha256": package_sha,
    }

    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("WORK_CANDIDATE_BASE_CACHE: PASS", expected_fingerprint, cached_from, "->", head)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
