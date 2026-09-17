#!/usr/bin/env python3
"""Build the active WoWControlHub source and append it to a verified work candidate ZIP."""

import argparse
import json
import os
import tempfile
import time
import zipfile
from pathlib import Path

from build_active_module import build_one, sha256_file

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
HUB_NAME = "WoWControlHub.dll"
DLL_LIST_NAME = "dlls.txt"


def active_hub():
    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    rows = [x for x in runtime.get("active_dlls", []) if x.get("name") == HUB_NAME]
    if len(rows) != 1:
        raise SystemExit(f"expected exactly one active {HUB_NAME}, found {len(rows)}")
    row = rows[0]
    source = ROOT / str(row.get("source_path") or "")
    recipe = row.get("build_recipe") or {}
    profile = recipe.get("profile")
    if not source.is_file():
        raise SystemExit(f"ControlHub active source missing: {source}")
    if not profile:
        raise SystemExit("ControlHub active build recipe/profile missing")
    return row, source, profile


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
    if HUB_NAME.lower() not in seen:
        dlls.append(HUB_NAME)
    return ("\r\n".join(dlls) + "\r\n").encode("ascii"), dlls


def deterministic_repack(package, hub_path):
    package = Path(package)
    hub_path = Path(hub_path)
    if not package.is_file():
        raise SystemExit(f"base candidate ZIP missing: {package}")

    with zipfile.ZipFile(package, "r") as src:
        original_names = src.namelist()
        rows = [
            (info.filename, src.read(info.filename))
            for info in src.infolist()
            if info.filename not in (HUB_NAME, DLL_LIST_NAME)
        ]

    loader_data, loader_dlls = loader_manifest_bytes(original_names + [HUB_NAME])
    rows.append((HUB_NAME, hub_path.read_bytes()))
    rows.append((DLL_LIST_NAME, loader_data))

    fd, temp_name = tempfile.mkstemp(prefix="wow112-hub-", suffix=".zip", dir=str(package.parent))
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


def read_loader_manifest(package):
    with zipfile.ZipFile(package, "r") as zf:
        text = zf.read(DLL_LIST_NAME).decode("ascii", errors="strict")
    return [line.strip() for line in text.splitlines() if line.strip()]


def replace_named(rows, name, value):
    out = []
    replaced = False
    for row in rows or []:
        if isinstance(row, dict) and row.get("name") == name:
            if not replaced:
                out.append(value)
                replaced = True
        else:
            out.append(row)
    if not replaced:
        out.append(value)
    return out


