#!/usr/bin/env python3
"""Package the exact accepted current runtime bytes without rebuilding DLLs."""

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path

from exact_runtime_artifacts import load_registry, resolve_exact_bytes

ROOT = Path(__file__).resolve().parents[1]
CURRENT = ROOT / "CURRENT.json"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def deterministic_zip(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="wow112-stable-", suffix=".zip", dir=str(path.parent))
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for name, data in rows:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def main():
    ap = argparse.ArgumentParser(description="Package exact current accepted runtime bytes; never recompiles stable DLLs.")
    ap.add_argument("--output", default="dist/WoW112_STABLE_CANDIDATE.zip")
    ap.add_argument("--metadata", default="dist/candidate_metadata.json")
    args = ap.parse_args()

    current = load_json(CURRENT)
    runtime_path = ROOT / current.get("runtime_manifest", "runtime/current.json")
    runtime = load_json(runtime_path)

    if current.get("status") != "stable":
        raise SystemExit("exact stable packaging requires CURRENT.json status=stable; curate a promotion tree first")
    if current.get("stable_baseline") != runtime.get("baseline"):
        raise SystemExit("CURRENT/runtime baseline mismatch")

    try:
        registry, registry_rel = load_registry(current)
    except Exception as exc:
        raise SystemExit(str(exc))

    exe_meta = runtime.get("exe") or {}
    exe_current = current.get("exe") or {}
    exe_name = exe_meta.get("name")
    exe_rel = exe_current.get("path")
    if not exe_name or not exe_rel or exe_current.get("name") != exe_name:
        raise SystemExit("canonical EXE routing is incomplete or inconsistent")
    exe_path = ROOT / exe_rel
    if not exe_path.is_file():
        raise SystemExit(f"canonical EXE missing: {exe_rel}")
    exe_data = exe_path.read_bytes()
    expected_exe_hash = str(exe_meta.get("sha256", "")).lower()
    if sha256_bytes(exe_data) != expected_exe_hash:
        raise SystemExit("canonical EXE SHA256 mismatch while packaging stable")
    if str(exe_current.get("sha256", "")).lower() != expected_exe_hash:
        raise SystemExit("CURRENT/runtime EXE SHA256 mismatch")
    if isinstance(exe_meta.get("size"), int) and len(exe_data) != exe_meta["size"]:
        raise SystemExit("canonical EXE size mismatch")

    rows = [(exe_name, exe_data)]
    dlls = runtime.get("active_dlls") or []
    if not dlls:
        raise SystemExit("runtime/current.json has no active DLLs")

    resolved = []
    for item in dlls:
        name = item.get("name")
        if not name or not name.lower().endswith(".dll"):
            raise SystemExit(f"invalid active DLL entry: {item!r}")
        try:
            data, meta = resolve_exact_bytes(item, current, registry)
        except Exception as exc:
            raise SystemExit(str(exc))
        rows.append((name, data))
        resolved.append(meta)

    out = (ROOT / args.output).resolve()
    metadata_path = (ROOT / args.metadata).resolve()
    deterministic_zip(out, rows)

    metadata = {
        "schema_version": 3,
        "git_head": os.environ.get("GITHUB_SHA"),
        "baseline": runtime.get("baseline"),
        "wow_build": runtime.get("wow_build"),
        "architecture": current.get("architecture"),
        "package": str(out.relative_to(ROOT)).replace("\\", "/"),
        "package_sha256": sha256_file(out),
        "package_size": out.stat().st_size,
        "zip_root_entries": [name for name, _ in rows],
        "exe": {"name": exe_name, "sha256": expected_exe_hash, "size": len(exe_data), "in_zip_root": True},
        "active_dll_count": len(dlls),
        "active_dlls": resolved,
        "all_active_dlls_in_zip_root": True,
        "candidate_extra_dll_count": 0,
        "candidate_extra_dlls": [],
        "candidate_required_modules": [],
        "exact_artifact_registry": registry_rel,
        "stable_packaging_mode": "exact_accepted_bytes_no_rebuild"
    }
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))
    print("EXACT_STABLE_PACKAGE: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
