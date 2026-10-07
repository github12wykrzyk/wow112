#!/usr/bin/env python3
"""Run compiled terminal against a loopback fixture, then exercise the real worker."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("worker",ROOT/"history_worker.py")
w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
BINARY=Path(os.environ.get("WOW112_HISTORY_BINARY", str(ROOT/"target/release"/("wow112-ah-history.exe" if os.name=="nt" else "wow112-ah-history"))))
ENV=dict(os.environ,WOW112_MARKET_ID="fixture:octo:test:pool1:epoch1",WOW112_PRODUCER_ID="autonomous-local",WOW112_OWNER_HMAC_KEY="test-fixture-key-never-use-live-000000000000")
checks=[]
def check(name, fn):
    start=time.perf_counter();detail=fn();elapsed=time.perf_counter()-start
    checks.append({"name":name,"status":"PASS","seconds":round(elapsed,3),"detail":detail})
    print(f"PASS {name} ({elapsed:.2f}s)",flush=True)

def recv_exact(conn,n):
    out=b""
    while len(out)<n:
        part=conn.recv(n-len(out))
        if not part:raise EOFError()
        out+=part
    return out

def auction(i,bad=False):
    raw=bytearray(64)
    for offset,value in [(0,i+1),(4,10940+i%20),(20,0 if bad else 1+i%20),(36,10),(40,1),(44,0 if i%7==0 else (i%1000+1)*37),(48,3600000),(60,10)]:
        struct.pack_into("<I",raw,offset,value)
    struct.pack_into("<Q",raw,28,5000+i%17)
    return raw

def capture(destination,count,max_pages=None,bad=False,kill=False):
    sock=socket.socket();sock.bind(("127.0.0.1",0));sock.listen(1);sock.settimeout(10)
    port=sock.getsockname()[1];requests=[];errors=[];first=threading.Event();stop=threading.Event()
    def serve():
        try:
            with sock.accept()[0] as conn:
                conn.settimeout(10)
                while True:
                    opcode,page=struct.unpack("<II",recv_exact(conn,8));requests.append(opcode)
                    if opcode!=0x0258:raise ValueError("unexpected mutation opcode")
                    n=min(50,max(0,count-page*50))
                    payload=struct.pack("<I",n)+b"".join(auction(page*50+i,bad) for i in range(n))+struct.pack("<I",count)
                    conn.sendall(struct.pack("<I",len(payload))+payload)
                    if kill:
                        first.set();stop.wait(10);return
                    if n<50:return
        except (EOFError,ConnectionResetError,BrokenPipeError):pass
        except Exception as e:errors.append(repr(e))
        finally:sock.close()
    thread=threading.Thread(target=serve,daemon=True);thread.start()
    args=[str(BINARY),"fixture-wire",f"127.0.0.1:{port}",str(destination)]
    if max_pages is not None:args.append(str(max_pages))
    start=time.perf_counter()
    if kill:
        process=subprocess.Popen(args,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert first.wait(10)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            paths=list(Path(destination).glob("*.partial"))
            if paths and paths[0].read_bytes().count(b"\n")>=2:break
            time.sleep(.01)
        process.kill();stdout,stderr=process.communicate(timeout=5);stop.set();code=process.returncode
    else:
        process=subprocess.run(args,env=ENV,capture_output=True,text=True,timeout=90)
        stdout,stderr,code=process.stdout,process.stderr,process.returncode
    thread.join(10);assert not thread.is_alive();assert not errors,errors
    return {"code":code,"stdout":str(stdout),"stderr":str(stderr),"requests":len(requests),"only_read_opcode":all(x==0x0258 for x in requests),"seconds":time.perf_counter()-start}

def expect_error(fn):
    try:fn()
    except (ValueError,KeyError):return
    raise AssertionError("expected validation failure")

def main():
    destination=Path(sys.argv[1]) if len(sys.argv)>1 else Path(tempfile.mkdtemp(prefix="ah-history-tests-"))
    destination.mkdir(parents=True,exist_ok=True)
    state={}
    def full():
        result=capture(destination/"full",60000)
        assert result["code"]==0,result
        assert result["requests"]==1201 and result["only_read_opcode"]
        segment=next((destination/"full").glob("*.ndjson"))
        events=w.read_segment(segment)
        db=w.connect(destination/"history.sqlite")
        outcome=w.ingest_events(db,events)
        assert outcome["inserted"]==60000 and outcome["quality"]=="eligible",outcome
        assert db.execute("SELECT COUNT(*) FROM observations WHERE buyout=0").fetchone()[0]>0
        state.update(db=db,events=events,segment=segment)
        return {"records":60000,"pages":1201,"capture_seconds":round(result["seconds"],3),"raw_bytes":segment.stat().st_size,"buyout_zero_retained":True}
    check("compiled_terminal_full_scan_60000",full)
    def dedup():
        out=w.ingest_events(state["db"],state["events"])
        assert out["state"]=="duplicate_noop"
        assert state["db"].execute("SELECT COUNT(*) FROM observations").fetchone()[0]==60000
        return out
    check("duplicate_segment_noop",dedup)
    def conflict():
        events=copy.deepcopy(state["events"]);events[1]["records"][0]["buyout_total_copper"]=123
        expect_error(lambda:w.ingest_events(state["db"],events))
        assert state["db"].execute("SELECT COUNT(*) FROM scans").fetchone()[0]==1
    check("conflicting_segment_rejected",conflict)
    def export_restore():
        db=state["db"];bundle=w.export_bundle(db,destination/"bundles")
        restored=w.connect(destination/"restored.sqlite")
        result=w.restore_bundle(restored,bundle)
        assert result[0]["inserted"]==60000
        cutoff=state["events"][-1]["observed_at_utc_ms"]+1
        view=w.view(db,ENV["WOW112_MARKET_ID"],cutoff)
        assert len(view["samples"])==20
        assert w.view(restored,ENV["WOW112_MARKET_ID"],cutoff)==view
        assert w.restore_bundle(restored,bundle)[0]["state"]=="duplicate_noop"
        state.update(bundle=bundle,view=view,cutoff=cutoff)
        restored.close()
        return {"gzip_bytes":(bundle/"events.ndjson.gz").stat().st_size,"view_id":view["view_id"],"items":20}
    check("bundle_restore_identical_view",export_restore)
    def tampered():
        copied=destination/"tampered";shutil.copytree(state["bundle"],copied)
        p=copied/"events.ndjson.gz";data=bytearray(p.read_bytes());data[len(data)//2]^=1;p.write_bytes(data)
        db=w.connect(destination/"tampered.sqlite")
        expect_error(lambda:w.restore_bundle(db,copied))
        assert db.execute("SELECT COUNT(*) FROM events").fetchone()[0]==0;db.close()
    check("corrupt_bundle_rejected_before_import",tampered)
    def truncated():
        result=capture(destination/"truncated",200,max_pages=2)
        assert result["code"]!=0
        events=w.read_segment(next((destination/"truncated").glob("*.ndjson")))
        out=w.ingest_events(state["db"],events)
        assert out["quality"]=="diagnostic_only" and "scan_truncated" in out["reasons"]
    check("page_limit_never_full",truncated)
    def bad_count():
        result=capture(destination/"invalid",10,bad=True)
        assert result["code"]!=0 and "invalid auction tuple" in result["stderr"]
        events=w.read_segment(next((destination/"invalid").glob("*.ndjson")))
        assert w.ingest_events(state["db"],events)["quality"]=="diagnostic_only"
    check("zero_count_parser_rejected",bad_count)
    def killed():
        result=capture(destination/"killed",200,kill=True)
        assert result["code"]!=0
        partial=next((destination/"killed").glob("*.partial"))
        with partial.open("ab") as f:f.write(b'{"broken_tail":')
        fixed=w.recover(partial)
        out=w.ingest_events(state["db"],w.read_segment(fixed))
        assert out["quality"]=="diagnostic_only" and "scan_aborted" in out["reasons"]
        return {"recovered_status":"aborted","records":out["inserted"]}
    check("process_kill_partial_recovery",killed)
    def target_scope():
        events=copy.deepcopy(state["events"][:3])
        # Build a valid small observation window from one page.
        events=[events[0],events[1],copy.deepcopy(state["events"][-1])]
        for i,e in enumerate(events,1):
            e.update(scan_id="target-window-test",event_id=f"target-window-test:{i}",producer_seq=i,scope="revalidation_window")
        events[-1]["pages"]=1
        out=w.ingest_events(state["db"],events)
        assert out["quality"]=="diagnostic_only" and "partial_scope" in out["reasons"]
    check("target_window_excluded_from_market",target_scope)
    def freshness():
        early=state["events"][0]["observed_at_utc_ms"]-1
        assert w.view(state["db"],ENV["WOW112_MARKET_ID"],early)["samples"]==[]
        assert w.view(state["db"],"fixture:other-server",state["cutoff"])["samples"]==[]
    check("cutoff_and_market_isolation",freshness)
    def crash_import():
        crash_db=destination/"crash.sqlite"
        program='''import importlib.util,os,sys
spec=importlib.util.spec_from_file_location("w",sys.argv[1]);w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
db=w.connect(sys.argv[2])
class Crash:
 def __getattr__(self,n):return getattr(db,n)
 def __enter__(self):return self
 def __exit__(self,*a):return False
 def executemany(self,*a):
  db.executemany(*a);os._exit(42)
w.ingest_events(Crash(),w.read_segment(sys.argv[3]))
'''
        result=subprocess.run([sys.executable,"-c",program,str(ROOT/"history_worker.py"),str(crash_db),str(state["segment"])],timeout=30)
        assert result.returncode==42
        db=w.connect(crash_db)
        assert db.execute("SELECT COUNT(*) FROM scans").fetchone()[0]==0
        assert db.execute("SELECT COUNT(*) FROM events").fetchone()[0]==0
        assert w.ingest_events(db,state["events"])["inserted"]==60000;db.close()
    check("killed_import_transaction_rollback_and_retry",crash_import)
    def multiple_sources():
        # Distinct scans remain observations, but one representative per time bucket.
        base=copy.deepcopy(state["events"])
        for e in base:
            e.update(scan_id="second-producer",event_id=f'second-producer:{e["producer_seq"]}',producer_id="second")
        out=w.ingest_events(state["db"],base);assert out["inserted"]==60000
        v=w.view(state["db"],ENV["WOW112_MARKET_ID"],state["cutoff"])
        assert len(v["samples"])==20
        assert sum(x["listings"] for x in v["samples"])==60000
    check("multi_producer_no_double_supply",multiple_sources)
    state["db"].close()
    report={"status":"PASS","live_server_scan":"NOT_RUN_DNS_UNAVAILABLE_AND_NO_CREDENTIALS","source_sha":"f78d4305a4c12fde33767cad85d94f755c1e120a","fixture_data":True,"checks":checks}
    (destination/"AUTONOMOUS_TEST_REPORT.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({"status":"PASS","checks":len(checks),"report":str(destination/"AUTONOMOUS_TEST_REPORT.json")}))

if __name__=="__main__":main()
