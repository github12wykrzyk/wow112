#!/usr/bin/env python3
"""Archive lifecycle tests with an in-memory GitHub REST fixture; no secrets."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import urllib.request
import github_archive as a
import history_worker as w

class MemoryGitHub(a.GitHubArchive):
    def __init__(self):
        super().__init__("test/repo")
        self.releases={};self.raw={};self.next_id=1;self.fail_upload=False

    def request(self,path,method="GET",data=None,content_type=None,upload=False,binary=False):
        route=path.split("?")[0]; parts=route.split("/"); result=None
        if "/tags/" in route:
            return next((copy.deepcopy(r) for r in self.releases.values() if r["tag_name"]==parts[-1]),None)
        if parts[-1]=="releases":
            if method=="GET": return list(copy.deepcopy(self.releases).values())
            result=json.loads(data); result.update(id=self.next_id,html_url="https://example.test/"+str(self.next_id));self.next_id+=1
            self.releases[result["id"]]=result
        elif parts[-1]=="assets" and not binary:
            rid=int(parts[-2])
            if method=="GET": return [{"id":aid,"name":name,"size":len(raw)} for aid,(release,name,raw) in self.raw.items() if release==rid]
            if self.fail_upload:
                self.fail_upload=False; raise ConnectionError("simulated upload outage")
            name=a.urllib.parse.parse_qs(path.split("?",1)[1])["name"][0]
            aid=self.next_id;self.next_id+=1;self.raw[aid]=(rid,name,data)
            result={"id":aid,"name":name,"size":len(data)}
        elif binary: return self.raw[int(parts[-1])][2]
        else: raise AssertionError(path)
        return copy.deepcopy(result)

def events(scan="one"):
    common={"schema_version":1,"scan_id":scan,"market_id":"synthetic:archive:realm1:pool1:epoch1","producer_id":"tests","source":"live","scope":"full_market"}
    row={"record_index":0,"auction_id":1,"item_id":10940,"count":2,"buyout_total_copper":40,"start_bid_copper":10,"current_bid_copper":0,"min_increment_copper":1,"time_left_raw":1000,"owner_token":None}
    payloads=[{"event_type":"ScanStarted"},{"event_type":"PageObserved","page":0,"listfrom":0,"total":1,"record_count":1,"records":[row]},{"event_type":"ScanFinished","pages":1,"status":"completed"}]
    return [dict(common,**p,event_id=f"{scan}:{i}",producer_seq=i,observed_at_utc_ms=1000+i) for i,p in enumerate(payloads,1)]

class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name); self.api=MemoryGitHub()
        db=w.connect(self.root/"one.sqlite");w.ingest_events(db,events());self.bundle=w.export_bundle(db,self.root/"bundles");db.close()
        self.outbox=self.root/"outbox.json"

    def tearDown(self): self.temp.cleanup()

    def publish(self): return self.api.publish(self.bundle,{"quality":"eligible"},self.outbox)

    def test_idempotent_verified_upload_and_restore(self):
        self.assertEqual(self.publish()["state"],"verified");self.publish()
        self.assertEqual(len(self.api.releases),1);self.assertEqual(len(self.api.raw),3)
        dest=self.root/"restore.sqlite"
        self.assertEqual(self.api.restore(dest)["restored"],1)
        self.assertEqual(self.api.restore(dest)["duplicate"],1)

    def test_pending_upload_can_resume(self):
        self.api.fail_upload=True
        with self.assertRaises(ConnectionError):self.publish()
        self.assertEqual(json.loads(self.outbox.read_text())["state"],"pending")
        self.assertEqual(self.api.restore(self.root/"pending.sqlite")["incomplete"],1)
        self.assertEqual(self.publish()["state"],"verified")
        self.assertEqual(len(self.api.releases),1)

    def test_remote_conflict_never_overwritten_or_acknowledged(self):
        self.publish();aid=next(k for k,v in self.api.raw.items() if v[1]=="events.ndjson.gz")
        rid,name,raw=self.api.raw[aid];self.api.raw[aid]=(rid,name,raw+b"corrupt")
        with self.assertRaises(ValueError):self.publish()
        self.assertEqual(json.loads(self.outbox.read_text())["state"],"pending")
        with self.assertRaises(ValueError):self.api.restore(self.root/"corrupt.sqlite")
        db=w.connect(self.root/"corrupt.sqlite");self.assertEqual(db.execute("SELECT COUNT(*) FROM scans").fetchone()[0],0);db.close()

    def test_two_independent_runs_build_history(self):
        self.publish(); db=w.connect(self.root/"two.sqlite");w.ingest_events(db,events("two"));other=w.export_bundle(db,self.root/"bundles");db.close()
        self.api.publish(other,{},self.root/"outbox-two.json")
        self.assertEqual(self.api.restore(self.root/"history.sqlite")["restored"],2)
        db=w.connect(self.root/"history.sqlite");self.assertEqual(db.execute("SELECT COUNT(*) FROM observations").fetchone()[0],2);db.close()

    def test_fixture_rejected_by_publisher(self):
        fixture=events("fixture")
        for e in fixture:e.update(source="fixture",market_id="fixture:archive")
        db=w.connect(self.root/"fixture.sqlite");w.ingest_events(db,fixture);bundle=w.export_bundle(db,self.root/"bundles");db.close()
        with self.assertRaises(ValueError):self.api.publish(bundle,{},self.outbox)
        self.assertFalse(self.api.releases)

    def test_pagination_metrics_preserve_strict_quality_gate(self):
        es=events();es[1]["total"]=2
        metrics=w.pagination_metrics(es)
        self.assertEqual(metrics["unique_minus_last_total"],-1)
        self.assertEqual(w.validate(es)[2],"diagnostic_only")
        self.assertIn("unique_total_mismatch",w.validate(es)[3])

    def test_redirect_drops_authorization(self):
        req=urllib.request.Request("https://api.github.com/example",headers={"Authorization":"Bearer synthetic-test"})
        redirected=a.SafeRedirect().redirect_request(req,None,302,"Found",{},"https://release-assets.githubusercontent.com/file")
        self.assertIsNone(redirected.get_header("Authorization"))

    def test_unverified_market_cannot_feed_decision_statistics(self):
        es=events()
        for e in es:e["market_id"]="live-test:unverified"
        db=w.connect(self.root/"unverified.sqlite")
        result=w.ingest_events(db,es)
        self.assertEqual(result["quality"],"diagnostic_only")
        self.assertIn("unverified_market_identity",result["reasons"])
        self.assertFalse(w.view(db,es[0]["market_id"],99999)["samples"])
        db.close()

if __name__=="__main__":unittest.main(verbosity=2)
