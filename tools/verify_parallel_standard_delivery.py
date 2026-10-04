#!/usr/bin/env python3
"""Fail closed if PARALLEL/STANDARD is not discoverable by the updater delivery path.

This gate runs after actions/upload-artifact in build_work_candidate.yml. It checks:
1) the live parallel branch still points at this workflow SHA,
2) this workflow run belongs to that exact SHA/branch,
3) the exact STANDARD artifact is visible through the GitHub Actions API,
4) updater network compatibility code does not redirect /branches/parallel to a testpoint,
5) STANDARD Actions lookup remains scoped to build_work_candidate.yml while preserving branch=parallel.

The intent is to catch the exact class of failure where CI is green and the artifact exists,
but the loader keeps resolving an older delivery head.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"


def fail(message: str) -> None:
    print(f"DELIVERY_VISIBILITY: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def request_json(path: str, token: str | None) -> dict:
    req = urllib.request.Request(API + path)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "wow112-standard-delivery-gate")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"GitHub API {path} -> HTTP {exc.code}: {body[:500]}")
    except Exception as exc:
        fail(f"GitHub API {path} failed: {exc}")
    raise AssertionError("unreachable")


def verify_updater_route(source: Path) -> None:
    if not source.is_file():
        fail(f"missing updater route source: {source}")
    text = source.read_text(encoding="utf-8")

    forbidden = (
        "private const string ParallelBranchPath",
        "TestPointBranchPath",
        "Path = TestPointBranchPath",
    )
    hits = [needle for needle in forbidden if needle in text]
    if hits:
        fail("updater can still redirect live parallel delivery: " + ", ".join(hits))

    required = (
        'CandidateWorkflowRunsPath = "/repos/github12wykrzyk/wow112/actions/workflows/build_work_candidate.yml/runs"',
        'QueryContains(uri.Query, "branch=parallel")',
        'QueryContains(uri.Query, "per_page=50")',
    )
    missing = [needle for needle in required if needle not in text]
    if missing:
        fail("updater STANDARD routing contract drifted: missing " + ", ".join(missing))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--artifact-name", required=True)
    parser.add_argument("--branch", default="parallel")
    parser.add_argument("--route-source", default="tools/updater/UpdaterNetworkCompat.cs")
    parser.add_argument("--artifact-retries", type=int, default=8)
    parser.add_argument("--artifact-retry-seconds", type=float, default=3.0)
    args = parser.parse_args()

    if len(args.sha) != 40 or any(c not in "0123456789abcdefABCDEF" for c in args.sha):
        fail(f"invalid expected SHA: {args.sha}")

    verify_updater_route(Path(args.route_source))

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    repo_path = args.repo.replace("/", "%2F")

    branch = request_json(f"/repos/{args.repo}/branches/{args.branch}", token)
    live_sha = ((branch.get("commit") or {}).get("sha") or "").lower()
    if live_sha != args.sha.lower():
        fail(f"live {args.branch} HEAD is {live_sha[:12] or '?'}; expected {args.sha[:12]}")

    run = request_json(f"/repos/{args.repo}/actions/runs/{args.run_id}", token)
    if (run.get("head_sha") or "").lower() != args.sha.lower():
        fail(f"workflow run head_sha mismatch: {run.get('head_sha')} != {args.sha}")
    if run.get("head_branch") != args.branch:
        fail(f"workflow run branch mismatch: {run.get('head_branch')} != {args.branch}")
    if run.get("path") != ".github/workflows/build_work_candidate.yml":
        fail(f"unexpected workflow path: {run.get('path')}")

    artifact = None
    for attempt in range(1, max(args.artifact_retries, 1) + 1):
        payload = request_json(
            f"/repos/{args.repo}/actions/runs/{args.run_id}/artifacts?per_page=100", token
        )
        for row in payload.get("artifacts") or []:
            if row.get("name") == args.artifact_name:
                artifact = row
                break
        if artifact:
            break
        if attempt < args.artifact_retries:
            print(
                f"DELIVERY_VISIBILITY: artifact not visible yet ({attempt}/{args.artifact_retries}); retrying..."
            )
            time.sleep(args.artifact_retry_seconds)

    if not artifact:
        fail(f"artifact not discoverable for run {args.run_id}: {args.artifact_name}")
    if artifact.get("expired"):
        fail(f"artifact is unexpectedly expired: {args.artifact_name}")
    artifact_run = artifact.get("workflow_run") or {}
    artifact_sha = (artifact_run.get("head_sha") or "").lower()
    if artifact_sha and artifact_sha != args.sha.lower():
        fail(f"artifact workflow SHA mismatch: {artifact_sha} != {args.sha}")

    print(
        "DELIVERY_VISIBILITY: PASS "
        f"branch={args.branch} sha={args.sha} run={args.run_id} artifact={args.artifact_name} "
        f"artifact_id={artifact.get('id')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
