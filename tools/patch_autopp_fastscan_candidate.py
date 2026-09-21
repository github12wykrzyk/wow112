#!/usr/bin/env python3
"""Hash-pinned, one-byte TEST-only PP scanner patch for WoW 5875 x86.

Only the idle PP target-rescan comparison at RVA 0x201B changes: 100 -> 20 ms.
The separate world/life scan, loot state machine and PP retry remain byte-identical.
Never use the reconstructed AutoLootPP source to replace the historical DLL.
"""
import argparse
import hashlib
import json
import lzma
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
BASE_SHA = "05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845"
CACHE = ROOT / "artifacts/runtime_cache" / (BASE_SHA + ".dll.xz")
RVA = 0x2013
OLD = bytes.fromhex("89e82b05f0ea001083f86472e9892df0ea0010")
NEW = OLD[:10] + bytes([20]) + OLD[11:]
WORLD_RVA = 0x10CB
WORLD = bytes.fromhex("89e82b053860001083f8640f83")
RETRY_RVA = 0x1AA6
RETRY = bytes.fromhex("3d5e010000")


def digest(b):
    return hashlib.sha256(b).hexdigest()


def raw_offset(image, rva):
    if image[:2] != b"MZ":
        raise ValueError("not a DOS/PE binary")
    pe = struct.unpack_from("<I", image, 0x3C)[0]
    if image[pe:pe+4] != b"PE\0\0":
        raise ValueError("not PE")
    machine, count = struct.unpack_from("<HH", image, pe+4)
    opt_size = struct.unpack_from("<H", image, pe+20)[0]
    opt = pe + 24
    if machine != 0x14C or struct.unpack_from("<H", image, opt)[0] != 0x10B:
        raise ValueError("not WoW-compatible PE32 x86")
    sections = opt + opt_size
    for i in range(count):
        pos = sections + i*40
        vsize, vaddr, rsize, rptr = struct.unpack_from("<IIII", image, pos+8)
        if vaddr <= rva < vaddr+min(vsize, rsize):
            return rptr+(rva-vaddr)
    raise ValueError("RVA outside raw PE sections")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--metadata", required=True)
    args = parser.parse_args()
    original = lzma.decompress(CACHE.read_bytes())
    if len(original) != 20992 or digest(original) != BASE_SHA:
        raise SystemExit("FAIL: cached AutoLootPP bytes do not match exact accepted baseline")
    offset = raw_offset(original, RVA)
    world = raw_offset(original, WORLD_RVA)
    retry = raw_offset(original, RETRY_RVA)
    if original[offset:offset+len(OLD)] != OLD or original[world:world+len(WORLD)] != WORLD or original[retry:retry+len(RETRY)] != RETRY:
        raise SystemExit("FAIL: scan/world/retry instruction signatures differ from verified v0.14")
    if original.count(OLD) != 1:
        raise SystemExit("FAIL: PP scanner instruction sequence is not unique")
    candidate = bytearray(original)
    candidate[offset:offset+len(OLD)] = NEW
    delta = [i for i, (a,b) in enumerate(zip(original, candidate)) if a != b]
    if len(candidate) != len(original) or delta != [offset+10]:
        raise SystemExit("FAIL: patch changed more than the PP scan immediate")
    if bytes(candidate[world:world+len(WORLD)]) != WORLD or bytes(candidate[retry:retry+len(RETRY)]) != RETRY:
        raise SystemExit("FAIL: world scan or PP retry changed")
    output = Path(args.output)
    metadata = Path(args.metadata)
    output.parent.mkdir(parents=True, exist_ok=True)
    metadata.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(candidate)
    report = {
        "kind": "exact_binary_one_byte_candidate_patch",
        "runtime_name": MODULE,
        "stable_sha256": BASE_SHA,
        "candidate_sha256": digest(candidate),
        "baseline_size": len(original),
        "candidate_size": len(candidate),
        "file_offset": offset+10,
        "instruction_rva": RVA+8,
        "old_scan_ms": 100,
        "candidate_scan_ms": 20,
        "world_scan_ms_unchanged": 100,
        "pp_retry_ms_unchanged": 350,
        "changed_byte_count": len(delta),
        "source_status": "original binary patch; reconstructed source NOT compiled",
        "result": "PASS",
    }
    metadata.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print("AUTOPP_FAST_SCAN_PATCH: PASS", json.dumps(report))


if __name__ == "__main__":
    main()
