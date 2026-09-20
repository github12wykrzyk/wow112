#!/usr/bin/env python3
"""Build and append the read-only TaxiFlightProbe V1 to the work candidate."""
import argparse
import json
import os
import tempfile
import zipfile
from pathlib import Path

from build_active_module import build_one, sha256_file

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/TaxiFlight/WoWTaxiFlightProbe_5875_v1.c"
DLL_NAME = "WoWTaxiFlightProbe_5875_v1.dll"
PROFILE = "clangcl_i686_win32imports"

def rewrite_zip(path, rows):
    fd, name = tempfile.mkstemp(prefix="wow112-taxi-", suffix=".zip", dir=str(path.parent))
    os.close(fd)
    temporary = Path(name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
            for filename, data in rows:
                info = zipfile.ZipInfo(filename, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                dst.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata", default="dist/taxiflight_build.json")
    ap.add_argument("--output", default="build/WoWTaxiFlightProbe_5875_v1.dll")
    args = ap.parse_args()

    package = ROOT / args.package
    metadata_path = ROOT / args.package_metadata
    summary_path = ROOT / args.summary
    build_metadata_path = ROOT / args.build_metadata
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    build_metadata_path.parent.mkdir(parents=True, exist_ok=True)
    if not package.is_file() or not metadata_path.is_file() or not summary_path.is_file():
        raise SystemExit("Base work candidate and metadata must exist before TaxiFlightProbe append")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
        raise SystemExit("Base work candidate is not verified/ready")

    timing, pe = build_one(PROFILE, SOURCE, output.with_suffix(".obj"), output)
    if pe.get("machine_hex") != "0x014C" or not pe.get("entrypoint_rva") or not pe.get("has_import_directory"):
        raise SystemExit("TaxiFlightProbe candidate is not PE32 x86 with Win32 imports")

    module = {
        "name": DLL_NAME,
        "source_path": str(SOURCE.relative_to(ROOT)).replace("\\", "/"),
        "source_sha256": sha256_file(SOURCE),
        "build_profile": PROFILE,
        "sha256": sha256_file(output),
        "size": output.stat().st_size,
        "pe_machine": pe["machine_hex"],
        "entrypoint_rva": pe["entrypoint_rva"],
        "has_import_directory": True,
        "mode": "experiment_opt_in_early_spline_ack",
        "native_opcode": "CMSG_MOVE_SPLINE_DONE",
        "hotkeys": {"start": "NUMPAD1", "instant": "NUMPAD2", "end": "NUMPAD3"},
        "requires_num_lock": True,
        "server_completion_verified": False,
        "writes_game_state": True,
        "timings_ms": timing,
    }
    with zipfile.ZipFile(package, "r") as src:
        rows = [(item.filename, src.read(item.filename))
                for item in src.infolist()
                if item.filename not in (DLL_NAME, "dlls.txt")]
    if any("/" in name.rstrip("/") or "\\" in name for name, _ in rows):
        raise SystemExit("Nested entries in base candidate")
    rows.append((DLL_NAME, output.read_bytes()))
    dlls = [name for name, _ in rows if name.lower().endswith(".dll")]
    rows.append(("dlls.txt", ("\r\n".join(dlls) + "\r\n").encode("ascii")))
    if len({name.lower() for name, _ in rows}) != len(rows):
        raise SystemExit("Duplicate ZIP entry")
    rewrite_zip(package, rows)
    with zipfile.ZipFile(package, "r") as src:
        if src.read(DLL_NAME) != output.read_bytes() or src.read("dlls.txt") != rows[-1][1]:
            raise SystemExit("TaxiFlightProbe ZIP round trip failed")
    for data in (metadata, summary):
        extras = [item for item in data.get("candidate_extra_dlls", [])
                  if item.get("name", "").lower() != DLL_NAME.lower()]
        extras.append(module)
        data["candidate_extra_dlls"] = extras
        data["candidate_extra_dll_count"] = len(extras)
        data["zip_root_entries"] = [name for name, _ in rows]
        data["package_sha256"] = sha256_file(package)
        data["package_size"] = package.stat().st_size
        data["loader_manifest"] = {
            "name": "dlls.txt", "generated_from_candidate_zip": True,
            "dll_count": len(dlls), "dlls": dlls,
        }
    summary["result"] = "PASS"
    summary["ready_for_test"] = True
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    build_metadata_path.write_text(json.dumps(module, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(module, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
