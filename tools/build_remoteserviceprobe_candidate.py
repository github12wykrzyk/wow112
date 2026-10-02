#!/usr/bin/env python3
"""Build RemoteServiceProbe 5875 and append it to the verified candidate ZIP."""
import argparse, json, os, tempfile, time, zipfile
from pathlib import Path
from build_active_module import build_one, sha256_file

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"src/RemoteServiceProbe/WoWRemoteServiceProbe_5875_v1.c"
DLL_NAME="WoWRemoteServiceProbe_5875_v1.dll"
DLL_LIST="dlls.txt"
PROFILE="clangcl_i686_win32imports"

def repack(package,dll):
    with zipfile.ZipFile(package,"r") as src:
        rows=[(i.filename,src.read(i.filename)) for i in src.infolist()
              if i.filename not in (DLL_NAME,DLL_LIST)]
    loader=[];seen=set()
    for name,_ in rows:
        if "/" in name.rstrip("/") or not name.lower().endswith(".dll"): continue
        k=name.lower()
        if k not in seen: seen.add(k);loader.append(name)
    if DLL_NAME.lower() not in seen: loader.append(DLL_NAME)
    rows.append((DLL_NAME,Path(dll).read_bytes()))
    rows.append((DLL_LIST,("\r\n".join(loader)+"\r\n").encode("ascii")))
    fd,tmp=tempfile.mkstemp(prefix="wow112-rsp-",suffix=".zip",dir=str(Path(package).parent));os.close(fd)
    temp=Path(tmp)
    try:
        with zipfile.ZipFile(temp,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9) as dst:
            for name,data in rows:
                info=zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0))
                info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
                dst.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
        os.replace(temp,package)
    finally:
        if temp.exists(): temp.unlink()
    return loader

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--compile-only",action="store_true")
    ap.add_argument("--package",default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata",default="dist/candidate_metadata.json")
    ap.add_argument("--summary",default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata",default="dist/remoteserviceprobe_build.json")
    ap.add_argument("--output",default="build/"+DLL_NAME)
    a=ap.parse_args()
    t0=time.perf_counter();out=(ROOT/a.output).resolve();out.parent.mkdir(parents=True,exist_ok=True)
    bm=(ROOT/a.build_metadata).resolve();bm.parent.mkdir(parents=True,exist_ok=True)
    timing,pe=build_one(PROFILE,SOURCE,out.with_suffix(".obj"),out)
    if pe.get("machine_hex")!="0x014C" or not pe.get("entrypoint_rva") or not pe.get("has_import_directory"):
        raise SystemExit("RemoteServiceProbe PE32/x86/win32imports gate failed")
    module={"name":DLL_NAME,"source_path":str(SOURCE.relative_to(ROOT)).replace("\\","/"),
            "source_sha256":sha256_file(SOURCE),"build_profile":PROFILE,"toolchain_mode":timing.get("mode"),
            "sha256":sha256_file(out),"size":out.stat().st_size,"pe_machine":pe.get("machine_hex"),
            "entrypoint_rva":pe.get("entrypoint_rva"),"has_import_directory":pe.get("has_import_directory"),
            "module_id":"remoteserviceprobe","diagnostic_only":True,
            "capabilities":["passive outbound ClientServices::Send ring buffer","learn exact bank/mail/AH service handshake from live realm events","replay exact learned handshake without movement or position spoof","GUID/object-presence/distance correlation","UI_ERROR_MESSAGE and CHAT_MSG_SYSTEM correlation",".wow112_debug\\RemoteServiceProbe.log"],
            "safety":["diagnostic open/list handshake only","no item movement","no mail send","no auction bid/buy/cancel","no position spoof","no opcode guessing: replay exact packet learned from normal interaction"],
            "timings_ms":timing}
    if a.compile_only:
        module["process_total_ms"]=(time.perf_counter()-t0)*1000.0
        bm.write_text(json.dumps(module,indent=2)+"\n",encoding="utf-8")
        print(json.dumps(module,indent=2));return 0
    package=(ROOT/a.package).resolve();pm=(ROOT/a.package_metadata).resolve();sm=(ROOT/a.summary).resolve()
    meta=json.loads(pm.read_text(encoding="utf-8"));summary=json.loads(sm.read_text(encoding="utf-8"))
    if summary.get("result")!="PASS" or not summary.get("ready_for_test"): raise SystemExit("base candidate not ready")
    loader=repack(package,out)
    with zipfile.ZipFile(package) as z:
        names=z.namelist();actual=[x.strip() for x in z.read(DLL_LIST).decode("ascii").splitlines() if x.strip()]
    if actual!=loader or DLL_NAME not in names or DLL_NAME not in actual: raise SystemExit("RemoteServiceProbe manifest mismatch")
    if {x.lower() for x in names if x.lower().endswith(".dll")}!={x.lower() for x in actual}: raise SystemExit("dlls.txt differs from ZIP DLL set")
    psha=sha256_file(package);psz=package.stat().st_size
    for obj in (meta,summary):
        extras=[x for x in (obj.get("candidate_extra_dlls") or []) if x.get("name")!=DLL_NAME];extras.append(module)
        obj["candidate_extra_dlls"]=extras;obj["candidate_extra_dll_count"]=len(extras)
        obj["package_sha256"]=psha;obj["package_size"]=psz;obj["zip_root_entries"]=names
        obj["loader_manifest"]={"name":DLL_LIST,"generated_from_candidate_zip":True,"dll_count":len(actual),"dlls":actual,
                                "contains_remoteserviceprobe":True}
        obj["remoteserviceprobe_pilot"]={"module":DLL_NAME,"branch":"parallel","game_runtime_tested":False,
            "test":"World -> direct ClientServices::Disconnect -> AutoLoginBridge relogin -> slot 1/2 -> World",
            "purpose":"headless coordinator worker: exact-build world connection teardown enables same-process character recycle without a persistent in-game diagnostic panel"}
    summary["ready_for_test"]=bool(summary.get("ready_for_test") and DLL_NAME in actual)
    summary["result"]="PASS" if summary["ready_for_test"] else "FAIL"
    pm.write_text(json.dumps(meta,indent=2)+"\n",encoding="utf-8")
    sm.write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")
    module["candidate_package_sha256"]=psha;module["candidate_package_size"]=psz
    module["process_total_ms"]=(time.perf_counter()-t0)*1000.0
    bm.write_text(json.dumps(module,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(module,indent=2))
    if not summary["ready_for_test"]: raise SystemExit("RemoteServiceProbe candidate not ready")
    return 0
if __name__=="__main__": raise SystemExit(main())
