#!/usr/bin/env python3
"""Final fail-closed verification/finalization for runnable WoW112 ZIP artifacts."""

import argparse
import hashlib
import json
import os
import struct
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DLL_LIST = "dlls.txt"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def inspect_pe(name, data):
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise SystemExit(f"{name}: not an MZ executable")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 24 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit(f"{name}: missing PE signature")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    if machine != 0x014C:
        raise SystemExit(f"{name}: expected x86 machine 0x014C, got 0x{machine:04X}")
    optional = pe + 24
    if optional + 20 > len(data):
        raise SystemExit(f"{name}: truncated optional header")
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic not in (0x10B, 0x20B):
        raise SystemExit(f"{name}: unsupported PE optional-header magic 0x{magic:04X}")
    entrypoint = struct.unpack_from("<I", data, optional + 16)[0]
    if entrypoint == 0:
        raise SystemExit(f"{name}: zero entrypoint")
    return {"machine": f"0x{machine:04X}", "entrypoint_rva": entrypoint}


def read_zip(path):
    with zipfile.ZipFile(path, "r") as zf:
        infos = zf.infolist()
        names = [x.filename for x in infos]
        if len(names) != len({x.lower() for x in names}):
            raise SystemExit("candidate ZIP contains duplicate/case-colliding entries")
        if any("/" in name.rstrip("/") or "\\" in name for name in names):
            raise SystemExit("candidate ZIP contains nested/unsafe paths")
        return [(info.filename, zf.read(info.filename)) for info in infos]


def deterministic_repack(path, rows):
    fd, tmp_name = tempfile.mkstemp(prefix="wow112-final-", suffix=".zip", dir=str(Path(path).parent))
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
            for name, data in rows:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                dst.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def loader_bytes(dlls):
    return ("\r\n".join(dlls) + "\r\n").encode("ascii")


def load_optional(path):
    if not path or not Path(path).is_file():
        return None
    return json.loads(Path(path).read_text(encoding="utf-8"))


def validate_meta_rows(rows, content, label):
    out = []
    seen = set()
    for row in rows or []:
        if not isinstance(row, dict):
            raise SystemExit(f"{label} contains a non-object")
        name = row.get("name")
        if not name or not name.lower().endswith(".dll"):
            raise SystemExit(f"{label} contains an invalid DLL name")
        key = name.lower()
        if key in seen:
            raise SystemExit(f"duplicate {label} metadata: {name}")
        seen.add(key)
        if name not in content:
            raise SystemExit(f"{label} DLL missing from final ZIP: {name}")
        data = content[name]
        expected_hash = str(row.get("sha256", "")).lower()
        expected_size = row.get("size")
        if expected_hash and sha256_bytes(data) != expected_hash:
            raise SystemExit(f"{label} DLL SHA256 mismatch: {name}")
        if isinstance(expected_size, int) and expected_size > 0 and len(data) != expected_size:
            raise SystemExit(f"{label} DLL size mismatch: {name}")
        out.append(name)
    return out


