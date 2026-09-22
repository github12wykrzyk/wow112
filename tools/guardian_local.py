#!/usr/bin/env python3
"""Run Guardian AI on user's Windows machine; GitHub's own schedule remains audit-only."""
import datetime
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

import guardian

ROOT = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "WoW112Guardian"
MODEL = os.environ.get("WOW112_LOCAL_MODEL", "qwen2.5-coder:7b")
URL = "http://127.0.0.1:11434"


def github_token():
    process = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"],
                             capture_output=True, text=True, timeout=20)
    if process.returncode or not process.stdout.strip():
        raise RuntimeError("GitHub CLI is not authenticated: run gh auth login -h github.com")
    return process.stdout.strip()


def ollama_tags():
    with urllib.request.urlopen(URL + "/api/tags", timeout=8) as response:
        return json.load(response)


def local_completion(request):
    # A small 7B model on an 8 GB GPU must not silently truncate source context.
    source = json.loads(request["messages"][1]["content"])["source"]
    if len(source.encode("utf-8")) > 12000:
        return {"old": "", "new": "", "reason": "Source too large for safe local model context"}
    payload = {"model": MODEL, "stream": False, "format": "json", "keep_alive": "5m",
               "messages": request["messages"],
               "options": {"temperature": 0, "num_ctx": 8192, "num_predict": 900}}
    req = urllib.request.Request(URL + "/api/chat",
                                 data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=480) as response:
        result = json.load(response)
    answer = result.get("message", {}).get("content", "")
    if result.get("done_reason") not in ("stop", None) or not answer:
        raise RuntimeError("Local model failed to return a complete proposal")
    proposed = json.loads(answer)
    if not isinstance(proposed, dict):
        raise ValueError("Ollama response is not a JSON object")
    return proposed


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    # gh manages credentials in Windows Credential Manager; never persist token to logs.
    guardian.os.environ["GH_TOKEN"] = github_token()
    guardian.os.environ["GITHUB_REPOSITORY"] = "github12wykrzyk/wow112"
    models = ollama_tags().get("models", [])
    if not any(x.get("name", "").split(":")[0] == MODEL.split(":")[0]
               and x.get("name", "").endswith(":" + MODEL.split(":")[-1]) for x in models):
        raise RuntimeError("Local model not installed: run ollama pull " + MODEL)
    rows = []
    for branch in guardian.BRANCHES:
        try:
            rows.append(guardian.audit(branch))
        except Exception as exc:
            rows.append({"branch": branch, "head": "unknown", "findings":
                         ["AUDIT ERROR: " + str(exc)[:180]], "failures": []})
    if any(r["head"] == "unknown" for r in rows):
        repair = {"state": "skipped", "reason": "GitHub audit incomplete"}
    else:
        repair = guardian.repair(rows, model_call=local_completion)
    result = {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "branches": [{"branch": x["branch"], "head": x["head"],
                            "findings": x["findings"]} for x in rows],
              "repair": repair}
    # Local diagnostics without source content, API token or model prompt.
    report = ROOT / "last_run.json"
    report.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    return 1 if any(r["head"] == "unknown" for r in rows) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError, urllib.error.URLError,
            ValueError, RuntimeError) as exc:
        print("LOCAL_GUARDIAN_ERROR: " + str(exc).replace(os.environ.get("GH_TOKEN", "__never__"), "<redacted>"),
              file=sys.stderr)
        sys.exit(1)
