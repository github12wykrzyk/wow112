#!/usr/bin/env python3
"""Patch exact active AutoLootPP v0.14 for cast/channel-safe corpse looting.

The canonical C source is a functional reconstruction and is not used to rebuild
this TEST candidate. This script starts from the exact active runtime DLL already
present in the aggregate candidate ZIP and applies a fail-closed 5875/x86 patch.
"""

import argparse
import hashlib
import json
import os
import struct
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DLL_NAME = "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
DLL_LIST_NAME = "dlls.txt"
BASE_SHA256 = "05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845"
PATCHED_SHA256 = "84801518ca0036612cb827074c149604233bf38eaa723cc91440d76102571220"
EXPECTED_SIZE = 20992

# Exact active-v0.14 bytes -> cast/channel guard.
# The corpse scanner has already cleared its candidate-valid flag when this
# guard runs. ECX is the local player object at this exact machine-code site.
PATCHES = (
    # mov eax,[0x00B41414] -> call 0x10004F2D
    (0x00003615, bytes.fromhex("a11414b400"), bytes.fromhex("e8130d0000")),
    # Keep guard ZF instead of overwriting it with test eax,eax.
    (0x0000361A, bytes.fromhex("85c0"), bytes.fromhex("9090")),
    # Busy (ZF=0) -> existing scanner epilogue.
    (0x0000361D, bytes.fromhex("84"), bytes.fromhex("85")),
    # Verified 18-byte NOP cave at VA 0x10004F2D:
    # edx = descriptor channel spell (+0x240)
    # edx |= normal cast field (+0xC8C)
    # idle -> 0x10004F78; busy -> return with ZF=0
    (
        0x0000432D,
        bytes.fromhex("90" * 18),
        bytes.fromhex("8b51088b92400200000b918c0c0000743ac3"),
    ),
    # Verified INT3 cave at VA 0x10004F78. Idle restores the overwritten
    # object-manager load without changing ZF and returns.
    (
        0x00004378,
        bytes.fromhex("cc" * 8),
        bytes.fromhex("a11414b400c3cccc"),
    ),
)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def inspect_pe(data):
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise SystemExit("patched AutoLootPP is not MZ")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 24 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("patched AutoLootPP has no PE signature")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    entry = struct.unpack_from("<I", data, pe + 24 + 16)[0]
    if machine != 0x014C or entry == 0:
        raise SystemExit(
            f"patched AutoLootPP PE check failed machine=0x{machine:04X} entry=0x{entry:08X}"
        )
    return {"machine_hex": f"0x{machine:04X}", "entrypoint_rva": entry}


def apply_patch(data):
    if len(data) != EXPECTED_SIZE:
        raise SystemExit(
            f"AutoLootPP input size mismatch: got={len(data)} expected={EXPECTED_SIZE}"
        )
    got = sha256_bytes(data)
    if got != BASE_SHA256:
        raise SystemExit(
            f"AutoLootPP input SHA256 mismatch: got={got} expected={BASE_SHA256}"
        )
    out = bytearray(data)
    for off, old, new in PATCHES:
        if len(old) != len(new):
            raise SystemExit(f"internal patch-size mismatch at 0x{off:X}")
        actual = bytes(out[off:off + len(old)])
        if actual != old:
            raise SystemExit(
                f"AutoLootPP patch preimage mismatch at 0x{off:X}: "
                f"got={actual.hex()} expected={old.hex()}"
            )
        out[off:off + len(new)] = new
    digest = sha256_bytes(out)
    if digest != PATCHED_SHA256:
        raise SystemExit(
            f"AutoLootPP output SHA256 mismatch: got={digest} expected={PATCHED_SHA256}"
        )
    return bytes(out)