def main():
    ap = argparse.ArgumentParser(description="Verify/finalize the complete runnable WoW112 candidate ZIP.")
    ap.add_argument("--package", required=True)
    ap.add_argument("--package-metadata", required=True)
    ap.add_argument("--summary")
    ap.add_argument("--report", default="dist/final_package_verification.json")
    ap.add_argument("--finalize", action="store_true")
    args = ap.parse_args()

    package = (ROOT / args.package).resolve()
    metadata_path = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve() if args.summary else None
    report_path = (ROOT / args.report).resolve()

    if not package.is_file():
        raise SystemExit(f"candidate ZIP missing: {package}")
    if not metadata_path.is_file():
        raise SystemExit(f"candidate metadata missing: {metadata_path}")

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    summary = load_optional(summary_path)

    rows = read_zip(package)
    content = dict(rows)
    exe_names = [name for name, _ in rows if name.lower().endswith(".exe")]
    dll_names = [name for name, _ in rows if name.lower().endswith(".dll")]
    if len(exe_names) != 1:
        raise SystemExit(f"candidate ZIP must contain exactly one EXE in root; got {len(exe_names)}")
    if not dll_names:
        raise SystemExit("candidate ZIP contains no DLLs")

    expected_exe = ((metadata.get("exe") or {}).get("name"))
    if expected_exe and exe_names[0] != expected_exe:
        raise SystemExit(f"candidate EXE mismatch: got {exe_names[0]}, expected {expected_exe}")

    expected_loader = loader_bytes(dll_names)
    if content.get(DLL_LIST) != expected_loader:
        if not args.finalize:
            raise SystemExit("dlls.txt is missing or does not exactly match final DLL order")
        rows = [(name, data) for name, data in rows if name != DLL_LIST]
        rows.append((DLL_LIST, expected_loader))
        deterministic_repack(package, rows)
        rows = read_zip(package)
        content = dict(rows)
    if content.get(DLL_LIST) != expected_loader:
        raise SystemExit("final dlls.txt round-trip verification failed")

    pe = {name: inspect_pe(name, content[name]) for name in exe_names + dll_names}

    active_rows = metadata.get("active_dlls") or []
    extra_rows = metadata.get("candidate_extra_dlls") or []
    active_names = validate_meta_rows(active_rows, content, "active_dlls")
    extra_names = validate_meta_rows(extra_rows, content, "candidate_extra_dlls")

    # Candidate extras may replace an already-active DLL (for example ControlHub)
    # or add a true companion DLL (for example AutoPoisons/DiagHub). Extra metadata
    # wins for replacements because it describes the final bytes actually packaged.
    active_keys = {x.lower() for x in active_names}
    companion_names = [name for name in extra_names if name.lower() not in active_keys]
    expected_final_keys = set(active_keys)
    expected_final_keys.update(name.lower() for name in companion_names)
    actual_final_keys = {name.lower() for name in dll_names}
    if expected_final_keys != actual_final_keys:
        missing = sorted(expected_final_keys - actual_final_keys)
        unexpected = sorted(actual_final_keys - expected_final_keys)
        raise SystemExit(f"final DLL identity set mismatch: missing={missing} unexpected={unexpected}")

    active_count = metadata.get("active_dll_count")
    if isinstance(active_count, int) and active_count != len(active_names):
        raise SystemExit(f"active DLL metadata count mismatch: declared={active_count} rows={len(active_names)}")
    if len(active_names) + len(companion_names) != len(dll_names):
        raise SystemExit(
            f"final DLL count mismatch: active={len(active_names)} companions={len(companion_names)} ZIP={len(dll_names)}"
        )

    if summary is not None:
        if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
            raise SystemExit("candidate summary is not PASS/ready_for_test before final gate")
        summary_extra_names = validate_meta_rows(summary.get("candidate_extra_dlls") or [], content, "summary candidate_extra_dlls")
        if [x.lower() for x in summary_extra_names] != [x.lower() for x in extra_names]:
            raise SystemExit("candidate extra DLL metadata differs between summary and package metadata")

    package_sha = sha256_file(package)
    package_size = package.stat().st_size
    names = [name for name, _ in rows]
    report = {
        "schema_version": 1,
        "result": "PASS",
        "package": str(package.relative_to(ROOT)).replace("\\", "/"),
        "package_sha256": package_sha,
        "package_size": package_size,
        "exe": exe_names[0],
        "active_dll_count": len(active_names),
        "companion_dll_count": len(companion_names),
        "dll_count": len(dll_names),
        "dlls": dll_names,
        "loader_manifest": DLL_LIST,
        "loader_exact": True,
        "all_binary_entries_pe32_x86": True,
        "candidate_replacements": [name for name in extra_names if name.lower() in active_keys],
        "candidate_required_modules": companion_names,
        "pe": pe,
    }

    if args.finalize:
        loader_meta = {
            "name": DLL_LIST,
            "generated_from_candidate_zip": True,
            "dll_count": len(dll_names),
            "dlls": dll_names,
        }
        metadata["package_sha256"] = package_sha
        metadata["package_size"] = package_size
        metadata["zip_root_entries"] = names
        metadata["candidate_required_modules"] = companion_names
        metadata["candidate_replacement_modules"] = report["candidate_replacements"]
        metadata["loader_manifest"] = loader_meta
        metadata["final_package_verification"] = report
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

        if summary is not None:
            summary["package_sha256"] = package_sha
            summary["package_size"] = package_size
            summary["zip_root_entries"] = names
            summary["candidate_required_modules"] = companion_names
            summary["candidate_replacement_modules"] = report["candidate_replacements"]
            summary["loader_manifest"] = loader_meta
            summary["final_package_verification"] = report
            summary["ready_for_test"] = True
            summary["result"] = "PASS"
            summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    else:
        expected_hash = str(metadata.get("package_sha256", "")).lower()
        if expected_hash and expected_hash != package_sha:
            raise SystemExit("candidate_metadata package_sha256 does not match final ZIP")

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print("FINAL_PACKAGE: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
