#!/usr/bin/env python3
"""Immutable, verified per-scan GitHub Release archive. No credentials in files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import history_worker as w

PREFIX = "ah-history-v1-"
MAX_FILE = 128 * 1024 * 1024

class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected=super().redirect_request(req,fp,code,msg,headers,newurl)
        if redirected is not None and urllib.parse.urlsplit(req.full_url).netloc!=urllib.parse.urlsplit(newurl).netloc:
            redirected.remove_header("Authorization")
        return redirected

class GitHubArchive:
    def __init__(self, repository, token=None, api="https://api.github.com", upload="https://uploads.github.com"):
        if len(repository.split("/")) != 2 or any(not s or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-" for c in s) for s in repository.split("/")):
            raise ValueError("invalid repository")
        self.repo=repository; self.token=token
        self.api=api.rstrip("/"); self.upload=upload.rstrip("/")

    def request(self, path, method="GET", data=None, content_type="application/json", upload=False, binary=False):
        base=self.upload if upload else self.api
        headers={"Accept":"application/octet-stream" if binary else "application/vnd.github+json", "User-Agent":"wow112-ah-history", "X-GitHub-Api-Version":"2022-11-28"}
        if self.token: headers["Authorization"]="Bearer "+self.token
        if data is not None: headers["Content-Type"]=content_type
        req=urllib.request.Request(base+path, data=data, headers=headers, method=method)
        with urllib.request.build_opener(SafeRedirect()).open(req, timeout=120) as response:
            raw=response.read(MAX_FILE+1)
        if len(raw)>MAX_FILE: raise ValueError("remote file too large")
        return raw if binary else json.loads(raw)

    def release(self, tag):
        try: return self.request(f"/repos/{self.repo}/releases/tags/{tag}")
        except urllib.error.HTTPError as e:
            if e.code!=404: raise
            return None

    def assets(self, release_id):
        # Exactly two data assets plus one informational receipt are expected.
        return self.request(f"/repos/{self.repo}/releases/{release_id}/assets?per_page=100")

    def download(self, asset):
        if asset.get("size",MAX_FILE+1)>MAX_FILE: raise ValueError("remote asset too large")
        return self.request(f"/repos/{self.repo}/releases/assets/{asset['id']}", binary=True)

    def publish(self, bundle, receipt, outbox):
        bundle=Path(bundle); outbox=Path(outbox)
        events=w.verify_bundle(bundle)
        manifest=json.loads((bundle/"manifest.json").read_text())
        if len({e["scan_id"] for e in events})!=1 or any(e["source"]!="live" for e in events):
            raise ValueError("publisher requires exactly one live scan")
        tag=PREFIX+manifest["bundle_id"]
        # Durable local intent; an Actions artifact also retains it on failed upload.
        intent={"schema_version":1,"tag":tag,"bundle_id":manifest["bundle_id"],"state":"pending"}
        self.write_state(outbox,intent)
        release=self.release(tag)
        if release is None:
            body={"tag_name":tag,"target_commitish":os.environ.get("GITHUB_SHA","dev/windows-ah-canonical"),"name":"AH observation bundle "+manifest["bundle_id"][:16],"body":"Terminal-only AH observations. Prices are observations, not confirmed sales. Market namespace is provisional; owner tokens are scan-local. See receipt.json for scan quality.","draft":False,"prerelease":True,"make_latest":"false"}
            release=self.request(f"/repos/{self.repo}/releases",method="POST",data=json.dumps(body).encode())
        assets={a["name"]:a for a in self.assets(release["id"])}
        # Receipt is informational: never used to authorize/validate data.
        files={name:(bundle/name).read_bytes() for name in ("events.ndjson.gz","manifest.json")}
        files["receipt.json"]=(json.dumps(receipt,sort_keys=True,indent=2)+"\n").encode()
        for name,raw in files.items():
            if name not in assets:
                assets[name]=self.request(f"/repos/{self.repo}/releases/{release['id']}/assets?name={urllib.parse.quote(name)}",method="POST",data=raw,content_type="application/octet-stream",upload=True)
            remote=self.download(assets[name])
            if name!="receipt.json" and hashlib.sha256(remote).digest()!=hashlib.sha256(raw).digest():
                raise ValueError("immutable remote asset conflict")
        # Verify remotely retrieved bundle with the worker, not just API metadata.
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)
            for name in ("manifest.json","events.ndjson.gz"): (path/name).write_bytes(self.download(assets[name]))
            w.verify_bundle(path)
        intent.update(state="verified",release_url=release["html_url"])
        self.write_state(outbox,intent)
        return intent

    @staticmethod
    def write_state(path,state):
        path.parent.mkdir(parents=True,exist_ok=True)
        temp=path.with_suffix(".tmp")
        with temp.open("w",encoding="utf-8") as f:
            json.dump(state,f,indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(temp,path)

    def restore(self, database):
        releases=[]; page=1
        while True:
            batch=self.request(f"/repos/{self.repo}/releases?per_page=100&page={page}")
            releases.extend(r for r in batch if r["tag_name"].startswith(PREFIX))
            if len(batch)<100: break
            page+=1
        db=w.connect(database); result={"restored":0,"duplicate":0,"incomplete":0}
        try:
            for release in sorted(releases,key=lambda r:r["tag_name"]):
                assets={a["name"]:a for a in self.assets(release["id"])}
                if not {"manifest.json","events.ndjson.gz"}<=assets.keys():
                    result["incomplete"]+=1; continue
                with tempfile.TemporaryDirectory() as temp:
                    path=Path(temp)
                    for name in ("manifest.json","events.ndjson.gz"): (path/name).write_bytes(self.download(assets[name]))
                    manifest=json.loads((path/"manifest.json").read_text())
                    if release["tag_name"]!=PREFIX+manifest["bundle_id"]: raise ValueError("release identity mismatch")
                    states=w.restore_bundle(db,path)
                    result["restored"]+=sum(s["state"]=="imported" for s in states)
                    result["duplicate"]+=sum(s["state"]=="duplicate_noop" for s in states)
        finally: db.close()
        return result

def main():
    p=argparse.ArgumentParser(); p.add_argument("command",choices=["publish","publish-run","restore"]); p.add_argument("path"); p.add_argument("--repository",default=os.environ.get("GITHUB_REPOSITORY","github12wykrzyk/wow112")); p.add_argument("--receipt"); p.add_argument("--outbox",default="archive-outbox.json")
    a=p.parse_args(); archive=GitHubArchive(a.repository,os.environ.get("GITHUB_TOKEN"))
    if a.command=="restore": result=archive.restore(a.path)
    elif a.command=="publish-run":
        root=Path(a.path); summary=root/"LIVE_VALIDATION_SUMMARY.json"
        receipt=json.loads(summary.read_text()); bundle=root/"bundles"/receipt["bundle_id"]
        try:
            result=archive.publish(bundle,receipt,root/"archive-outbox.json")
            receipt["archive"]=result
        except Exception as e:
            receipt["archive"]={"state":"pending","error_class":type(e).__name__}
            summary.write_text(json.dumps(receipt,indent=2)+"\n")
            raise SystemExit("Archive publication failed; bundle retained in recovery artifact")
        summary.write_text(json.dumps(receipt,indent=2)+"\n")
    else:
        receipt=json.loads(Path(a.receipt).read_text()) if a.receipt else {}
        result=archive.publish(a.path,receipt,a.outbox)
    print(json.dumps(result,indent=2))

if __name__=="__main__": main()
