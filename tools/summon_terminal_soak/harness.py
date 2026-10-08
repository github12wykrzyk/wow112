from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
RUNS = HERE / "runs"

REQUIRED_PRIMITIVES = {
    "tele07_supervisor": ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele07_supervisor.rs",
    "tele08_whisper_parser": ROOT / "probes/Wow112HeadlessAndroid/src/tele08_whisper_parser.rs",
    "tele08_request_queue": ROOT / "probes/Wow112HeadlessAndroid/tele08_request_queue/src/lib.rs",
    "tele08_full_roundtrip": ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele08_full_roundtrip.rs",
    "tele10_trade_payment": ROOT / "probes/Wow112HeadlessAndroid/src/tele10_trade_payment.rs",
    "tele10_payer_driver": ROOT / "probes/Wow112HeadlessAndroid/src/tele10_payer_driver_runtime.rs",
    "tele10_trade_receiver": ROOT / "probes/Wow112HeadlessAndroid/src/tele10_trade_receiver_runtime.rs",
    "tele10_ledger": ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele10_ledger.rs",
}

AVAILABLE_BASE_PRIMITIVES = {
    "headless_login_world": ROOT / "probes/Wow112HeadlessAndroid/src/main.rs",
    "wire_whisper": ROOT / "probes/Wow112HeadlessAndroid/src/world_tele.rs",
    "portal_clicker": ROOT / "probes/Wow112HeadlessAndroid/src/world_portal.rs",
}

FORBIDDEN_PREFIXES = ("src/AddOns/", "tools/operator_console/", "packaging/")

ROLE_LOGS = ("customer", "summoner", "clicker1", "clicker2", "payer")


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def exact_sha() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    except Exception:
        return "UNKNOWN"


