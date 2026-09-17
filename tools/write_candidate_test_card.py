#!/usr/bin/env python3
"""Create a concise human-readable test card for a work candidate artifact."""

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def git_text(*args):
    try:
        return subprocess.check_output(
            ["git", *args], cwd=str(ROOT), text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return ""


def rows(values, empty="(none)"):
    values = [str(x) for x in (values or []) if str(x).strip()]
    if not values:
        return [f"- {empty}"]
    return [f"- {value}" for value in values]


def main():
    ap = argparse.ArgumentParser(description="Write TEST_THIS.txt for a WoW112 work candidate.")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--output", default="dist/TEST_THIS.txt")
    args = ap.parse_args()

    summary_path = (ROOT / args.summary).resolve()
    output_path = (ROOT / args.output).resolve()
    data = json.loads(summary_path.read_text(encoding="utf-8"))

    head = data.get("head") or git_text("rev-parse", "HEAD")
    subject = git_text("log", "-1", "--pretty=%s", head or "HEAD")
    changed_modules = data.get("changed_active_modules") or []
    required_modules = data.get("candidate_required_modules") or []
    overrides = data.get("candidate_override_names") or []
    changed_files = data.get("changed_files") or []
    verification = data.get("verification") or {}

    lines = [
        "WoW112 WORK CANDIDATE - TEST CARD",
        "=================================",
        "Target: World of Warcraft 1.12.1 build 5875, Windows x86",
        f"Commit: {head}",
        f"Change: {subject or '(commit subject unavailable)'}",
        f"Verdict: {data.get('result', 'UNKNOWN')}",
        f"Ready for test: {'YES' if data.get('ready_for_test') else 'NO'}",
        f"Package SHA256: {data.get('package_sha256') or '(n/a)'}",
        "",
        "CHANGED ACTIVE MODULES",
        *rows(changed_modules),
        "",
        "CANDIDATE-REQUIRED COMPANION MODULES",
        *rows(required_modules),
        "",
        "DLL OVERRIDES ACTUALLY PACKAGED",
        *rows(overrides),
        "",
        "FAST VERIFICATION",
    ]

    for key in ("verify_current", "verify_runtime_artifacts", "verify_verified_symbols"):
        gate = verification.get(key) or {}
        lines.append(f"- {key}: {gate.get('result', 'UNKNOWN')}")

    lines.extend([
        "",
        "CHANGED FILES",
        *rows(changed_files),
        "",
        "This card is generated automatically from candidate_summary.json.",
        "Use candidate_summary.json as the machine-readable source of truth.",
        "",
    ])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines), encoding="utf-8")
    print(output_path.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
