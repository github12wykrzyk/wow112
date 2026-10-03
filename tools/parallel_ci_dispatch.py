#!/usr/bin/env python3
"""Dispatch and wait for exact-SHA GitHub Actions delivery gates.

Used by the serialized Parallel integration flow both before merge (profile gates
on the exact feature SHA) and after merge (STANDARD + declared profiles on the
exact integrated parallel SHA). All selected workflows are dispatched first so
independent profile builds run concurrently; the caller returns only after every
exact-SHA gate succeeds.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.github.com"
WORKFLOWS = {
    "economy": "build_parallel_economy.yml",
    "updater": "build_updater.yml",
    "autologinbridge": "build_autologinbridge.yml",
}
STANDARD = ("standard", "build_work_candidate.yml")


def parse_profiles(value):
    if not value:
        return []
    result = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if item not in WORKFLOWS:
            raise ValueError("unsupported delivery profile: " + item)
        if item not in result:
            result.append(item)
    return result


def selected_workflows(include_standard, profiles):
    selected = []
    if include_standard:
        selected.append(STANDARD)
    selected.extend((profile, WORKFLOWS[profile]) for profile in profiles)
    return selected


def api_request(token, method, path, payload=None):
    data = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "User-Agent": "wow112-parallel-ci-dispatch",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError("GitHub API %s %s failed: HTTP %s %s" %
                           (method, path, exc.code, body)) from exc


def workflow_runs(token, repo, workflow, ref):
    query = urllib.parse.urlencode({
        "event": "workflow_dispatch",
        "branch": ref,
        "per_page": 50,
    })
    data = api_request(
        token,
        "GET",
        "/repos/%s/actions/workflows/%s/runs?%s" % (repo, workflow, query),
    )
    return list((data or {}).get("workflow_runs", []))


def dispatch_exact(token, repo, workflow, label, ref, sha, materialize_timeout=120):
    before = {str(run["id"]) for run in workflow_runs(token, repo, workflow, ref)}
    api_request(
        token,
        "POST",
        "/repos/%s/actions/workflows/%s/dispatches" % (repo, workflow),
        {"ref": ref},
    )
    print("PARALLEL_CI_DISPATCH: dispatched %s workflow=%s ref=%s sha=%s" %
          (label, workflow, ref, sha), flush=True)

    deadline = time.monotonic() + materialize_timeout
    while time.monotonic() < deadline:
        for candidate in workflow_runs(token, repo, workflow, ref):
            if (candidate.get("head_sha") == sha
                    and candidate.get("head_branch") == ref
                    and str(candidate.get("id")) not in before):
                run_id = int(candidate["id"])
                print("PARALLEL_CI_DISPATCH: materialized %s run=%s" %
                      (label, run_id), flush=True)
                return run_id
        time.sleep(2)
    raise RuntimeError("%s dispatch did not materialize on exact SHA %s" % (label, sha))


def wait_exact(token, repo, label, run_id, ref, sha, completion_timeout=1800):
    deadline = time.monotonic() + completion_timeout
    while time.monotonic() < deadline:
        current = api_request(token, "GET", "/repos/%s/actions/runs/%s" % (repo, run_id))
        if current.get("head_sha") != sha or current.get("head_branch") != ref:
            raise RuntimeError("%s run provenance changed unexpectedly" % label)
        if current.get("status") == "completed":
            conclusion = current.get("conclusion")
            if conclusion != "success":
                raise RuntimeError("%s exact-SHA gate failed: run=%s conclusion=%s" %
                                   (label, run_id, conclusion))
            print("PARALLEL_CI_DISPATCH: PASS %s run=%s sha=%s" %
                  (label, run_id, sha), flush=True)
            return
        time.sleep(5)
    raise RuntimeError("%s exact-SHA gate timed out: run=%s" % (label, run_id))


def write_outputs(path, results):
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as handle:
        for label, run_id in results.items():
            handle.write(label + "_run_id=" + str(run_id) + "\n")
        handle.write("delivery_run_ids=" + json.dumps(results, sort_keys=True, separators=(",", ":")) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--profiles", default="")
    parser.add_argument("--standard", action="store_true")
    parser.add_argument("--github-output")
    args = parser.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        print("PARALLEL_CI_DISPATCH: FAIL: GH_TOKEN/GITHUB_TOKEN is required", file=sys.stderr)
        return 1
    try:
        profiles = parse_profiles(args.profiles)
        selected = selected_workflows(args.standard, profiles)
        results = {}
        for label, workflow in selected:
            results[label] = dispatch_exact(
                token, args.repo, workflow, label, args.ref, args.sha
            )
        for label, _workflow in selected:
            wait_exact(token, args.repo, label, results[label], args.ref, args.sha)
        write_outputs(args.github_output, results)
        print("PARALLEL_CI_DISPATCH: PASS " + json.dumps(results, sort_keys=True))
        return 0
    except (ValueError, RuntimeError, OSError, json.JSONDecodeError) as exc:
        print("PARALLEL_CI_DISPATCH: FAIL: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