def main():
    ap = argparse.ArgumentParser(description="Build active WoWControlHub and append it to a verified candidate package.")
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata", default="dist/controlhub_build.json")
    ap.add_argument("--output", default="build/WoWControlHub.dll")
    args = ap.parse_args()

    t0 = time.perf_counter()
    package = (ROOT / args.package).resolve()
    package_meta_path = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve()
    build_meta_path = (ROOT / args.build_metadata).resolve()
    output = (ROOT / args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    build_meta_path.parent.mkdir(parents=True, exist_ok=True)

    runtime_row, source, profile = active_hub()

    if not package_meta_path.is_file() or not summary_path.is_file():
        raise SystemExit("candidate metadata/summary missing; generic verified candidate must be built first")

    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    package_meta = json.loads(package_meta_path.read_text(encoding="utf-8"))
    if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
        raise SystemExit("base candidate is not READY_FOR_TEST")

    obj = output.with_suffix(".obj")
    timing, pe = build_one(profile, source, obj, output)
    if pe.get("machine_hex") != "0x014C" or pe.get("entrypoint_rva") == 0:
        raise SystemExit("ControlHub PE32/x86/entrypoint verification failed")
    if profile == "clangcl_i686_win32imports" and not pe.get("has_import_directory"):
        raise SystemExit("ControlHub Win32-import profile unexpectedly produced no import directory")

    digest = sha256_file(output)
    hub_meta = {
        "name": HUB_NAME,
        "source_path": str(source.relative_to(ROOT)).replace("\\", "/"),
        "source_sha256": sha256_file(source),
        "build_profile": profile,
        "toolchain_mode": timing.get("mode"),
        "sha256": digest,
        "size": output.stat().st_size,
        "pe_machine": pe.get("machine_hex"),
        "entrypoint_rva": pe.get("entrypoint_rva"),
        "has_import_directory": pe.get("has_import_directory"),
        "gui_toggle": runtime_row.get("gui_toggle", "Insert"),
        "timings_ms": timing,
    }

    loader_dlls = deterministic_repack(package, output)
    with zipfile.ZipFile(package, "r") as zf:
        names = zf.namelist()
    actual_loader_dlls = read_loader_manifest(package)

    if HUB_NAME not in names or DLL_LIST_NAME not in names:
        raise SystemExit("ControlHub/dlls.txt missing from candidate ZIP after repack")
    if any("/" in name.rstrip("/") for name in names):
        raise SystemExit("candidate ZIP unexpectedly contains nested paths")
    package_dlls = [name for name in names if name.lower().endswith(".dll")]
    if {x.lower() for x in actual_loader_dlls} != {x.lower() for x in package_dlls}:
        raise SystemExit("dlls.txt does not exactly match candidate ZIP DLL set")
    if actual_loader_dlls != loader_dlls:
        raise SystemExit("dlls.txt round-trip mismatch")

    package_sha = sha256_file(package)
    package_size = package.stat().st_size
    loader_meta = {
        "name": DLL_LIST_NAME,
        "generated_from_candidate_zip": True,
        "dll_count": len(actual_loader_dlls),
        "dlls": actual_loader_dlls,
        "contains_controlhub": HUB_NAME in actual_loader_dlls,
    }

    entries = [x for x in (package_meta.get("zip_root_entries") or []) if x not in (HUB_NAME, DLL_LIST_NAME)]
    entries += [HUB_NAME, DLL_LIST_NAME]
    package_meta["zip_root_entries"] = entries
    package_meta["package_sha256"] = package_sha
    package_meta["package_size"] = package_size
    package_meta["candidate_extra_dlls"] = replace_named(package_meta.get("candidate_extra_dlls"), HUB_NAME, hub_meta)
    package_meta["candidate_extra_dll_count"] = len(package_meta["candidate_extra_dlls"])
    package_meta["loader_manifest"] = loader_meta
    package_meta["controlhub"] = {
        "abi": "W112_CONTROL_API_V1",
        "source_path": hub_meta["source_path"],
        "gui_toggle": hub_meta["gui_toggle"],
        "features": ["module_paging", "setting_paging", "runtime_health"],
        "render_input": "Win32 layered overlay + game WndProc subclass",
        "loader_manifest": DLL_LIST_NAME,
    }
    package_meta_path.write_text(json.dumps(package_meta, indent=2) + "\n", encoding="utf-8")

    summary["package_sha256"] = package_sha
    summary["package_size"] = package_size
    summary["zip_root_entries"] = entries
    summary["candidate_extra_dlls"] = replace_named(summary.get("candidate_extra_dlls"), HUB_NAME, hub_meta)
    summary["candidate_extra_dll_count"] = len(summary["candidate_extra_dlls"])
    summary["loader_manifest"] = loader_meta
    summary["controlhub"] = package_meta["controlhub"]
    summary["ready_for_test"] = bool(
        summary.get("ready_for_test")
        and HUB_NAME in names
        and HUB_NAME in actual_loader_dlls
        and pe.get("machine_hex") == "0x014C"
        and pe.get("entrypoint_rva") != 0
    )
    summary["result"] = "PASS" if summary["ready_for_test"] else "FAIL"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    hub_meta["candidate_package"] = str(package.relative_to(ROOT)).replace("\\", "/")
    hub_meta["candidate_package_sha256"] = package_sha
    hub_meta["candidate_package_size"] = package_size
    hub_meta["loader_manifest"] = loader_meta
    hub_meta["process_total_ms"] = (time.perf_counter() - t0) * 1000.0
    build_meta_path.write_text(json.dumps(hub_meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(hub_meta, indent=2))

    if not summary["ready_for_test"]:
        raise SystemExit("ControlHub candidate verdict is not READY_FOR_TEST")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
