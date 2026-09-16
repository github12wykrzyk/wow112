#!/usr/bin/env python3
"""Apply/verify the build-5875 hard 5s Stealth EXE argument fix.

The existing hard patch detours 0x006E12C0 to 0x0075D401 and clamps the
cooldown durations to 5000 ms for Stealth ranks 1784..1787.  The original
patch selected the spell id from [esp+0x14], but reverse inspection of all
0x006E12C0 callers shows spellId is argument #1, i.e. [esp+0x04] before the
prologue.  This script changes only that ModRM/SIB displacement byte:

    VA 0x0075D401: 8B 44 24 14  ->  8B 44 24 04

Rollback is the inverse one-byte change.  The old/new full EXE hashes below
make this patch deterministic for the exact WoW 1.12.1 build 5875 lineage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CURRENT = ROOT / "CURRENT.json"
RUNTIME = ROOT / "runtime" / "current.json"
MANIFEST = ROOT / "manifests" / "SHA256SUMS_WORK.txt"

EXE_NAME = "WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe"
EXE = ROOT / EXE_NAME
OLD_SHA256 = "b24ebfe0a9fa49ba051911a904fc1dcb531d7c3908a35e77a84376d96b476f27"
NEW_SHA256 = "0a5ecb0023f9ba1dddecb25f4a636a0bcd1706db70583d9db3ad69ba51f9f227"
PATCH_OFFSET = 0x35D401  # VA 0x0075D401 in this PE (.text RVA/file mapping is 1:1)
OLD_INSN = bytes.fromhex("8B 44 24 14")
NEW_INSN = bytes.fromhex("8B 44 24 04")
CLAMP_CONTEXT = bytes.fromhex(
    "8B 44 24 04 8B D0 83 E2 FC 81 FA F8 06 00 00 75 1A "
    "C7 44 24 10 88 13 00 00 81 7C 24 1C 88 13 00 00"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_exe() -> None:
    data = bytearray(EXE.read_bytes())
    digest = sha256(data)
    insn = bytes(data[PATCH_OFFSET : PATCH_OFFSET + 4])

    if digest == NEW_SHA256 and insn == NEW_INSN:
        return
    if digest != OLD_SHA256:
        raise SystemExit(f"unexpected EXE SHA256: {digest}")
    if insn != OLD_INSN:
        raise SystemExit(
            f"unexpected bytes at 0x{PATCH_OFFSET:X}: {insn.hex(' ')}"
        )

    data[PATCH_OFFSET : PATCH_OFFSET + 4] = NEW_INSN
    result = sha256(data)
    if result != NEW_SHA256:
        raise SystemExit(f"patched EXE hash mismatch: {result}")
    EXE.write_bytes(data)


def replace_hash(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if NEW_SHA256 in text:
        return
    if OLD_SHA256 not in text:
        raise SystemExit(f"old EXE hash not found in {path.relative_to(ROOT)}")
    path.write_text(text.replace(OLD_SHA256, NEW_SHA256, 1), encoding="utf-8")


def verify() -> None:
    data = EXE.read_bytes()
    digest = sha256(data)
    if digest != NEW_SHA256:
        raise SystemExit(f"EXE SHA256 mismatch: {digest}")
    if data[PATCH_OFFSET : PATCH_OFFSET + 4] != NEW_INSN:
        raise SystemExit("Stealth spellId argument fix is missing")
    if data[PATCH_OFFSET : PATCH_OFFSET + len(CLAMP_CONTEXT)] != CLAMP_CONTEXT:
        raise SystemExit("Stealth 5s clamp context is not exact")

    current = json.loads(CURRENT.read_text(encoding="utf-8"))
    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    if current["exe"]["name"] != EXE_NAME or current["exe"]["sha256"] != NEW_SHA256:
        raise SystemExit("CURRENT.json EXE identity mismatch")
    if runtime["exe"]["name"] != EXE_NAME or runtime["exe"]["sha256"] != NEW_SHA256:
        raise SystemExit("runtime/current.json EXE identity mismatch")
    manifest_line = f"{NEW_SHA256}  {EXE_NAME}"
    if manifest_line not in MANIFEST.read_text(encoding="utf-8"):
        raise SystemExit("work SHA256 manifest EXE identity mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if not args.check:
        patch_exe()
        replace_hash(CURRENT)
        replace_hash(RUNTIME)
        replace_hash(MANIFEST)
    verify()
    print("PASS: hard Stealth 5s EXE argfix is exact")


if __name__ == "__main__":
    main()
