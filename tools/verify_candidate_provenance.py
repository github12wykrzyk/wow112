#!/usr/bin/env python3
"""Fail-closed attestation of the exact post-finalize candidate before artifact upload.

This proves provenance and package integrity, not functionality inside the game.
"""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def require(ok, message):
    if not ok:
        raise SystemExit("CANDIDATE_ATTESTATION: FAIL: " + message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sha", required=True)
    parser.add_argument("--branch", required=True, choices=("parallel", "work"))
    parser.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    parser.add_argument("--metadata", default="dist/candidate_metadata.json")
    parser.add_argument("--summary", default="dist/candidate_summary.json")
    parser.add_argument("--final-report", default="dist/final_package_verification.json")
    parser.add_argument("--output", default="dist/candidate_attestation.json")
    args = parser.parse_args()

    actual_head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    require(len(args.sha) == 40 and actual_head == args.sha,
            "workflow SHA does not match checked-out commit")
    require(os.environ.get("GITHUB_REF_NAME", args.branch) == args.branch,
            "workflow branch does not match requested channel")

    package = ROOT / args.package
    require(package.is_file(), "candidate ZIP is missing")
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    size = package.stat().st_size
    meta, summary, report = (
        load(ROOT / args.metadata),
        load(ROOT / args.summary),
        load(ROOT / args.final_report),
    )
    require(meta.get("git_head") == args.sha and summary.get("head") == args.sha,
            "package/summary commit does not match exact workflow commit")
    require(report.get("result") == "PASS" and summary.get("result") == "PASS"
            and summary.get("ready_for_test") is True,
            "finalized package and candidate summary must both PASS")
    require(all(row.get("result") == "PASS" for row in (
        summary.get("verification", {}).get("verify_current", {}),
        summary.get("verification", {}).get("verify_runtime_artifacts", {}),
        summary.get("verification", {}).get("verify_verified_symbols", {}),
    )), "fast verification gates missing or failed")
    require(report.get("loader_exact") is True
            and report.get("all_binary_entries_pe32_x86") is True,
            "x86 executable/DLL or loader manifest validation is incomplete")
    for label, item in (("package metadata", meta),
                        ("candidate summary", summary),
                        ("final report", report),
                        ("embedded final report", meta.get("final_package_verification") or {})):
        require(item.get("package_sha256") == digest
                and item.get("package_size") == size,
                label + " does not identify the final package bytes")
    require((summary.get("final_package_verification") or {}).get("package_sha256") == digest,
            "summary does not contain the final package proof")
    require(set(meta.get("candidate_required_modules", [])) ==
            set(report.get("candidate_required_modules", [])),
            "companion module metadata does not match final ZIP")

    builds = summary.get("audit_builds", [])
    require(all(row.get("pe_machine") == "0x014C" for row in builds),
            "an audited active module is not x86")
    output = {
        "schema_version": 1,
        "branch": args.branch,
        "commit_sha": args.sha,
        "package_sha256": digest,
        "package_size": size,
        "active_dlls": report.get("dlls", []),
        "built_native_module_count": len(builds),
        "source_check": "SOURCE_CHECK_PASS",
        "native_build": "X86_BUILD_PASS" if builds else "X86_BUILD_NOT_REQUIRED",
        "package_status": "PACKAGE_VERIFIED",
        "delivery_status": "READY_FOR_GAME_TEST",
        "game_test_accepted": False,
        "result": "PASS",
    }
    dest = ROOT / args.output
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print("CANDIDATE_ATTESTATION: PASS", args.branch, args.sha, digest)


if __name__ == "__main__":
    main()
