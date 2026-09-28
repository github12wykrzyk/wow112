#!/usr/bin/env python3
"""Build AutoSummon Assist V1 and append it to the verified work candidate ZIP."""

import argparse
import json
import os
import tempfile
import time
import zipfile
from pathlib import Path

from build_active_module import build_one, sha256_file

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/AutoSummonAssist/WoWAutoSummonAssist_5875_v1.c"
DLL_NAME = "WoWAutoSummonAssist_5875_v1.dll"
DLL_LIST_NAME = "dlls.txt"
PROFILE = "clangcl_i686_crtless"


def loader_manifest_bytes(names):
    dlls = []
    seen = set()
    for name in names:
        if "/" in name.rstrip("/") or not name.lower().endswith(".dll"):
            continue
        key = name.lower()
        if key in seen:
            continue
        seen.add(key)
        dlls.append(name)
    if DLL_NAME.lower() not in seen:
        dlls.append(DLL_NAME)
    return ("\r\n".join(dlls) + "\r\n").encode("ascii"), dlls


def deterministic_repack(package, extra_path):
    package = Path(package)
    extra_path = Path(extra_path)
    if not package.is_file():
        raise SystemExit(f"base candidate ZIP missing: {package}")

    with zipfile.ZipFile(package, "r") as src:
        rows = [
            (info.filename, src.read(info.filename))
            for info in src.infolist()
            if info.filename not in (DLL_NAME, DLL_LIST_NAME)
        ]

    loader_data, loader_dlls = loader_manifest_bytes([name for name, _ in rows] + [DLL_NAME])
    rows.append((DLL_NAME, extra_path.read_bytes()))
    rows.append((DLL_LIST_NAME, loader_data))

    fd, temp_name = tempfile.mkstemp(prefix="wow112-autosummon-", suffix=".zip", dir=str(package.parent))
    os.close(fd)
    temp = Path(temp_name)
    try:
        with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
            for name, data in rows:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                dst.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(temp, package)
    finally:
        if temp.exists():
            temp.unlink()
    return loader_dlls


def append_extra(rows, meta):
    out = [x for x in (rows or []) if x.get("name") != DLL_NAME]
    out.append(meta)
    return out


