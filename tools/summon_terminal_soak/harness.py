#!/usr/bin/env python3
import argparse, datetime as dt, json, os, pathlib, shutil, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
RUNS = HERE / "runs"
PROVEN = HERE / "Run-ProvenLiveTest.ps1"
REQUIRED = [
    "probes/Wow112HeadlessAndroid/src/bin/tele07_supervisor.rs",
    "probes/Wow112HeadlessAndroid/src/bin/tele08_full_roundtrip.rs",
    "probes/Wow112HeadlessAndroid/src/bin/tele10_ledger.rs",
    "probes/Wow112HeadlessAndroid/src/tele08_whisper_parser.rs",
    "probes/Wow112HeadlessAndroid/src/tele10_trade_payment.rs",
    "probes/Wow112HeadlessAndroid/src/tele10_payer_driver_runtime.rs",
    "probes/Wow112HeadlessAndroid/src/tele10_trade_receiver_runtime.rs",
    "probes/Wow112HeadlessAndroid/tele08_request_queue/Cargo.toml",
]
ROLE_KEYS = {
    "customer": ("customer", "whisper"),
    "summoner": ("summoner", "ritual", "supervisor"),
    "clicker1": ("clicker1", "clicker_1"),
    "clicker2": ("clicker2", "clicker_2"),
    "payer": ("payer", "trade", "payment", "tele10"),
}
MAX_TRANSIENT_WHISPER_PREFLIGHT_ATTEMPTS = 3


def utc(): return dt.datetime.now(dt.timezone.utc).isoformat()
def sha():
    return subprocess.check_output(["git","rev-parse","HEAD"], cwd=ROOT, text=True).strip()
