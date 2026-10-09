#!/usr/bin/env python3
"""Pin and append the audited OctoLogin v1.1.0 release to runnable candidates.

The runtime ZIP format is intentionally flat. OctoLogin is location-agnostic, so the
verified upstream DLL is installed as ``OctoLogin.dll`` in the WoW root instead of the
upstream ``mods/`` convention. The updater already owns DLL installation, backup,
rollback and ``dlls.txt`` generation for root DLLs.
"""

import hashlib
import json
import os
import struct
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

DLL_NAME = "OctoLogin.dll"
DLL_LIST = "dlls.txt"
VERSION = "v1.1.0"
SOURCE_REPOSITORY = "https://github.com/fmustafayaman/OctoLogin"
ASSET_URL = "https://github.com/fmustafayaman/OctoLogin/releases/download/v1.1.0/OctoLogin.dll"
EXPECTED_SHA256 = "fed726cc910084ec4191d7c02763f094a43c30b6944194136af70823865dabd9"
EXPECTED_SIZE = 60928
LICENSE = "MIT"


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _inspect_pe(data):
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise RuntimeError("OctoLogin asset is not an MZ executable")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 26 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        raise RuntimeError("OctoLogin asset has no valid PE signature")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    entrypoint = struct.unpack_from("<I", data, optional + 16)[0]
    if machine != 0x014C or magic != 0x010B or entrypoint == 0:
        raise RuntimeError(
            "OctoLogin asset is not a runnable PE32/x86 DLL "
            f"(machine=0x{machine:04X}, magic=0x{magic:04X}, entrypoint=0x{entrypoint:08X})"
        )
    return {"machine": "0x014C", "optional_magic": "0x010B", "entrypoint_rva": entrypoint}


def _validate_asset(data):
    digest = _sha256(data)
    if digest != EXPECTED_SHA256:
        raise RuntimeError(f"OctoLogin SHA256 mismatch: got={digest} expected={EXPECTED_SHA256}")
    if len(data) != EXPECTED_SIZE:
        raise RuntimeError(f"OctoLogin size mismatch: got={len(data)} expected={EXPECTED_SIZE}")
    return _inspect_pe(data)


def _download_asset():
    last_error = None
    for attempt in range(1, 4):
        try:
            req = urllib.request.Request(
                ASSET_URL,
                headers={"User-Agent": "WoW112CandidateBuilder/OctoLogin-v1"},
            )
            with urllib.request.urlopen(req, timeout=45) as response:
                data = response.read()
            pe = _validate_asset(data)
            return data, pe, attempt
        except Exception as exc:
            last_error = exc
            if attempt < 3:
                time.sleep(attempt)
    raise RuntimeError(f"OctoLogin pinned asset download failed after 3 attempts: {last_error}")


def _read_flat_zip(path):
    with zipfile.ZipFile(path, "r") as src:
        infos = src.infolist()
        names = [x.filename for x in infos]
        if len(names) != len({x.lower() for x in names}):
            raise RuntimeError("candidate ZIP contains duplicate/case-colliding entries")
        if any("/" in name.rstrip("/") or "\\" in name for name in names):
            raise RuntimeError("candidate ZIP contains nested/unsafe paths")
        return [(info.filename, src.read(info.filename)) for info in infos]


def _deterministic_repack(path, rows):
    path = Path(path)
    fd, temp_name = tempfile.mkstemp(prefix="wow112-octologin-", suffix=".zip", dir=str(path.parent))
    os.close(fd)
    temp = Path(temp_name)
    try:
        with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
            for name, data in rows:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                dst.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def _replace_named(rows, record):
    out = [x for x in (rows or []) if isinstance(x, dict) and str(x.get("name", "")).lower() != DLL_NAME.lower()]
    out.append(record)
    return out


def finalize_pinned_octologin(package, metadata_path, summary_path=None):
    """Ensure exact OctoLogin bytes + metadata are in a candidate before final verification.

    Returns a compact evidence object. This function is idempotent: if the exact pinned
    DLL is already present, it is reused without a network request.
    """
    package = Path(package)
    metadata_path = Path(metadata_path)
    summary_path = Path(summary_path) if summary_path else None
    if not package.is_file():
        raise RuntimeError(f"candidate ZIP missing: {package}")
    if not metadata_path.is_file():
        raise RuntimeError(f"candidate metadata missing: {metadata_path}")

    rows = _read_flat_zip(package)
    content = dict(rows)
    current = content.get(DLL_NAME)
    downloaded = False
    attempts = 0
    if current is not None:
        try:
            pe = _validate_asset(current)
            data = current
        except Exception:
            data, pe, attempts = _download_asset()
            downloaded = True
    else:
        data, pe, attempts = _download_asset()
        downloaded = True

    # dlls.txt is finalized by verify_candidate_package.py from final ZIP order.
    # Keeping it out of this repack avoids publishing a manifest between composition
    # and the final fail-closed loader-exact gate.
    kept = [(name, payload) for name, payload in rows if name not in (DLL_NAME, DLL_LIST)]
    kept.append((DLL_NAME, data))
    _deterministic_repack(package, kept)

    module_meta = {
        "name": DLL_NAME,
        "sha256": EXPECTED_SHA256,
        "size": EXPECTED_SIZE,
        "source_path": f"external:{SOURCE_REPOSITORY}@{VERSION}/{DLL_NAME}",
        "source_sha256": EXPECTED_SHA256,
        "build_profile": "external_pinned_release",
        "toolchain_mode": "upstream_release_asset",
        "pe_machine": pe["machine"],
        "entrypoint_rva": pe["entrypoint_rva"],
        "module_id": "octologin",
        "license": LICENSE,
        "upstream_version": VERSION,
        "upstream_asset_url": ASSET_URL,
        "upstream_repository": SOURCE_REPOSITORY,
        "scope": "WoW 1.12.1/5875 login endpoint racing and world-server selection; upstream hooks only the game's connect import",
    }
    component = {
        "module": DLL_NAME,
        "version": VERSION,
        "sha256": EXPECTED_SHA256,
        "size": EXPECTED_SIZE,
        "repository": SOURCE_REPOSITORY,
        "asset_url": ASSET_URL,
        "license": LICENSE,
        "placement": "wow_root",
        "loader_entry": DLL_NAME,
        "downloaded_this_run": downloaded,
        "download_attempts": attempts,
        "verification": "exact SHA256 + size + PE32/x86/entrypoint; final candidate gate re-verifies all PE entries and dlls.txt exactness",
    }

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    extras = _replace_named(metadata.get("candidate_extra_dlls"), module_meta)
    metadata["candidate_extra_dlls"] = extras
    metadata["candidate_extra_dll_count"] = len(extras)
    metadata["octologin_component"] = component
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    if summary_path and summary_path.is_file():
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        summary_extras = _replace_named(summary.get("candidate_extra_dlls"), module_meta)
        summary["candidate_extra_dlls"] = summary_extras
        summary["candidate_extra_dll_count"] = len(summary_extras)
        summary["octologin_component"] = component
        summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    evidence = dict(component)
    evidence["result"] = "PASS"
    evidence["package_sha256_after_component"] = _sha256(package.read_bytes())
    evidence["package_size_after_component"] = package.stat().st_size
    return evidence
