#!/usr/bin/env python3
"""Build the optional WoWControlHub V1 pilot and append it to a verified work candidate ZIP."""

import argparse
import hashlib
import json
import os
import tempfile
import time
import zipfile
from pathlib import Path

from build_active_module import build_one, sha256_file

ROOT = Path(__file__).resolve().parents[1]
HUB_SOURCE = ROOT / "src/WoWControlHub/WoWControlHub_v1.c"
HUB_NAME = "WoWControlHub.dll"
DLL_LIST_NAME = "dlls.txt"
HUB_PROFILE = "clangcl_i686_win32imports"
SPEED_NAME = "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll"
HOTKEY_NAME = "Insert"
# Candidate-only deterministic binary patch. Canonical source still documents the
# original F10 pilot until the in-game path is accepted and promoted cleanly.
HOTKEY_CODE_FROM = b"\x83\xf1\x79\x09\xc1"  # xor ecx,0x79 ; or ecx,eax
HOTKEY_CODE_TO = b"\x83\xf1\x2d\x09\xc1"    # xor ecx,0x2d ; or ecx,eax
HOTKEY_LABEL_FROM = b"WoWControlHub V1   [F10]"
HOTKEY_LABEL_TO = b"WoWControlHub V1   [INS]"


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


def patch_controlhub_hotkey(path):
    path = Path(path)
    data = bytearray(path.read_bytes())
    patches = []
    for label, before, after in (
        ("wndproc_virtual_key", HOTKEY_CODE_FROM, HOTKEY_CODE_TO),
        ("panel_hotkey_label", HOTKEY_LABEL_FROM, HOTKEY_LABEL_TO),
    ):
        if len(before) != len(after):
            raise SystemExit(f"ControlHub hotkey patch length mismatch: {label}")
        count = data.count(before)
        if count != 1:
            raise SystemExit(f"ControlHub hotkey patch expected one {label} site, found {count}")
        offset = data.find(before)
        data[offset:offset + len(before)] = after
        patches.append({
            "label": label,
            "file_offset": offset,
            "before_hex": before.hex(),
            "after_hex": after.hex(),
        })
    path.write_bytes(data)
    if data.count(HOTKEY_CODE_FROM) or data.count(HOTKEY_LABEL_FROM):
        raise SystemExit("ControlHub F10 bytes remain after candidate hotkey patch")
    if data.count(HOTKEY_CODE_TO) != 1 or data.count(HOTKEY_LABEL_TO) != 1:
        raise SystemExit("ControlHub Insert hotkey patch verification failed")
    return patches


def deterministic_repack(package, extra_path):
    package = Path(package)
    extra_path = Path(extra_path)
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
    rows.append((HUB_NAME, extra_path.read_bytes()))
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


def require_speedfloor_candidate(summary):
    names = set(summary.get("candidate_override_names") or [])
    if SPEED_NAME not in names:
        raise SystemExit("SpeedFloor candidate override is missing; refusing to pair ControlHub with the stable non-ABI DLL")
    rows = summary.get("audit_builds") or []
    row = next((x for x in rows if x.get("runtime_name") == SPEED_NAME), None)
    if not row:
        raise SystemExit("SpeedFloor candidate build metadata missing")
    if row.get("pe_machine") != "0x014C":
        raise SystemExit("SpeedFloor candidate is not x86 PE32")
    if row.get("has_import_directory"):
        raise SystemExit("SpeedFloor candidate unexpectedly has PE imports; optional ControlHub contract violated")
    return row


def zip_root_names(package):
    with zipfile.ZipFile(package, "r") as zf:
        return zf.namelist()


def read_loader_manifest(package):
    with zipfile.ZipFile(package, "r") as zf:
        if DLL_LIST_NAME not in zf.namelist():
            return []
        text = zf.read(DLL_LIST_NAME).decode("ascii", errors="strict")
    return [line.strip() for line in text.splitlines() if line.strip()]


