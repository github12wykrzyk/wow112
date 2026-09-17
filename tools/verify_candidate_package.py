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
        rows = [(info.filename, zf.read(info.filename)) for info in infos]
    return rows


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
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def verify_extra_metadata(extras, content):
    names = set(content)
    seen = set()
    required = []
    for row in extras or []:
        if not isinstance(row, dict):
            raise SystemExit("candidate_extra_dlls contains a non-object")
        name = row.get("name")
        if not name or not name.lower().endswith(".dll"):
            raise SystemExit("candidate_extra_dlls contains an invalid DLL name")
        if name not in names:
            raise SystemExit(f"candidate extra DLL missing from final ZIP: {name}")
        key = name.lower()
        if key in seen:
            raise SystemExit(f"duplicate candidate extra DLL metadata: {name}")
        seen.add(key)
        data = content[name]
        expected_hash = str(row.get("sha256", "")).lower()
        expected_size = row.get("size")
        if expected_hash and sha256_bytes(data) != expected_hash:
            raise SystemExit(f"candidate extra DLL SHA256 mismatch: {name}")
        if isinstance(expected_size, int) and len(data) != expected_size:
            raise SystemExit(f"candidate extra DLL size mismatch: {name}")
        required.append(name)
    return required


def main():
    ap = argparse.ArgumentParser(description="Verify/finalize the complete runnable WoW112 candidate ZIP.")
    ap.add_argument("--package", required=True)
    ap.add_argument("--package-metadata", required=True)
    ap.add_argument("--summary")
    ap.add_argument("--report", default="dist/final_package_verification.json")
    ap.add_argument("--finalize", action="store_true",
                    help="Create/repair dlls.txt and synchronize final package metadata.")
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
    summary = load_optional(summary_path) if summary_path else None

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
    current_loader = content.get(DLL_LIST)
    if current_loader != expected_loader:
        if not args.finalize:
            raise SystemExit("dlls.txt is missing or does not exactly match final DLL order")
        rows = [(name, data) for name, data in rows if name != DLL_LIST]
        rows.append((DLL_LIST, expected_loader))
        deterministic_repack(package, rows)
        rows = read_zip(package)
        content = dict(rows)

    actual_loader = content.get(DLL_LIST)
    if actual_loader != expected_loader:
        raise SystemExit("final dlls.txt round-trip verification failed")

    pe = {}
    for name in exe_names + dll_names:
        pe[name] = inspect_pe(name, content[name])

    extras = metadata.get("candidate_extra_dlls") or []
    required_modules = verify_extra_metadata(extras, content)

    if summary is not None:
        if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
            raise SystemExit("candidate summary is not PASS/ready_for_test before final gate")
        summary_extras = summary.get("candidate_extra_dlls") or []
        summary_required = verify_extra_metadata(summary_extras, content)
        if [x.lower() for x in summary_required] != [x.lower() for x in required_modules]:
            raise SystemExit("candidate extra DLL metadata differs between summary and package metadata")

    package_sha = sha256_file(package)
    package_size = package.stat().st_size
    names = [name for name, _ in rows]

    active_count = metadata.get("active_dll_count")
    extra_count = len(required_modules)
    if isinstance(active_count, int) and active_count + extra_count != len(dll_names):
        raise SystemExit(
            f"final DLL count mismatch: active={active_count} extras={extra_count} ZIP={len(dll_names)}"
        )

    report = {
        "schema_version": 1,
        "result": "PASS",
        "package": str(package.relative_to(ROOT)).replace("\\", "/"),
        "package_sha256": package_sha,
        "package_size": package_size,
        "exe": exe_names[0],
        "dll_count": len(dll_names),
        "dlls": dll_names,
        "loader_manifest": DLL_LIST,
        "loader_exact": True,
        "all_binary_entries_pe32_x86": True,
        "candidate_required_modules": required_modules,
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
        metadata["candidate_required_modules"] = required_modules
        metadata["loader_manifest"] = loader_meta
        metadata["final_package_verification"] = report
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

        if summary is not None:
            summary["package_sha256"] = package_sha
            summary["package_size"] = package_size
            summary["zip_root_entries"] = names
            summary["candidate_required_modules"] = required_modules
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
