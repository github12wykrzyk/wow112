#!/usr/bin/env python3
"""Build Opener UI Recovery V1 and append it to the work candidate ZIP."""
import argparse,json,os,tempfile,time,zipfile
from pathlib import Path
from build_active_module import build_one,sha256_file
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"src/OpenerUIRecovery/WoWOpenerUIRecovery_5875_v1.c"
DLL_NAME="WoWOpenerUIRecovery_5875_v1.dll"
DLL_LIST_NAME="dlls.txt"
PROFILE="clangcl_i686_crtless"

def repack(package,extra):
    package=Path(package); extra=Path(extra)
    with zipfile.ZipFile(package,"r") as src:
        rows=[(i.filename,src.read(i.filename)) for i in src.infolist() if i.filename not in (DLL_NAME,DLL_LIST_NAME)]
    dlls=[]; seen=set()
    for name,_ in rows:
        if "/" in name.rstrip("/") or not name.lower().endswith(".dll"): continue
        if name.lower() in seen: continue
        seen.add(name.lower()); dlls.append(name)
    if DLL_NAME.lower() not in seen: dlls.append(DLL_NAME)
    rows.append((DLL_NAME,extra.read_bytes()))
    rows.append((DLL_LIST_NAME,("\r\n".join(dlls)+"\r\n").encode("ascii")))
    fd,tmpname=tempfile.mkstemp(prefix="wow112-openerui-",suffix=".zip",dir=str(package.parent));os.close(fd);tmp=Path(tmpname)
    try:
        with zipfile.ZipFile(tmp,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9) as dst:
            for name,data in rows:
                info=zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
                dst.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
        os.replace(tmp,package)
    finally:
        if tmp.exists(): tmp.unlink()
    return dlls

def append_extra(rows,meta):
    out=[x for x in (rows or []) if x.get("name")!=DLL_NAME];out.append(meta);return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--package",default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata",default="dist/candidate_metadata.json")
    ap.add_argument("--summary",default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata",default="dist/openeruirecovery_build.json")
    ap.add_argument("--output",default="build/WoWOpenerUIRecovery_5875_v1.dll")
    a=ap.parse_args();t0=time.perf_counter()
    package=(ROOT/a.package).resolve();pm=(ROOT/a.package_metadata).resolve();sp=(ROOT/a.summary).resolve();bm=(ROOT/a.build_metadata).resolve();out=(ROOT/a.output).resolve()
    out.parent.mkdir(parents=True,exist_ok=True);bm.parent.mkdir(parents=True,exist_ok=True)
    if not SOURCE.is_file(): raise SystemExit("Opener UI Recovery source missing")
    summary=json.loads(sp.read_text(encoding="utf-8"));meta=json.loads(pm.read_text(encoding="utf-8"))
    if summary.get("result")!="PASS" or not summary.get("ready_for_test"): raise SystemExit("base candidate is not READY_FOR_TEST")
    timing,pe=build_one(PROFILE,SOURCE,out.with_suffix(".obj"),out)
    if pe.get("machine_hex")!="0x014C" or pe.get("entrypoint_rva")==0 or pe.get("has_import_directory"): raise SystemExit("Opener UI Recovery PE gate failed")
    mm={"name":DLL_NAME,"source_path":str(SOURCE.relative_to(ROOT)).replace("\\","/"),"source_sha256":sha256_file(SOURCE),"build_profile":PROFILE,"toolchain_mode":timing.get("mode"),"sha256":sha256_file(out),"size":out.stat().st_size,"pe_machine":pe.get("machine_hex"),"entrypoint_rva":pe.get("entrypoint_rva"),"has_import_directory":False,"control_api":"W112_CONTROL_API_V1","module_id":"opener_ui_recovery","settings":["Clear stuck opener","Auto clear","Auto grace (ms)","UI clears","Active-cast skips","Last opener spell ID"],"timings_ms":timing}
    expected=repack(package,out)
    with zipfile.ZipFile(package,"r") as z:
        names=z.namelist();loader=[x.strip() for x in z.read(DLL_LIST_NAME).decode("ascii").splitlines() if x.strip()]
    if DLL_NAME not in names or DLL_NAME not in loader or loader!=expected: raise SystemExit("Opener UI Recovery ZIP/loader gate failed")
    package_dlls=[n for n in names if n.lower().endswith(".dll")]
    if {x.lower() for x in package_dlls}!={x.lower() for x in loader}: raise SystemExit("dlls.txt mismatch")
    psha=sha256_file(package);psz=package.stat().st_size
    extras=append_extra(meta.get("candidate_extra_dlls"),mm)
    meta["zip_root_entries"]=names;meta["package_sha256"]=psha;meta["package_size"]=psz;meta["candidate_extra_dll_count"]=len(extras);meta["candidate_extra_dlls"]=extras
    meta["loader_manifest"]={"name":DLL_LIST_NAME,"generated_from_candidate_zip":True,"dll_count":len(loader),"dlls":loader,"contains_opener_ui_recovery":True}
    meta["opener_ui_recovery_pilot"]={"module":DLL_NAME,"module_id":"opener_ui_recovery","abi":"W112_CONTROL_API_V1","default_auto_clear":True,"default_grace_ms":250,"scope":"client UI action GUID recovery only; no packets/range/facing/movement/GCD/timing changes","manual_clear":"explicit action may dispatch native opener SpellStopCasting while active; skips unrelated active spell","auto_clear":"ON for Parallel test; requires Backstab/Ambush evidence + unchanged orphaned action/targeting state + fully idle pending/casting/handle/queued pipeline + 250 ms grace; never auto-cancels active cast"}
    if isinstance(meta.get("controlhub_pilot"),dict):
        p=list(meta["controlhub_pilot"].get("providers") or [])
        if DLL_NAME not in p:p.append(DLL_NAME)
        meta["controlhub_pilot"]["providers"]=p
    pm.write_text(json.dumps(meta,indent=2)+"\n",encoding="utf-8")
    sextras=append_extra(summary.get("candidate_extra_dlls"),mm)
    summary["package_sha256"]=psha;summary["package_size"]=psz;summary["zip_root_entries"]=names;summary["candidate_extra_dll_count"]=len(sextras);summary["candidate_extra_dlls"]=sextras;summary["loader_manifest"]=meta["loader_manifest"];summary["opener_ui_recovery_pilot"]=meta["opener_ui_recovery_pilot"]
    if isinstance(summary.get("controlhub_pilot"),dict):
        p=list(summary["controlhub_pilot"].get("providers") or [])
        if DLL_NAME not in p:p.append(DLL_NAME)
        summary["controlhub_pilot"]["providers"]=p
    summary["ready_for_test"]=bool(summary.get("ready_for_test") and DLL_NAME in names and DLL_NAME in loader);summary["result"]="PASS" if summary["ready_for_test"] else "FAIL"
    sp.write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")
    mm["candidate_package_sha256"]=psha;mm["candidate_package_size"]=psz;mm["process_total_ms"]=(time.perf_counter()-t0)*1000.0
    bm.write_text(json.dumps(mm,indent=2)+"\n",encoding="utf-8");print(json.dumps(mm,indent=2))
    if not summary["ready_for_test"]: raise SystemExit("Opener UI Recovery candidate not ready")
if __name__=="__main__": raise SystemExit(main())
