#!/usr/bin/env python3
"""One read-only live capture; verified bundle is handed to the archive publisher."""
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
import history_worker as w

def main():
    root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
    report={"source_commit":os.environ.get("GITHUB_SHA"),"account":"octowar1","character":"Smokinpole","mutation":"DISABLED","live_scan":"NOT_STARTED","checks":{}}
    code=1
    try:
        password=os.environ.get("WOW112_PASSWORD")
        if not password:
            report["failure_reason"]="MISSING_REPOSITORY_SECRET_WOW112_PASSWORD";return
        host="play.octowow.st"
        try:
            socket.getaddrinfo(host,3724,type=socket.SOCK_STREAM)
            report["checks"]["auth_dns"]="PASS"
        except OSError:
            report["failure_reason"]="AUTH_DNS_UNAVAILABLE";return
        try:
            with socket.create_connection((host,3724),timeout=15):pass
            report["checks"]["auth_tcp"]="PASS"
        except OSError:
            report["failure_reason"]="AUTH_TCP_UNREACHABLE";return
        env=dict(os.environ,WOW112_ACCOUNT="octowar1",WOW112_CHARACTER="Smokinpole",WOW112_REALM_INDEX="1",
            WOW112_AH_GUID="0xF130003D4100023A",WOW112_MAILBOX_GUID="0xF11002A4A5002A0C",
            WOW112_PRODUCER_ID="github-windows-live-validation",
            WOW112_MARKET_ID="live-test:octowow:realm-index1:pool-unverified:epoch-unspecified",
            WOW112_OWNER_HMAC_KEY=secrets.token_hex(32),WOW112_AH_FULL_SCAN_MAX_PAGES="2048")
        binary=Path(os.environ["WOW112_HISTORY_BINARY"])
        report["binary_sha256"]=hashlib.sha256(binary.read_bytes()).hexdigest()
        start=time.perf_counter()
        report["live_scan"]="RUNNING"
        try:
            process=subprocess.run([str(binary),"live",str(root/"capture")],env=env,capture_output=True,text=True,timeout=600)
        except subprocess.TimeoutExpired:
            report.update(live_scan="FAIL",failure_reason="LIVE_PROCESS_TIMEOUT");return
        report["seconds"]=round(time.perf_counter()-start,3)
        output=process.stdout+process.stderr
        for marker,name in [("[AUTH] SRP6 PASS","srp_auth"),("[WORLD] auth PASS","world_auth"),("SMSG_LOGIN_VERIFY_WORLD PASS","character_login"),("MSG_AUCTION_HELLO PASS","auction_house_open")]:
            report["checks"][name]="PASS" if marker in output else "NOT_REACHED"
        report["process_exit_code"]=process.returncode
        if process.returncode:
            error_lines=[line for line in process.stderr.splitlines() if line.startswith("[AH-HISTORY] ERROR: ")]
            if error_lines:
                detail=error_lines[-1][len("[AH-HISTORY] ERROR: "):][:512]
                for secret_value in (password,password.upper(),password.lower()):
                    if secret_value:detail=re.sub(re.escape(secret_value),"MASKED",detail,flags=re.IGNORECASE)
                safe_detail=re.sub(r"[^a-zA-Z0-9 _:=.()/,-]","",detail)
                report["terminal_error"] = safe_detail
            reasons=[("world auth rejected","WORLD_AUTH_REJECTED"),("auth connect failed","AUTH_CONNECT_FAILED"),("account has no characters","NO_CHARACTERS"),("character not found","CHARACTER_NOT_FOUND"),("invalid password","PASSWORD_FORMAT_INVALID"),("invalid auction tuple","INVALID_AUCTION_TUPLE"),("auction payload length mismatch","AUCTION_PAYLOAD_LENGTH_MISMATCH"),("not return MSG_AUCTION_HELLO","AUCTION_HOUSE_NOT_OPENED"),("truncated at page limit","SCAN_PAGE_LIMIT"),("world connect failed","WORLD_CONNECT_FAILED"),("already logged","ALREADY_LOGGED_IN"),("missing WOW112_","RUNTIME_CONFIG_MISSING")]
            report["failure_reason"]=next((reason for marker,reason in reasons if marker.lower() in output.lower()),"TERMINAL_FAILED_SEE_REACHED_STAGES")
            report["live_scan"]="FAIL"
        captures=list((root/"capture").glob("*.ndjson"))
        if len(captures)!=1:
            report["capture_count"]=len(captures)
            report["live_scan"]="FAIL"
            report.setdefault("failure_reason","CAPTURE_COUNT_MISMATCH")
            return
        events=w.read_segment(captures[0])
        report["pagination"]=w.pagination_metrics(events)
        report["owner_token_scope"]="scan_local"
        report["scan_id"]=events[0]["scan_id"]
        report["market_evidence"]=events[1].get("market_evidence") if len(events)>2 else None
        db=w.connect(root/"history.sqlite")
        result=w.ingest_events(db,events)
        report.update(live_scan="PASS" if process.returncode==0 else "FAIL",records=result["inserted"],quality=result["quality"],quality_reasons=result["reasons"],pages=events[-1]["pages"],status=events[-1]["status"])
        report["market_namespace"]="provisional_live_test"
        report["checks"]["sqlite_import"]="PASS"
        duplicate=w.ingest_events(db,events)
        if duplicate["state"]!="duplicate_noop":raise ValueError("duplicate import failed")
        report["checks"]["duplicate_import"]="PASS"
        bundle=w.export_bundle(db,root/"bundles")
        report["bundle_id"]=bundle.name
        restored=w.connect(root/"restored.sqlite")
        w.restore_bundle(restored,bundle)
        cutoff=events[-1]["observed_at_utc_ms"]+1
        first=w.view(db,events[0]["market_id"],cutoff)
        second=w.view(restored,events[0]["market_id"],cutoff)
        if first!=second:raise ValueError("restored view mismatch")
        report["checks"]["bundle_restore"]="PASS"
        report["view_id"]=first["view_id"]
        report["view_samples"]=len(first["samples"])
        report["raw_bytes"]=captures[0].stat().st_size
        report["gzip_bytes"]=(bundle/"events.ndjson.gz").stat().st_size
        restored.close();db.close();code=0 if process.returncode==0 else 1
    except Exception as e:
        report.update(live_scan="FAIL",failure_reason="HARNESS_ERROR",error_class=type(e).__name__)
    finally:
        if report["live_scan"]=="RUNNING" and code!=0:
            report["live_scan"]="FAIL"
            report.setdefault("failure_reason","PROCESS_INTERRUPTED")
        if "bundle_id" not in report:
            try:
                partials=list((root/"capture").glob("*.partial"))
                for partial in partials:w.recover(partial)
                paths=list((root/"capture").glob("*.ndjson"))
                if paths:
                    db=w.connect(root/"recovered.sqlite")
                    for path in paths:
                        events=w.read_segment(path)
                        result=w.ingest_events(db,events)
                        report.update(records=result.get("inserted",0),quality=result.get("quality","diagnostic_only"),quality_reasons=result.get("reasons",[]),pagination=w.pagination_metrics(events),status=events[-1]["status"],pages=events[-1]["pages"])
                    bundle=w.export_bundle(db,root/"bundles");db.close()
                    report["bundle_id"]=bundle.name
                    report["capture_recovery"]="PASS"
                    report["owner_token_scope"]="scan_local"
            except Exception as e:
                report["capture_recovery"]="FAIL";report["recovery_error_class"]=type(e).__name__
        (root/"LIVE_VALIDATION_SUMMARY.json").write_text(json.dumps(report,indent=2)+"\n")
        print(json.dumps(report,indent=2))
        sys.exit(code)

if __name__=="__main__":main()