def main():
    ap = argparse.ArgumentParser(description="Build AutoSummon Assist and append it to a verified candidate package.")
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata", default="dist/autosummonassist_build.json")
    ap.add_argument("--output", default="build/WoWAutoSummonAssist_5875_v1.dll")
    args = ap.parse_args()

    t0 = time.perf_counter()
    package = (ROOT / args.package).resolve()
    package_meta_path = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve()
    build_meta_path = (ROOT / args.build_metadata).resolve()
    output = (ROOT / args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    build_meta_path.parent.mkdir(parents=True, exist_ok=True)

    if not SOURCE.is_file():
        raise SystemExit(f"AutoSummon Assist source missing: {SOURCE.relative_to(ROOT)}")
    if not package_meta_path.is_file() or not summary_path.is_file():
        raise SystemExit("candidate metadata/summary missing; base candidate must be built first")

    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    package_meta = json.loads(package_meta_path.read_text(encoding="utf-8"))
    if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
        raise SystemExit("base candidate is not READY_FOR_TEST")

    obj = output.with_suffix(".obj")
    timing, pe = build_one(PROFILE, SOURCE, obj, output)
    if pe.get("machine_hex") != "0x014C" or pe.get("entrypoint_rva") == 0:
        raise SystemExit("AutoSummon Assist PE32/x86/entrypoint verification failed")
    if pe.get("has_import_directory"):
        raise SystemExit("AutoSummon Assist unexpectedly has PE imports; crtless provider contract violated")

    module_meta = {
        "name": DLL_NAME,
        "source_path": str(SOURCE.relative_to(ROOT)).replace("\\", "/"),
        "source_sha256": sha256_file(SOURCE),
        "build_profile": PROFILE,
        "toolchain_mode": timing.get("mode"),
        "sha256": sha256_file(output),
        "size": output.stat().st_size,
        "pe_machine": pe.get("machine_hex"),
        "entrypoint_rva": pe.get("entrypoint_rva"),
        "has_import_directory": pe.get("has_import_directory"),
        "control_api": "W112_CONTROL_API_V1",
        "module_id": "autosummonassist",
        "settings": ["Enabled", "Eligible (read-only)", "Portal in range (read-only)", "Click attempts"],
        "timings_ms": timing,
    }

    expected_loader = deterministic_repack(package, output)
    with zipfile.ZipFile(package, "r") as zf:
        names = zf.namelist()
        loader = [line.strip() for line in zf.read(DLL_LIST_NAME).decode("ascii").splitlines() if line.strip()]

    if any("/" in name.rstrip("/") for name in names):
        raise SystemExit("candidate ZIP unexpectedly contains nested paths")
    if DLL_NAME not in names or DLL_NAME not in loader:
        raise SystemExit("AutoSummon Assist is missing from candidate ZIP/dlls.txt")
    package_dlls = [name for name in names if name.lower().endswith(".dll")]
    if {x.lower() for x in package_dlls} != {x.lower() for x in loader}:
        raise SystemExit("dlls.txt does not exactly match final candidate ZIP DLL set")
    if loader != expected_loader:
        raise SystemExit("AutoSummon Assist loader manifest round-trip mismatch")

    package_sha = sha256_file(package)
    package_size = package.stat().st_size
    extras = append_extra(package_meta.get("candidate_extra_dlls"), module_meta)
    package_meta["zip_root_entries"] = names
    package_meta["package_sha256"] = package_sha
    package_meta["package_size"] = package_size
    package_meta["candidate_extra_dll_count"] = len(extras)
    package_meta["candidate_extra_dlls"] = extras
    package_meta["loader_manifest"] = {
        "name": DLL_LIST_NAME,
        "generated_from_candidate_zip": True,
        "dll_count": len(loader),
        "dlls": loader,
        "contains_autosummonassist": True,
    }
    package_meta["autosummonassist_pilot"] = {
        "module": DLL_NAME,
        "module_id": "autosummonassist",
        "abi": "W112_CONTROL_API_V1",
        "default_enabled": True,
        "scope": "Vanilla Ritual of Summoning portal GameObject entry 36727 only",
        "eligibility": "alive + party/raid + out of combat + no active cast/channel",
        "interaction": "native 5875 0x005F8660 GameObject right-click on UI thread",
        "range_yd": 4.75,
        "portal_radius_reference_yd": 5.0,
        "retry_policy": "one click per observed portal GUID",
        "position_spoof": False,
        "timer_period_ms": 25,
        "world_reacquire_ms": 500,
    }
    hub = package_meta.get("controlhub_pilot")
    if isinstance(hub, dict):
        providers = list(hub.get("providers") or [])
        if DLL_NAME not in providers:
            providers.append(DLL_NAME)
        hub["providers"] = providers
    package_meta_path.write_text(json.dumps(package_meta, indent=2) + "\n", encoding="utf-8")

    summary_extras = append_extra(summary.get("candidate_extra_dlls"), module_meta)
    summary["package_sha256"] = package_sha
    summary["package_size"] = package_size
    summary["zip_root_entries"] = names
    summary["candidate_extra_dll_count"] = len(summary_extras)
    summary["candidate_extra_dlls"] = summary_extras
    summary["loader_manifest"] = package_meta["loader_manifest"]
    summary["autosummonassist_pilot"] = package_meta["autosummonassist_pilot"]
    if isinstance(summary.get("controlhub_pilot"), dict):
        providers = list(summary["controlhub_pilot"].get("providers") or [])
        if DLL_NAME not in providers:
            providers.append(DLL_NAME)
        summary["controlhub_pilot"]["providers"] = providers

    summary["ready_for_test"] = bool(
        summary.get("ready_for_test")
        and DLL_NAME in names
        and DLL_NAME in loader
        and pe.get("machine_hex") == "0x014C"
        and pe.get("entrypoint_rva") != 0
        and not pe.get("has_import_directory")
    )
    summary["result"] = "PASS" if summary["ready_for_test"] else "FAIL"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    module_meta["candidate_package_sha256"] = package_sha
    module_meta["candidate_package_size"] = package_size
    module_meta["loader_manifest"] = package_meta["loader_manifest"]
    module_meta["process_total_ms"] = (time.perf_counter() - t0) * 1000.0
    build_meta_path.write_text(json.dumps(module_meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(module_meta, indent=2))

    if not summary["ready_for_test"]:
        raise SystemExit("AutoSummon Assist candidate verdict is not READY_FOR_TEST")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
