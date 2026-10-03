#!/usr/bin/env python3
"""Build AutoLoginBridge 5875 and optionally append it to a candidate ZIP."""
import argparse, json, os, tempfile, time, zipfile
from pathlib import Path
from build_active_module import build_one, sha256_file

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"src/AutoLoginBridge/WoWAutoLoginBridge_5875_v1_HOTPROBE.c"
DLL_NAME="WoWAutoLoginBridge_5875_v1.dll"
DLL_LIST="dlls.txt"
PROFILE="clangcl_i686_win32imports"
HOT_PAYLOADS=(
    "Interface/AddOns/SummonScout/SummonScout_PostPaymentOfferHot.lua",
    "Interface/AddOns/SummonScout/SummonScout_WhisperConfirmSpam.lua",
    "Interface/AddOns/SummonScout/SummonScout.lua",
)
HOT_PAYLOAD=HOT_PAYLOADS[0]

def repack(package,dll):
    with zipfile.ZipFile(package,"r") as src:
        rows=[(i.filename,src.read(i.filename)) for i in src.infolist()
              if i.filename not in (DLL_NAME,DLL_LIST)]
    loader=[]; seen=set()
    for name,_ in rows:
        if "/" in name.rstrip("/") or not name.lower().endswith(".dll"): continue
        k=name.lower()
        if k not in seen: seen.add(k); loader.append(name)
    if DLL_NAME.lower() not in seen: loader.append(DLL_NAME)
    rows.append((DLL_NAME,Path(dll).read_bytes()))
    rows.append((DLL_LIST,("\r\n".join(loader)+"\r\n").encode("ascii")))
    fd,tmp=tempfile.mkstemp(prefix="wow112-autologin-",suffix=".zip",dir=str(Path(package).parent)); os.close(fd)
    temp=Path(tmp)
    try:
        with zipfile.ZipFile(temp,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9) as dst:
            for name,data in rows:
                info=zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0))
                info.compress_type=zipfile.ZIP_DEFLATED; info.external_attr=0o100644<<16
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
    ap.add_argument("--build-metadata",default="dist/autologinbridge_build.json")
    ap.add_argument("--output",default="build/WoWAutoLoginBridge_5875_v1.dll")
    a=ap.parse_args()
    t0=time.perf_counter(); out=(ROOT/a.output).resolve(); out.parent.mkdir(parents=True,exist_ok=True)
    meta_path=(ROOT/a.build_metadata).resolve(); meta_path.parent.mkdir(parents=True,exist_ok=True)
    timing,pe=build_one(PROFILE,SOURCE,out.with_suffix(".obj"),out)
    if pe.get("machine_hex")!="0x014C" or not pe.get("entrypoint_rva") or not pe.get("has_import_directory"):
        raise SystemExit("AutoLoginBridge PE32/x86/import gate failed")
    module={
      "name":DLL_NAME,"source_path":str(SOURCE.relative_to(ROOT)).replace("\\","/"),
      "source_sha256":sha256_file(SOURCE),"build_profile":PROFILE,"toolchain_mode":timing.get("mode"),
      "sha256":sha256_file(out),"size":out.stat().st_size,"pe_machine":pe.get("machine_hex"),
      "entrypoint_rva":pe.get("entrypoint_rva"),"has_import_directory":pe.get("has_import_directory"),
      "module_id":"autologinbridge","keyboard_input":False,"foreground_dependency":False,
      "native_login":"0x0046AFB0","credential_transport":"child environment; password remains DPAPI-protected",
      "hot_lua_probe":True,
      "hot_lua_execute":"0x00704CD0",
      "hot_lua_payload":HOT_PAYLOAD,
      "hot_lua_payloads":list(HOT_PAYLOADS),
      "hot_lua_scope":"SummonScout hot modules: post-payment + whisper-confirm + core",
      "hot_lua_poll_ms":250,
      "timings_ms":timing
    }
    if a.compile_only:
        module["process_total_ms"]=(time.perf_counter()-t0)*1000.0
        meta_path.write_text(json.dumps(module,indent=2)+"\n",encoding="utf-8")
        print(json.dumps(module,indent=2)); return 0
    package=(ROOT/a.package).resolve(); pm=(ROOT/a.package_metadata).resolve(); sm=(ROOT/a.summary).resolve()
    if not package.is_file() or not pm.is_file() or not sm.is_file(): raise SystemExit("candidate package state missing")
    package_meta=json.loads(pm.read_text(encoding="utf-8")); summary=json.loads(sm.read_text(encoding="utf-8"))
    if summary.get("result")!="PASS" or not summary.get("ready_for_test"): raise SystemExit("base candidate not ready")
    loader=repack(package,out)
    with zipfile.ZipFile(package) as z:
        names=z.namelist(); actual=[x.strip() for x in z.read(DLL_LIST).decode("ascii").splitlines() if x.strip()]
    if actual!=loader or DLL_NAME not in names or DLL_NAME not in actual: raise SystemExit("AutoLoginBridge package manifest mismatch")
    dlls=[n for n in names if n.lower().endswith(".dll")]
    if {x.lower() for x in dlls}!={x.lower() for x in actual}: raise SystemExit("dlls.txt differs from ZIP DLL set")
    module["candidate_package_sha256"]=sha256_file(package); module["candidate_package_size"]=package.stat().st_size
    for obj in (package_meta,summary):
        extras=[x for x in (obj.get("candidate_extra_dlls") or []) if x.get("name")!=DLL_NAME]; extras.append(module)
        obj["candidate_extra_dlls"]=extras; obj["candidate_extra_dll_count"]=len(extras)
        obj["package_sha256"]=module["candidate_package_sha256"]; obj["package_size"]=module["candidate_package_size"]
        obj["zip_root_entries"]=names
        obj["loader_manifest"]={"name":DLL_LIST,"generated_from_candidate_zip":True,"dll_count":len(actual),"dlls":actual,"contains_autologinbridge":True}
        obj["autologinbridge_pilot"]={
            "module":DLL_NAME,
            "keyboard_input":False,
            "foreground_dependency":False,
            "native_login":"0x0046AFB0",
            "credential_storage":"DPAPI vault; encrypted child environment",
            "hot_lua_probe":True,
            "hot_lua_execute":"0x00704CD0",
            "hot_lua_payload":HOT_PAYLOAD,
            "hot_lua_payloads":list(HOT_PAYLOADS),
            "hot_lua_scope":"SummonScout hot modules: post-payment + whisper-confirm + core",
            "hot_lua_poll_ms":250
        }
    summary["ready_for_test"]=bool(summary.get("ready_for_test") and DLL_NAME in actual)
    summary["result"]="PASS" if summary["ready_for_test"] else "FAIL"
    pm.write_text(json.dumps(package_meta,indent=2)+"\n",encoding="utf-8")
    sm.write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")
    module["process_total_ms"]=(time.perf_counter()-t0)*1000.0
    meta_path.write_text(json.dumps(module,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(module,indent=2))
    if not summary["ready_for_test"]: raise SystemExit("AutoLoginBridge candidate not ready")
    return 0
if __name__=="__main__": raise SystemExit(main())
