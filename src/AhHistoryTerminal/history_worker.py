#!/usr/bin/env python3
"""V0 local terminal history worker. Python standard library only; no trading."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time

MAX_RAW_BYTES = 128 * 1024 * 1024
U32 = 2**32 - 1

def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def connect(path):
    db = sqlite3.connect(path, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("PRAGMA foreign_keys=ON")
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version not in (0, 1):
        raise ValueError("unsupported database schema")
    db.executescript('''
    CREATE TABLE IF NOT EXISTS events(event_id TEXT PRIMARY KEY, scan_id TEXT NOT NULL,
      seq INTEGER NOT NULL, payload TEXT NOT NULL, sha256 TEXT NOT NULL, UNIQUE(scan_id,seq));
    CREATE TABLE IF NOT EXISTS scans(scan_id TEXT PRIMARY KEY, market TEXT NOT NULL,
      producer TEXT NOT NULL, source TEXT NOT NULL, scope TEXT NOT NULL, status TEXT NOT NULL,
      started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, quality TEXT NOT NULL,
      reasons TEXT NOT NULL, record_count INTEGER NOT NULL, unique_count INTEGER NOT NULL,
      segment_sha256 TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS observations(event_id TEXT NOT NULL REFERENCES events(event_id),
      record_index INTEGER NOT NULL, scan_id TEXT NOT NULL REFERENCES scans(scan_id),
      market TEXT NOT NULL, observed_ms INTEGER NOT NULL, auction_id INTEGER NOT NULL,
      item_id INTEGER NOT NULL, count INTEGER NOT NULL, buyout INTEGER NOT NULL,
      owner_token TEXT, start_bid INTEGER NOT NULL, current_bid INTEGER NOT NULL,
      min_increment INTEGER NOT NULL, time_left INTEGER NOT NULL,
      PRIMARY KEY(event_id,record_index));
    CREATE INDEX IF NOT EXISTS obs_market_item_time ON observations(market,item_id,observed_ms);
    CREATE INDEX IF NOT EXISTS obs_market_auction_time ON observations(market,auction_id,observed_ms);
    PRAGMA user_version=1;
    ''')
    return db

def integer(value, name, minimum=0, maximum=U32):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError("invalid " + name)
    return value

def validate(events):
    if len(events)<2 or events[0].get("event_type")!="ScanStarted" or events[-1].get("event_type")!="ScanFinished":
        raise ValueError("segment must contain ScanStarted..ScanFinished")
    first = events[0]
    for field in ("scan_id","market_id","producer_id","source","scope"):
        if not isinstance(first.get(field),str) or not first[field]: raise ValueError("invalid " + field)
    if first["source"] not in ("fixture","live"): raise ValueError("unsupported source")
    if first["source"] == "fixture" and not first["market_id"].startswith("fixture:"):
        raise ValueError("fixture data must use a fixture: market namespace")
    if first["scope"] not in ("full_market","targeted_item","revalidation_window"):
        raise ValueError("unsupported scan scope")
    previous_time = -1
    for seq,e in enumerate(events,1):
        if e.get("schema_version") != 1 or e.get("producer_seq") != seq:
            raise ValueError("schema or sequence mismatch")
        if e.get("event_id") != f'{first["scan_id"]}:{seq}': raise ValueError("event id mismatch")
        for field in ("scan_id","market_id","producer_id","source","scope"):
            if e.get(field)!=first[field]: raise ValueError("mixed segment identity")
        now=integer(e.get("observed_at_utc_ms"),"observed_at",0,2**63-1)
        if now<previous_time: raise ValueError("clock moved backwards")
        previous_time=now
        if e.get("event_type") not in ("ScanStarted","PageObserved","ScanFinished"):
            raise ValueError("unsupported event type")
        if 0<seq-1<len(events)-1 and e["event_type"]!="PageObserved":
            raise ValueError("unexpected control event")
    status=events[-1].get("status")
    if status not in ("completed","truncated","aborted","capture_failed"): raise ValueError("invalid scan status")
    pages=events[1:-1]
    if events[-1].get("pages")!=len(pages): raise ValueError("finish page count mismatch")
    seen={}; rows=[]; reasons=[]; totals=[]
    for expected,e in enumerate(pages):
        page=integer(e.get("page"),"page",0,4095)
        if page!=expected: reasons.append("page_gap_or_reorder")
        if e.get("listfrom") != page*50: raise ValueError("invalid listfrom")
        total=integer(e.get("total"),"total")
        totals.append(total)
        records=e.get("records")
        if not isinstance(records,list) or len(records)>50 or e.get("record_count")!=len(records):
            raise ValueError("invalid page records")
        for index,r in enumerate(records):
            if r.get("record_index")!=index: raise ValueError("record index mismatch")
            for f in ("auction_id","item_id","count"):
                integer(r.get(f),f,1)
            for f in ("buyout_total_copper","start_bid_copper","current_bid_copper","min_increment_copper","time_left_raw"):
                integer(r.get(f),f)
            token=r.get("owner_token")
            if token is not None and (not isinstance(token,str) or len(token)!=64 or any(c not in "0123456789abcdef" for c in token)):
                raise ValueError("invalid owner token")
            identity=(r["item_id"],r["count"],r["buyout_total_copper"],token)
            if r["auction_id"] in seen and seen[r["auction_id"]]!=identity:
                reasons.append("conflicting_auction_identity")
            seen[r["auction_id"]]=identity
            rows.append((e,index,r))
    if status!="completed": reasons.append("scan_"+status)
    if first["scope"]!="full_market": reasons.append("partial_scope")
    if first["source"]=="live" and first["market_id"].startswith("live-test:"):
        reasons.append("unverified_market_identity")
    if not pages or pages[-1]["record_count"]>=50: reasons.append("no_terminal_page")
    if any(e["record_count"]<50 for e in pages[:-1]): reasons.append("early_terminal_page")
    if totals and max(totals)-min(totals)>max(5,max(totals)//10): reasons.append("total_drift")
    if totals and len(seen)!=totals[-1]: reasons.append("unique_total_mismatch")
    if events[-1]["observed_at_utc_ms"]-first["observed_at_utc_ms"]>30*60*1000:
        reasons.append("scan_over_30_minutes")
    reasons=sorted(set(reasons))
    quality="eligible" if not reasons else "diagnostic_only"
    return first,status,quality,reasons,rows,len(seen)

def pagination_metrics(events):
    """Exact evidence for scan churn; does not relax eligibility rules."""
    validate(events)
    pages=events[1:-1]; totals=[e["total"] for e in pages]
    seen={}; duplicates=0; conflicts=0
    for page in pages:
        for row in page["records"]:
            identity=tuple(row.get(f) for f in ("item_id","count","buyout_total_copper","owner_token"))
            aid=row["auction_id"]
            if aid in seen:
                duplicates+=1; conflicts+=seen[aid]!=identity
            seen[aid]=identity
    return {"page_count":len(pages),"observations":sum(e["record_count"] for e in pages),
            "unique_auction_ids":len(seen),"duplicate_observations":duplicates,
            "conflicting_identity_observations":conflicts,
            "server_total_first":totals[0] if totals else None,"server_total_last":totals[-1] if totals else None,
            "server_total_min":min(totals) if totals else None,"server_total_max":max(totals) if totals else None,
            "unique_minus_last_total":len(seen)-totals[-1] if totals else None,
            "last_page_records":pages[-1]["record_count"] if pages else None,
            "duration_ms":events[-1]["observed_at_utc_ms"]-events[0]["observed_at_utc_ms"]}

def ingest_events(db, events):
    first,status,quality,reasons,rows,unique=validate(events)
    payloads=[canonical(e) for e in events]
    segment_hash=digest(("\n".join(payloads)+"\n").encode())
    existing=db.execute("SELECT segment_sha256 FROM scans WHERE scan_id=?",(first["scan_id"],)).fetchone()
    if existing:
        if existing[0]!=segment_hash: raise ValueError("conflicting segment under same scan_id")
        return {"state":"duplicate_noop","scan_id":first["scan_id"],"inserted":0}
    with db:
        db.execute("INSERT INTO scans VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",(
            first["scan_id"],first["market_id"],first["producer_id"],first["source"],first["scope"],status,
            first["observed_at_utc_ms"],events[-1]["observed_at_utc_ms"],quality,canonical(reasons),len(rows),unique,segment_hash))
        db.executemany("INSERT INTO events VALUES(?,?,?,?,?)",[(e["event_id"],first["scan_id"],e["producer_seq"],p,digest(p.encode())) for e,p in zip(events,payloads)])
        db.executemany("INSERT INTO observations VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[
            (e["event_id"],i,first["scan_id"],first["market_id"],e["observed_at_utc_ms"],r["auction_id"],r["item_id"],r["count"],r["buyout_total_copper"],r["owner_token"],r["start_bid_copper"],r["current_bid_copper"],r["min_increment_copper"],r["time_left_raw"]) for e,i,r in rows])
    return {"state":"imported","scan_id":first["scan_id"],"inserted":len(rows),"quality":quality,"reasons":reasons}

def read_segment(path):
    data=Path(path).read_bytes()
    if len(data)>MAX_RAW_BYTES: raise ValueError("segment too large")
    return [json.loads(line) for line in data.splitlines() if line]

def view(db,market,cutoff):
    # Exactly one full eligible scan per bucket. Completed before cutoff prevents future leakage.
    scans=db.execute("SELECT scan_id,started_ms,ended_ms,unique_count,source FROM scans WHERE market=? AND quality='eligible' AND ended_ms<=? ORDER BY started_ms,scan_id",(market,cutoff)).fetchall()
    chosen={}
    for scan in scans: chosen[scan[1]//1800000]=scan
    samples=[]
    for bucket,scan in sorted(chosen.items()):
        # Latest observation per auction within the selected scan, no duplicate supply.
        records=db.execute("SELECT auction_id,item_id,count,buyout,owner_token,observed_ms FROM observations WHERE scan_id=? ORDER BY observed_ms,event_id,record_index",(scan[0],)).fetchall()
        auctions={r[0]:r for r in records}
        items={}
        for r in auctions.values():
            x=items.setdefault(r[1],{"item_id":r[1],"listings":0,"units":0,"buyout_listings":0,"buyout_units":0,"prices":[],"sellers":set(),"last_observed_ms":0})
            x["listings"]+=1;x["units"]+=r[2];x["last_observed_ms"]=max(x["last_observed_ms"],r[5])
            if r[4]:x["sellers"].add(r[4])
            if r[3]>0:x["buyout_listings"]+=1;x["buyout_units"]+=r[2];x["prices"].append((r[3],r[2]))
        from fractions import Fraction
        for item,x in sorted(items.items()):
            prices=sorted(x.pop("prices"),key=lambda t:Fraction(t[0],t[1]))
            def price_at(percentile):
                if not prices:return None
                n,d=prices[((len(prices)-1)*percentile)//100]
                return {"numerator_copper":n,"denominator_units":d}
            x["seller_tokens"]=len(x.pop("sellers"));x["offer_p10"]=price_at(10);x["offer_p50"]=price_at(50);x["offer_p90"]=price_at(90)
            x.update(bucket_utc_ms=bucket*1800000,scan_id=scan[0],source=scan[4])
            samples.append(x)
    out={"schema_version":1,"algorithm_version":"v0-latest-eligible-per-bucket/listing-order-statistics","market_id":market,"cutoff_ms":cutoff,"samples":samples}
    out["view_id"]=digest(canonical(out).encode())
    return out

def export_bundle(db,outdir):
    events=[json.loads(r[0]) for r in db.execute("SELECT payload FROM events ORDER BY scan_id,seq")]
    raw=("\n".join(canonical(e) for e in events)+"\n").encode()
    if len(raw)>MAX_RAW_BYTES:raise ValueError("V0 bundle size limit; split database export")
    bundle_id=digest(raw)
    out=Path(outdir)/bundle_id
    if out.exists():
        verify_bundle(out)
        return out
    Path(outdir).mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="bundle-",dir=outdir))
    data=gzip.compress(raw,mtime=0)
    (temp/"events.ndjson.gz").write_bytes(data)
    manifest={"schema_version":1,"bundle_id":bundle_id,"event_count":len(events),"raw_bytes":len(raw),"files":[{"name":"events.ndjson.gz","sha256":digest(data),"bytes":len(data)}]}
    (temp/"manifest.json").write_text(canonical(manifest)+"\n")
    os.rename(temp,out)
    return out

def verify_bundle(path):
    path=Path(path)
    m=json.loads((path/"manifest.json").read_text())
    if m.get("schema_version")!=1 or len(m.get("files",[]))!=1:raise ValueError("unsupported bundle")
    f=m["files"][0]
    if f.get("name")!="events.ndjson.gz":raise ValueError("invalid bundle file name")
    raw_size=integer(m.get("raw_bytes"),"raw_bytes",1,MAX_RAW_BYTES)
    data=(path/f["name"]).read_bytes()
    if len(data)!=f["bytes"] or digest(data)!=f["sha256"]:raise ValueError("bundle hash mismatch")
    import io
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as z:raw=z.read(raw_size+1)
    if len(raw)!=raw_size or digest(raw)!=m["bundle_id"]:raise ValueError("bundle content mismatch")
    events=[json.loads(line) for line in raw.splitlines() if line]
    if len(events)!=m["event_count"]:raise ValueError("bundle count mismatch")
    return events

def restore_bundle(db,path):
    events=verify_bundle(path)
    groups={}
    for e in events:groups.setdefault(e["scan_id"],[]).append(e)
    for group in groups.values():validate(group)
    # Entire bundle restore is atomic, including multiple scans.
    db.execute("SAVEPOINT restore_bundle")
    try:
        results=[ingest_events_no_commit(db,g) for g in groups.values()]
        db.execute("RELEASE restore_bundle")
        return results
    except Exception:
        db.execute("ROLLBACK TO restore_bundle");db.execute("RELEASE restore_bundle");raise

def ingest_events_no_commit(db,events):
    # Proxy keeps ingest's context manager from committing an outer restore transaction.
    class Proxy:
        def __getattr__(self,n):return getattr(db,n)
        def __enter__(self):return self
        def __exit__(self,*args):return False
    return ingest_events(Proxy(),events)

def recover(path):
    path=Path(path)
    if not path.name.endswith(".partial"):raise ValueError("recovery only accepts .partial")
    target=Path(str(path)[:-len(".partial")])
    if target.exists():raise ValueError("recovered target already exists")
    data=path.read_bytes()
    if len(data)>MAX_RAW_BYTES:raise ValueError("partial too large")
    lines=data.splitlines(keepends=True)
    events=[]
    for index,line in enumerate(lines):
        try:events.append(json.loads(line))
        except json.JSONDecodeError:
            if index!=len(lines)-1:raise ValueError("corrupt interior recovery line")
    if not events or events[0].get("event_type")!="ScanStarted":raise ValueError("no recoverable scan")
    if events[-1].get("event_type")!="ScanFinished":
        e=dict(events[0]);e.update(event_type="ScanFinished",producer_seq=len(events)+1,event_id=f'{e["scan_id"]}:{len(events)+1}',status="aborted",reason="recovered_partial",pages=len(events)-1,observed_at_utc_ms=max(int(time.time()*1000),events[-1]["observed_at_utc_ms"]))
        events.append(e)
    validate(events)
    with target.open("x") as f:
        f.write("\n".join(canonical(e) for e in events)+"\n");f.flush();os.fsync(f.fileno())
    return target

def main():
    ap=argparse.ArgumentParser();sub=ap.add_subparsers(dest="command",required=True)
    p=sub.add_parser("ingest");p.add_argument("db");p.add_argument("segment")
    p=sub.add_parser("view");p.add_argument("db");p.add_argument("market");p.add_argument("--cutoff-ms",type=int,default=int(time.time()*1000))
    p=sub.add_parser("export");p.add_argument("db");p.add_argument("output_dir")
    p=sub.add_parser("restore");p.add_argument("db");p.add_argument("bundle")
    p=sub.add_parser("recover");p.add_argument("partial")
    args=ap.parse_args()
    if args.command=="recover": print(recover(args.partial));return
    db=connect(args.db)
    try:
        if args.command=="ingest":print(canonical(ingest_events(db,read_segment(args.segment))))
        elif args.command=="view":print(canonical(view(db,args.market,args.cutoff_ms)))
        elif args.command=="export":print(export_bundle(db,args.output_dir))
        elif args.command=="restore":print(canonical(restore_bundle(db,args.bundle)))
    finally:db.close()

if __name__=="__main__":main()