def deterministic_replace(package, replacement):
    package = Path(package)
    with zipfile.ZipFile(package, "r") as src:
        rows = [(info.filename, src.read(info.filename)) for info in src.infolist()]
    found = 0
    replaced = []
    for name, data in rows:
        if name == DLL_NAME:
            replaced.append((name, replacement))
            found += 1
        else:
            replaced.append((name, data))
    if found != 1:
        raise SystemExit(
            f"expected exactly one {DLL_NAME} in candidate ZIP, found {found}"
        )

    fd, temp_name = tempfile.mkstemp(
        prefix="wow112-autoloot-guard-", suffix=".zip", dir=str(package.parent)
    )
    os.close(fd)
    temp = Path(temp_name)
    try:
        with zipfile.ZipFile(
            temp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as dst:
            for name, data in replaced:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                dst.writestr(
                    info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9
                )
        os.replace(temp, package)
    finally:
        if temp.exists():
            temp.unlink()


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
    ap = argparse.ArgumentParser(
        description="Apply exact AutoLootPP cast/channel guard to the work TEST candidate."
    )
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata", default="dist/autoloot_castguard_build.json")
    ap.add_argument("--output", default=f"build/{DLL_NAME}")
    args = ap.parse_args()

    t0 = time.perf_counter()
    package = (ROOT / args.package).resolve()
    package_meta_path = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve()
    build_meta_path = (ROOT / args.build_metadata).resolve()
    output = (ROOT / args.output).resolve()

    if not package.is_file() or not package_meta_path.is_file() or not summary_path.is_file():
        raise SystemExit("base candidate ZIP/metadata/summary missing")
    package_meta = json.loads(package_meta_path.read_text(encoding="utf-8"))
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    if summary.get("result") != "PASS" or not summary.get("ready_for_test"):
        raise SystemExit("base candidate is not READY_FOR_TEST")

    with zipfile.ZipFile(package, "r") as zf:
        names_before = zf.namelist()
        if names_before.count(DLL_NAME) != 1:
            raise SystemExit(f"candidate ZIP does not contain exactly one {DLL_NAME}")
        base = zf.read(DLL_NAME)

    patched = apply_patch(base)
    pe = inspect_pe(patched)
    output.parent.mkdir(parents=True, exist_ok=True)
    build_meta_path.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(patched)
    deterministic_replace(package, patched)

    with zipfile.ZipFile(package, "r") as zf:
        names_after = zf.namelist()
        final = zf.read(DLL_NAME)
        loader = zf.read(DLL_LIST_NAME) if DLL_LIST_NAME in names_after else None
    if names_after != names_before:
        raise SystemExit(
            "AutoLootPP guard unexpectedly changed candidate ZIP entry order/identity"
        )
    if sha256_bytes(final) != PATCHED_SHA256:
        raise SystemExit(
            "AutoLootPP guard replacement did not survive ZIP round-trip"
        )

    module_meta = {
        "name": DLL_NAME,
        "sha256": PATCHED_SHA256,
        "size": len(patched),
        "pe_machine": pe["machine_hex"],
        "entrypoint_rva": pe["entrypoint_rva"],
        "source_kind": "exact_runtime_binary_patch",
        "base_sha256": BASE_SHA256,
        "patch_scope": "corpse AutoLoot scanner initiation",
        "wow_build": 5875,
        "normal_cast_field": "player+0xC8C",
        "channel_field": "player->descriptor+0x240",
        "guard_behavior": (
            "skip corpse scan while either local-player cast field is nonzero; "
            "existing candidate-valid flag is cleared before the guard"
        ),
        "patch_sites": [
            "VA 0x10004215 -> guard call",
            "VA 0x1000421A -> preserve guard flags",
            "VA 0x1000421C -> busy JNE epilogue",
            "VA 0x10004F2D -> 18-byte guard cave",
            "VA 0x10004F78 -> idle object-manager restore cave",
        ],
    }

    package_sha = sha256_file(package)
    package_size = package.stat().st_size
    extras = replace_named(package_meta.get("candidate_extra_dlls"), DLL_NAME, module_meta)
    package_meta["package_sha256"] = package_sha
    package_meta["package_size"] = package_size
    package_meta["candidate_extra_dlls"] = extras
    package_meta["candidate_extra_dll_count"] = len(extras)
    package_meta["autoloot_cast_channel_guard"] = {
        "module": DLL_NAME,
        "base_sha256": BASE_SHA256,
        "candidate_sha256": PATCHED_SHA256,
        "normal_cast": "player+0xC8C",
        "channel": "player->descriptor+0x240",
        "scope": (
            "do not start corpse AutoLoot while local player is casting or channeling"
        ),
    }
    package_meta_path.write_text(
        json.dumps(package_meta, indent=2) + "\n", encoding="utf-8"
    )

    summary_extras = replace_named(
        summary.get("candidate_extra_dlls"), DLL_NAME, module_meta
    )
    summary["package_sha256"] = package_sha
    summary["package_size"] = package_size
    summary["candidate_extra_dlls"] = summary_extras
    summary["candidate_extra_dll_count"] = len(summary_extras)
    summary["autoloot_cast_channel_guard"] = package_meta[
        "autoloot_cast_channel_guard"
    ]
    summary["ready_for_test"] = bool(
        summary.get("ready_for_test")
        and sha256_bytes(final) == PATCHED_SHA256
        and pe["machine_hex"] == "0x014C"
        and pe["entrypoint_rva"] != 0
        and (loader is None or DLL_NAME.encode("ascii") in loader)
    )
    summary["result"] = "PASS" if summary["ready_for_test"] else "FAIL"
    summary_path.write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )

    module_meta["candidate_package_sha256"] = package_sha
    module_meta["candidate_package_size"] = package_size
    module_meta["output"] = str(output.relative_to(ROOT)).replace("\\", "/")
    module_meta["process_total_ms"] = (time.perf_counter() - t0) * 1000.0
    build_meta_path.write_text(
        json.dumps(module_meta, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(module_meta, indent=2))

    if not summary["ready_for_test"]:
        raise SystemExit(
            "AutoLootPP cast/channel guard candidate verdict is not READY_FOR_TEST"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
