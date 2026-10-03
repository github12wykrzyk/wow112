#!/usr/bin/env python3
"""Build AH native throttle diagnostic and append it to the verified parallel candidate ZIP."""
import argparse, json, os, tempfile, time, zipfile
from pathlib import Path
from build_active_module import build_one, sha256_file

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"src/AHThrottleNative/WoWAHThrottleNative_5875_v8_FASTMARKET.c"
DLL_NAME="WoWAHThrottleNative_5875_v8_FASTMARKET.dll"
DLL_LIST_NAME="dlls.txt"
PROFILE="clangcl_i686_crtless"

def loader_manifest_bytes(names):
    dlls=[]; seen=set()
    for name in names:
        if "/" in name.rstrip("/") or not name.lower().endswith(".dll"): continue
        key=name.lower()
        if key in seen: continue
        seen.add(key); dlls.append(name)
    if DLL_NAME.lower() not in seen: dlls.append(DLL_NAME)
    return ("\r\n".join(dlls)+"\r\n").encode("ascii"),dlls

def deterministic_repack(package, extra_path):
    package=Path(package); extra_path=Path(extra_path)
    with zipfile.ZipFile(package,"r") as src:
        rows=[(i.filename,src.read(i.filename)) for i in src.infolist()
              if i.filename not in (DLL_NAME,DLL_LIST_NAME)]
    loader_data,loader_dlls=loader_manifest_bytes([n for n,_ in rows]+[DLL_NAME])
    rows.append((DLL_NAME,extra_path.read_bytes())); rows.append((DLL_LIST_NAME,loader_data))
    fd,tmp=tempfile.mkstemp(prefix="wow112-aht-native-",suffix=".zip",dir=str(package.parent));os.close(fd)
    temp=Path(tmp)
    try:
        with zipfile.ZipFile(temp,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9) as dst:
            for name,data in rows:
                info=zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
                dst.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
        os.replace(temp,package)
    finally:
        if temp.exists(): temp.unlink()
    return loader_dlls

def append_extra(rows,meta):
    out=[x for x in (rows or []) if x.get("name")!=DLL_NAME];out.append(meta);return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--package",default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata",default="dist/candidate_metadata.json")
    ap.add_argument("--summary",default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata",default="dist/ahthrottle_native_build.json")
    ap.add_argument("--output",default="build/"+DLL_NAME)
    args=ap.parse_args()
    t0=time.perf_counter(); package=(ROOT/args.package).resolve()
    pm=(ROOT/args.package_metadata).resolve(); sp=(ROOT/args.summary).resolve()
    bm=(ROOT/args.build_metadata).resolve(); output=(ROOT/args.output).resolve()
    output.parent.mkdir(parents=True,exist_ok=True);bm.parent.mkdir(parents=True,exist_ok=True)
    summary=json.loads(sp.read_text(encoding="utf-8"));meta=json.loads(pm.read_text(encoding="utf-8"))
    if summary.get("result")!="PASS" or not summary.get("ready_for_test"): raise SystemExit("base candidate not READY_FOR_TEST")
    timing,pe=build_one(PROFILE,SOURCE,output.with_suffix(".obj"),output)
    if pe.get("machine_hex")!="0x014C" or pe.get("entrypoint_rva")==0 or pe.get("has_import_directory"):
        raise SystemExit("AH native diagnostic PE32/x86/crtless verification failed")
    module={
      "name":DLL_NAME,"source_path":str(SOURCE.relative_to(ROOT)).replace("\\","/"),
      "source_sha256":sha256_file(SOURCE),"build_profile":PROFILE,"toolchain_mode":timing.get("mode"),
      "sha256":sha256_file(output),"size":output.stat().st_size,"pe_machine":pe.get("machine_hex"),
      "entrypoint_rva":pe.get("entrypoint_rva"),"has_import_directory":pe.get("has_import_directory"),
      "module_id":"ahthrottle_native","settings":["diagnostic-only","F5 trigger","10 alternating stages x500","75ms vs 125ms repeatability","native SMSG 0x025C receive probe","AUX native response correlation callback","AUX real outbound CMSG counter","stock QueryAuctionItems cooldown 5000ms preserved; no runtime cooldown patch","F2 disabled; F5 benchmark remains manual-only","one in-flight query","no bid/buy"]
    }
    expected=deterministic_repack(package,output)
    with zipfile.ZipFile(package) as z:
        names=z.namelist(); loader=[x.strip() for x in z.read(DLL_LIST_NAME).decode("ascii").splitlines() if x.strip()]
    if DLL_NAME not in names or DLL_NAME not in loader or loader!=expected: raise SystemExit("AH native diagnostic packaging mismatch")
    if {x.lower() for x in names if x.lower().endswith(".dll")}!={x.lower() for x in loader}: raise SystemExit("dlls.txt mismatch")
    psha=sha256_file(package);psz=package.stat().st_size
    extras=append_extra(meta.get("candidate_extra_dlls"),module)
    pilot={"module":DLL_NAME,"branch":"parallel","trigger":"F5 while AH open and CanSendAuctionQuery=true",
           "capture":"exact outbound opcode 0x258 at ClientServices::Send","receive_probe":"NetClient handler table opcode 0x25C -> verified 0x004CC7F0, passive wrapper counts calls and sanity-checks auction count","fast_market":"F2 disabled; F5 benchmark remains manual-only; normal AUX uses stock QueryAuctionItems pacing","aux_query_cooldown":"exact WoW 5875 QueryAuctionItems add eax,0x1388 at 0x004CEC47; immediate at 0x004CEC48 signature-validated at 5000ms and left unchanged","intervals_ms":[75,125,75,125,75,125,75,125,75,125],"stage_sends":500,
           "chain":"replay through pre-existing send hook target","safety":"only captured CMSG_AUCTION_LIST_ITEMS is replayed; listfrom is the only mutated payload field; no auction bid/buy opcode",
           "game_runtime_tested":False}
    meta.update({"zip_root_entries":names,"package_sha256":psha,"package_size":psz,
                 "candidate_extra_dll_count":len(extras),"candidate_extra_dlls":extras,
                 "loader_manifest":{"name":DLL_LIST_NAME,"generated_from_candidate_zip":True,"dll_count":len(loader),"dlls":loader,"contains_ahthrottle_native":True},
                 "ahthrottle_native_pilot":pilot})
    pm.write_text(json.dumps(meta,indent=2)+"\n",encoding="utf-8")
    sextras=append_extra(summary.get("candidate_extra_dlls"),module)
    summary.update({"package_sha256":psha,"package_size":psz,"zip_root_entries":names,
                    "candidate_extra_dll_count":len(sextras),"candidate_extra_dlls":sextras,
                    "loader_manifest":meta["loader_manifest"],"ahthrottle_native_pilot":pilot})
    summary["ready_for_test"]=bool(summary.get("ready_for_test") and DLL_NAME in names and DLL_NAME in loader)
    summary["result"]="PASS" if summary["ready_for_test"] else "FAIL"
    sp.write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")
    module.update({"candidate_package_sha256":psha,"candidate_package_size":psz,
                   "loader_manifest":meta["loader_manifest"],"process_total_ms":(time.perf_counter()-t0)*1000.0})
    bm.write_text(json.dumps(module,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(module,indent=2))
    if not summary["ready_for_test"]: raise SystemExit("AH native candidate not READY_FOR_TEST")
    return 0
if __name__=="__main__": raise SystemExit(main())