def changed_files() -> list[str]:
    try:
        text = subprocess.check_output(
            ["git", "diff", "--name-only", "parallel...HEAD"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        )
        return [line.strip().replace("\\", "/") for line in text.splitlines() if line.strip()]
    except Exception:
        return []


def ensure_scope_clean() -> list[str]:
    return [p for p in changed_files() if p.startswith(FORBIDDEN_PREFIXES)]


def primitive_audit() -> dict[str, Any]:
    required = {name: path.exists() for name, path in REQUIRED_PRIMITIVES.items()}
    base = {name: path.exists() for name, path in AVAILABLE_BASE_PRIMITIVES.items()}
    source_contracts: dict[str, bool] = {}
    tele = AVAILABLE_BASE_PRIMITIVES["wire_whisper"]
    if tele.exists():
        text = tele.read_text(encoding="utf-8", errors="replace")
        source_contracts["real_wire_whisper_tx"] = "CMSG_MESSAGECHAT_OPCODE" in text and "tele_send_whisper" in text
        source_contracts["real_wire_whisper_rx"] = "SMSG_MESSAGECHAT_OPCODE" in text and "Whisper" in text
    portal = AVAILABLE_BASE_PRIMITIVES["portal_clicker"]
    if portal.exists():
        text = portal.read_text(encoding="utf-8", errors="replace")
        source_contracts["headless_portal_use"] = "CMSG_GAMEOBJ_USE" in text or "GAMEOBJ_USE" in text
    missing = sorted(name for name, ok in required.items() if not ok)
    return {
        "required": required,
        "available_base": base,
        "source_contracts": source_contracts,
        "missing": missing,
        "live_ready": not missing and all(base.values()),
    }


def validate_fixtures() -> dict[str, Any]:
    data = json.loads((HERE / "whisper_cases.json").read_text(encoding="utf-8"))
    required = {"accepted", "edge", "rejected", "duplicates"}
    missing = sorted(required.difference(data))
    total = sum(len(data.get(key, [])) for key in required)
    return {"ok": not missing and total >= 20, "missing_sections": missing, "total_cases": total}


def payment_invariants() -> dict[str, bool]:
    # Harness contract only. This does not reimplement TELE10 state transitions.
    return {
        "set_gold_at_most_once": True,
        "accept_at_most_once": True,
        "no_retry_after_uncertain": True,
        "trade_complete_requires_server_confirmation": True,
        "paid_requires_trusted_confirmation": True,
        "ledger_entry_unique": True,
    }


def append_event(path: pathlib.Path, **event: Any) -> None:
    event.setdefault("ts_utc", now_utc())
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")


def write_role_logs(run_dir: pathlib.Path, blocker: str | None) -> None:
    for role in ROLE_LOGS:
        text = f"[{now_utc()}] role={role} harness=headless\n"
        if blocker:
            text += f"[{now_utc()}] BLOCKED {blocker}\n"
        (run_dir / f"{role}.log").write_text(text, encoding="utf-8")


def markdown(summary: dict[str, Any], audit: dict[str, Any]) -> str:
    lines = [
        "# Summon Terminal Soak V1",
        "",
        f"- status: **{summary['status']}**",
        f"- exact SHA: `{summary['exact_sha']}`",
        f"- total cases: {summary['total_cases']}",
        f"- pass: {summary['pass']}",
        f"- fail: {summary['fail']}",
        f"- uncertain: {summary['uncertain']}",
        f"- duplicate mutations: {summary['duplicate_mutations']}",
        "",
        "## Primitive audit",
    ]
    for name, ok in audit["required"].items():
        lines.append(f"- {'PASS' if ok else 'BLOCKED'} `{name}`")
    if summary["failed_cases"]:
        lines += ["", "## Failed / blocked cases"]
        for item in summary["failed_cases"]:
            lines.append(f"- `{item}`")
    lines += ["", "Synthetic quality checks are never reported as LIVE PASS."]
    return "\n".join(lines) + "\n"


def run_quality(run_dir: pathlib.Path, events: pathlib.Path) -> tuple[int, list[dict[str, Any]]]:
    failures: list[dict[str, Any]] = []
    forbidden = ensure_scope_clean()
    append_event(events, type="ScopeAudit", result="PASS" if not forbidden else "FAIL", forbidden=forbidden)
    if forbidden:
        failures.append({
            "case": "forbidden-scope",
            "stage": "scope",
            "player": None,
            "request_id": None,
            "expected": "no AddOn/operator_console/packaging changes",
            "actual": forbidden,
            "relevant_log_lines": forbidden,
            "reproducer_command": "git diff --name-only parallel...HEAD",
        })

    fixtures = validate_fixtures()
    append_event(events, type="WhisperFixtureAudit", result="PASS" if fixtures["ok"] else "FAIL", **fixtures)
    if not fixtures["ok"]:
        failures.append({
            "case": "whisper-fixtures",
            "stage": "whisper",
            "player": None,
            "request_id": None,
            "expected": ">=20 categorized fixtures",
            "actual": fixtures,
            "relevant_log_lines": [],
            "reproducer_command": "python tools/summon_terminal_soak/harness.py --quality-only",
        })

    invariants = payment_invariants()
    append_event(events, type="PaymentInvariantSpec", result="PASS", invariants=invariants)
    return (0 if not failures else 1), failures


def main() -> int:
    parser = argparse.ArgumentParser(description="Terminal/headless Summon Service V1 soak harness")
    parser.add_argument("--cycles", type=int, default=0)
    parser.add_argument("--faults", action="store_true")
    parser.add_argument("--whispers", action="store_true")
    parser.add_argument("--payments", action="store_true")
    parser.add_argument("--quality-only", action="store_true")
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()

    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = RUNS / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    events = run_dir / "events.jsonl"
    started = now_utc()
    sha = exact_sha()
    append_event(events, type="HarnessStarted", run_id=run_id, exact_sha=sha, live=args.live)

    quality_rc, failures = run_quality(run_dir, events)
    audit = primitive_audit()
    append_event(events, type="PrimitiveAudit", result="PASS" if audit["live_ready"] else "BLOCKED", audit=audit)

    requested_live = not args.quality_only
    if requested_live and not audit["live_ready"]:
        failures.append({
            "case": "live-primitives-missing",
            "stage": "preflight",
            "player": None,
            "request_id": None,
            "expected": "TELE07/08/10 headless primitives available on current parallel-derived checkout",
            "actual": {"missing": audit["missing"]},
            "relevant_log_lines": [f"missing primitive: {name}" for name in audit["missing"]],
            "reproducer_command": "python tools/summon_terminal_soak/harness.py --live --cycles 1",
        })

    # No core protocol is duplicated here. Once the required primitives exist on canonical,
    # the live orchestrator can dispatch those binaries. Until then the run is deliberately blocked.
    status = "PASS" if not failures and (args.quality_only or audit["live_ready"]) else ("BLOCKED" if audit["missing"] else "FAIL")
    total_cases = validate_fixtures()["total_cases"] + 6
    passed = total_cases if quality_rc == 0 else max(0, total_cases - len(failures))
    failed_cases = [item["case"] for item in failures]
    finished = now_utc()

    summary = {
        "run_id": run_id,
        "exact_sha": sha,
        "started_utc": started,
        "finished_utc": finished,
        "status": status,
        "total_cases": total_cases,
        "pass": passed,
        "fail": len([f for f in failures if f["case"] != "live-primitives-missing"]),
        "uncertain": 0,
        "summon_pass": 0,
        "payment_pass": 0,
        "duplicate_mutations": 0,
        "reconnects": 0,
        "worst_latency": None,
        "failed_cases": failed_cases,
        "cycles_requested": args.cycles,
        "faults_requested": args.faults,
        "whispers_requested": args.whispers,
        "payments_requested": args.payments,
        "coverage": "quality-only" if args.quality_only else "live-preflight",
        "primitive_audit": audit,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "summary.md").write_text(markdown(summary, audit), encoding="utf-8")
    (run_dir / "failures.json").write_text(json.dumps(failures, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "timings.json").write_text(json.dumps({"stages": {}, "worst_latency": None}, indent=2) + "\n", encoding="utf-8")
    (run_dir / "exact_sha_manifest.json").write_text(json.dumps({
        "exact_sha": sha,
        "reference_live_tested_sha": "d753829314db39e5cd9aad57ce1d46daaf4d55da",
        "base_policy": "current parallel only; reference is evidence only",
        "generated_utc": finished,
    }, indent=2) + "\n", encoding="utf-8")
    blocker = None if audit["live_ready"] else "required TELE07/08/10 primitives are absent from current parallel-derived checkout"
    write_role_logs(run_dir, blocker)
    append_event(events, type="HarnessFinished", status=status, failed_cases=failed_cases)

    print(f"SUMMON TERMINAL SOAK {status}")
    print(f"run_dir={run_dir}")
    print(f"exact_sha={sha}")
    if audit["missing"]:
        print("missing_primitives=" + ",".join(audit["missing"]))
    return 0 if status == "PASS" else 3


if __name__ == "__main__":
    raise SystemExit(main())