def main():
    ap = argparse.ArgumentParser(description="Build WoWControlHub pilot and append it to a verified candidate package.")
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata", default="dist/controlhub_build.json")
    ap.add_argument("--output", default="build/WoWControlHub.dll")
    args = ap.parse_args()

    t0 = time.perf_counter()
    package = (ROOT / args.package).resolve()
    package_metadata_path = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve()
    build_metadata_path = (ROOT / args.build_metadata).resolve()
    output = (ROOT / args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    build_metadata_path.parent.mkdir(parents=True, exist_ok=True)

    if not HUB_SOURCE.is_file():
        raise SystemExit(f"ControlHub source missing: {HUB_SOURCE.relative_to(ROOT)}")
    if not package_metadata_path.is_file() or not summary_path.is_file():
        raise SystemExit("candidate metadata/summary missing; generic verified candidate must be built first")

    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    package_meta = json.loads(package_metadata_path.read_text(encoding="utf-8"))
    if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
        raise SystemExit("base candidate is not READY_FOR_TEST")
    speed_row = require_speedfloor_candidate(summary)

    obj = output.with_suffix(".obj")
    timing, pe = build_one(HUB_PROFILE, HUB_SOURCE, obj, output)

    if pe.get("machine_hex") != "0x014C" or pe.get("entrypoint_rva") == 0:
        raise SystemExit("ControlHub PE32/x86/entrypoint verification failed")
    if not pe.get("has_import_directory"):
        raise SystemExit("ControlHub Win32-import profile unexpectedly produced no import directory")

    hotkey_patch = patch_controlhub_hotkey(output)
    digest = sha256_file(output)

    hub_meta = {
        "name": HUB_NAME,
        "source_path": str(HUB_SOURCE.relative_to(ROOT)).replace("\\", "/"),
        "source_sha256": sha256_file(HUB_SOURCE),
        "build_profile": HUB_PROFILE,
        "toolchain_mode": timing.get("mode"),
        "sha256": digest,
        "size": output.stat().st_size,
        "pe_machine": pe.get("machine_hex"),
        "entrypoint_rva": pe.get("entrypoint_rva"),
        "has_import_directory": pe.get("has_import_directory"),
        "speedfloor_optional_dependency_verified": not bool(speed_row.get("has_import_directory")),
        "candidate_hotkey": HOTKEY_NAME,
        "candidate_hotkey_binary_patch": hotkey_patch,
        "timings_ms": timing,
    }

    loader_dlls = deterministic_repack(package, output)
    names = zip_root_names(package)
    actual_loader_dlls = read_loader_manifest(package)
    if HUB_NAME not in names:
        raise SystemExit("ControlHub missing from candidate ZIP after repack")
    if DLL_LIST_NAME not in names:
        raise SystemExit("dlls.txt missing from ControlHub candidate ZIP")
    if any("/" in name.rstrip("/") for name in names):
        raise SystemExit("candidate ZIP unexpectedly contains nested paths")
    if HUB_NAME not in actual_loader_dlls:
        raise SystemExit("dlls.txt does not load WoWControlHub.dll")
    package_dlls = [name for name in names if name.lower().endswith(".dll")]
    if {x.lower() for x in actual_loader_dlls} != {x.lower() for x in package_dlls}:
        raise SystemExit("dlls.txt does not exactly match candidate ZIP DLL set")
    if actual_loader_dlls != loader_dlls:
        raise SystemExit("dlls.txt round-trip mismatch")

    package_sha = sha256_file(package)
    package_size = package.stat().st_size

    entries = list(package_meta.get("zip_root_entries") or [])
    if HUB_NAME not in entries:
        entries.append(HUB_NAME)
    if DLL_LIST_NAME not in entries:
        entries.append(DLL_LIST_NAME)
    loader_meta = {
        "name": DLL_LIST_NAME,
        "generated_from_candidate_zip": True,
        "dll_count": len(actual_loader_dlls),
        "dlls": actual_loader_dlls,
        "contains_controlhub": HUB_NAME in actual_loader_dlls,
    }
    package_meta["zip_root_entries"] = entries
    package_meta["package_sha256"] = package_sha
    package_meta["package_size"] = package_size
    package_meta["candidate_extra_dll_count"] = 1
    package_meta["candidate_extra_dlls"] = [hub_meta]
    package_meta["loader_manifest"] = loader_meta
    package_meta["controlhub_pilot"] = {
        "abi": "W112_CONTROL_API_V1",
        "optional": True,
        "provider": SPEED_NAME,
        "provider_has_import_directory": bool(speed_row.get("has_import_directory")),
        "gui_toggle": HOTKEY_NAME,
        "render_input": "Win32 layered overlay + game WndProc subclass",
        "loader_manifest": DLL_LIST_NAME,
        "hotkey_conflict_avoided": "MovementCore F10 MODE_PURSUIT",
    }
    package_metadata_path.write_text(json.dumps(package_meta, indent=2) + "\n", encoding="utf-8")

    summary["package_sha256"] = package_sha
    summary["package_size"] = package_size
    summary["zip_root_entries"] = entries
    summary["candidate_extra_dll_count"] = 1
    summary["candidate_extra_dlls"] = [hub_meta]
    summary["loader_manifest"] = loader_meta
    summary["controlhub_pilot"] = package_meta["controlhub_pilot"]
    summary["ready_for_test"] = bool(
        summary.get("ready_for_test")
        and HUB_NAME in names
        and DLL_LIST_NAME in names
        and HUB_NAME in actual_loader_dlls
        and speed_row.get("pe_machine") == "0x014C"
        and not speed_row.get("has_import_directory")
        and pe.get("machine_hex") == "0x014C"
        and pe.get("entrypoint_rva") != 0
        and len(hotkey_patch) == 2
    )
    summary["result"] = "PASS" if summary["ready_for_test"] else "FAIL"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    hub_meta["candidate_package"] = str(package.relative_to(ROOT)).replace("\\", "/")
    hub_meta["candidate_package_sha256"] = package_sha
    hub_meta["candidate_package_size"] = package_size
    hub_meta["loader_manifest"] = loader_meta
    hub_meta["process_total_ms"] = (time.perf_counter() - t0) * 1000.0
    build_metadata_path.write_text(json.dumps(hub_meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(hub_meta, indent=2))

    if not summary["ready_for_test"]:
        raise SystemExit("ControlHub candidate verdict is not READY_FOR_TEST")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())