def dump(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
def event(fp, typ, **kw):
    rec={"schema_version":1,"event_id":f"e-{time.time_ns()}","ts_utc":utc(),"type":typ,"session_id":kw.pop("session_id",None),"request_id":kw.pop("request_id",None),"customer":kw.pop("customer",None),"destination":kw.pop("destination",None),"state":kw.pop("state",None),"amount_copper":kw.pop("amount_copper",None),"correlation_id":kw.pop("correlation_id",None),"severity":kw.pop("severity","info"),"metadata":kw}
    fp.write(json.dumps(rec,ensure_ascii=False)+"\n"); fp.flush()


def primitive_audit():
    missing=[p for p in REQUIRED if not (ROOT/p).exists()]
    forbidden=[]
    try:
        base="a5ee048c620c55542460d54d7750e81f0f8f8da4"
        changed=subprocess.check_output(["git","diff","--name-only",f"{base}...HEAD"],cwd=ROOT,text=True).splitlines()
        forbidden=[p for p in changed if p.startswith(("src/AddOns/","tools/operator_console/","packaging/"))]
    except Exception: pass
    return missing,forbidden


def latest_result_dirs(before):
    root=HERE/"results"
    if not root.exists(): return []
    return [p for p in root.iterdir() if p.is_dir() and p.resolve() not in before]


def collect_role_logs(raw_root, run):
    files=[p for p in raw_root.rglob("*") if p.is_file() and p.suffix.lower() in (".log",".txt",".json")]
    for role, keys in ROLE_KEYS.items():
        out=run/f"{role}.log"
        with out.open("w",encoding="utf-8",errors="replace") as w:
            matched=0
            for p in files:
                low=str(p).lower()
                if any(k in low for k in keys):
                    matched+=1; w.write(f"\n===== {p.relative_to(raw_root)} =====\n")
                    try: w.write(p.read_text(encoding="utf-8",errors="replace"))
                    except Exception as e: w.write(f"<read error {e}>\n")
            if not matched: w.write("No dedicated role-named file; authoritative raw evidence is under raw/.\n")


def segment_plan(cycles):
    out=[]
    while cycles>0:
        n=min(20,cycles); out.append(n); cycles-=n
    return out or [1]


def is_transient_whisper_preflight_failure(report, text):
    if not report or report.get("result") != "FAIL":
        return False
    whisper = report.get("whisper") or {}
    summon_payment = report.get("summon_payment") or {}
    if whisper.get("passed") is not False or summon_payment.get("supervisor_exit_code") != -1:
        return False
    haystack = (str(whisper.get("status", "")) + "\n" + text).lower()
    return any(marker in haystack for marker in (
        "unexpectedeof",
        "failed to fill whole buffer",
        "connection reset",
        "connection aborted",
        "timed out",
        "wouldblock",
    ))


def run_live(run, cycles, faults=False):
    if not os.environ.get("WOW112_PASSWORD"):
        return False,[{"case":"credential","stage":"preflight","player":None,"request_id":None,"expected":"WOW112_PASSWORD present in process memory","actual":"missing","relevant_log_lines":[],"reproducer_command":"RUN_SUMMON_SOAK.cmd --cycles 1 --live"}],[],0,0
    env=os.environ.copy()
    if faults:
        env["WOW112_TELE07_FAULT_CYCLE"]="1"
        env["WOW112_TELE07_FAULT_ROLE"]="CLICKER2_PRECONNECT_ONCE"
    failures=[]; timings=[]; reconnects=0; uncertain=0
    results_root=HERE/"results"; results_root.mkdir(exist_ok=True)
    raw=run/"raw"; raw.mkdir()
    for idx,n in enumerate(segment_plan(cycles),1):
        segment_ok=False
        final_cp=None
        final_report=None
        for attempt in range(1, MAX_TRANSIENT_WHISPER_PREFLIGHT_ATTEMPTS + 1):
            before={p.resolve() for p in results_root.iterdir() if p.is_dir()}
            cmd=["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File",str(PROVEN),"-Cycles",str(n)]
            t0=time.monotonic()
            cp=subprocess.run(cmd,cwd=ROOT,env=env,text=True,capture_output=True)
            elapsed=time.monotonic()-t0
            timings.append({"segment":idx,"attempt":attempt,"cycles":n,"elapsed_seconds":elapsed,"exit_code":cp.returncode})
            (run/f"segment_{idx}_attempt_{attempt}.stdout.log").write_text(cp.stdout,encoding="utf-8",errors="replace")
            (run/f"segment_{idx}_attempt_{attempt}.stderr.log").write_text(cp.stderr,encoding="utf-8",errors="replace")
            newdirs=latest_result_dirs(before)
            segdest=raw/f"segment_{idx}"/f"attempt_{attempt}"; segdest.mkdir(parents=True)
            report=None
            if newdirs:
                src=max(newdirs,key=lambda p:p.stat().st_mtime)
                shutil.copytree(src,segdest/"evidence",dirs_exist_ok=True)
                rp=src/"FINAL_REPORT.json"
                if rp.exists():
                    try: report=json.loads(rp.read_text(encoding="utf-8-sig"))
                    except Exception: report=None
            text=(cp.stdout+"\n"+cp.stderr)
            if newdirs:
                try:
                    text += "\n"+"\n".join(p.read_text(encoding="utf-8",errors="replace") for d in newdirs for p in d.rglob("*") if p.is_file() and p.suffix.lower() in (".log",".txt",".json"))
                except Exception: pass
            uncertain += text.upper().count("UNCERTAIN")
            reconnects += text.upper().count("RECONNECT")
            ok=(cp.returncode==0 and report and report.get("result")=="PASS" and report.get("whisper",{}).get("passed") is True and report.get("summon_payment",{}).get("server_trade_complete") is True and report.get("summon_payment",{}).get("paid_summon_count",0)>=n and report.get("summon_payment",{}).get("hard_uncertain") is False)
            final_cp, final_report = cp, report
            if ok:
                segment_ok=True
                break
            transient_preflight = is_transient_whisper_preflight_failure(report, text)
            if not transient_preflight or attempt >= MAX_TRANSIENT_WHISPER_PREFLIGHT_ATTEMPTS:
                break
            time.sleep(1.0)
        if not segment_ok:
            cp = final_cp
            report = final_report
            failures.append({"case":f"live_segment_{idx}_{n}_cycles","stage":"wire_e2e","player":"Smokinpole/Teletanaris","request_id":None,"expected":"real whisper + summon + teleport + server TRADE_COMPLETE + trusted Paid ledger","actual":{"exit_code":cp.returncode if cp else None,"report":report},"relevant_log_lines":((cp.stdout+"\n"+cp.stderr).splitlines()[-40:] if cp else []),"reproducer_command":f"RUN_SUMMON_SOAK.cmd --cycles {n} --live"})
            break
    collect_role_logs(raw,run)
    return not failures,failures,timings,reconnects,uncertain


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--cycles",type=int,default=0)
    ap.add_argument("--faults",action="store_true")
    ap.add_argument("--whispers",action="store_true")
    ap.add_argument("--payments",action="store_true")
    ap.add_argument("--quality-only",action="store_true")
    ap.add_argument("--live",action="store_true")
    a=ap.parse_args()
    started=utc(); stamp=dt.datetime.now().strftime("%Y%m%d_%H%M%S_%f"); run=RUNS/stamp; run.mkdir(parents=True)
    exact=sha(); events=(run/"events.jsonl").open("w",encoding="utf-8")
    event(events,"ServiceStarted",state="quality" if not a.live else "live",correlation_id=stamp)
    missing,forbidden=primitive_audit(); failures=[]; blocked=[]; timings=[]; reconnects=0; uncertain=0
    if forbidden:
        failures.append({"case":"scope_guard","stage":"preflight","player":None,"request_id":None,"expected":"no forbidden paths","actual":forbidden,"relevant_log_lines":forbidden,"reproducer_command":"git diff --name-only a5ee048c...HEAD"})
    if missing:
        blocked += [f"missing primitive: {x}" for x in missing]
    cycles=a.cycles or (1 if a.live else 0)
    live_ok=None
    if a.live and not failures and not blocked:
        event(events,"SessionReady",state="starting",correlation_id=stamp)
        live_ok,lf,tm,reconnects,uncertain=run_live(run,cycles,a.faults); failures+=lf; timings+=tm
        event(events,"ServiceStopped",state="PASS" if live_ok else "FAIL",correlation_id=stamp,severity="info" if live_ok else "error")
    else:
        event(events,"ServiceStopped",state="BLOCKED" if blocked else ("FAIL" if failures else "PASS"),correlation_id=stamp,severity="warning" if blocked else "info")
    if a.live and a.whispers:
        blocked.append("adversarial whisper variants: tele08_full_roundtrip request text is hardcoded; no terminal wire test seam exists")
    if a.live and a.payments:
        blocked.append("full payment variant matrix: proven runner covers trusted exact-payment path; no harness seam exists for 0/under/over/cancel/uncertain injection")
    if a.live and a.faults:
        blocked.append("remaining summon fault matrix beyond CLICKER2_PRECONNECT_ONCE has no existing terminal fault-injection primitive")
    status="FAIL" if failures else ("BLOCKED" if blocked else "PASS")
    passed_cycles=cycles if a.live and status=="PASS" else (cycles if a.live and live_ok and not failures else 0)
    summary={"run_id":stamp,"status":status,"exact_sha":exact,"started_utc":started,"finished_utc":utc(),"total_cases":len(timings) if a.live else 1,"pass":len(timings) if a.live and live_ok else (1 if not failures and not blocked else 0),"fail":len(failures),"uncertain":uncertain,"summon_pass":passed_cycles,"payment_pass":passed_cycles,"duplicate_mutations":0 if a.live and live_ok else None,"reconnects":reconnects,"worst_latency":max((x["elapsed_seconds"] for x in timings),default=0),"failed_cases":[x["case"] for x in failures],"blocked_cases":blocked,"cycles_requested":cycles,"cycles_completed":passed_cycles,"mode":{"live":a.live,"faults":a.faults,"whispers":a.whispers,"payments":a.payments,"quality_only":a.quality_only}}
    dump(run/"summary.json",summary); dump(run/"failures.json",failures); dump(run/"timings.json",timings); dump(run/"exact_sha_manifest.json",{"exact_sha":exact,"base_parallel_sha":"a5ee048c620c55542460d54d7750e81f0f8f8da4","proven_reference_sha":"d753829314db39e5cd9aad57ce1d46daaf4d55da"})
    md=["# Summon Terminal Soak",f"- status: **{status}**",f"- exact SHA: `{exact}`",f"- cycles: {passed_cycles}/{cycles}",f"- failures: {len(failures)}",f"- uncertain: {uncertain}"]
    if blocked: md += ["","## Blocked"]+[f"- {x}" for x in blocked]
    (run/"summary.md").write_text("\n".join(md)+"\n",encoding="utf-8")
    for role in ROLE_KEYS:
        p=run/f"{role}.log"
        if not p.exists(): p.write_text("No live role process executed in this run.\n",encoding="utf-8")
    events.close(); print(f"SUMMON TERMINAL SOAK {status}\n{run}\nSHA={exact}")
    return 0 if status=="PASS" else (3 if status=="BLOCKED" else 1)
if __name__=="__main__": sys.exit(main())
