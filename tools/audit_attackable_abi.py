#!/usr/bin/env python3
"""Read-only exact-byte evidence for native CanAttack (0x00606980) on WoW 5875 x86.

Passing evidence collection does NOT establish an ABI verdict or a runtime crash.
"""
import argparse
import hashlib
import json
import lzma
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDRESS = 0x00606980
PROLOGUE = bytes.fromhex("55 8B EC 56 8B 75 08 8B 46 08 57 8B F9")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pe(data, name):
    if len(data) < 0x100 or data[:2] != b"MZ":
        raise ValueError(f"{name}: invalid MZ")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_offset + 24 > len(data) or data[pe_offset:pe_offset+4] != b"PE\0\0":
        raise ValueError(f"{name}: invalid PE")
    machine, count, _, _, _, opt_size, _ = struct.unpack_from("<HHIIIHH", data, pe_offset+4)
    opt = pe_offset+24
    if machine != 0x014C or struct.unpack_from("<H", data, opt)[0] != 0x10B:
        raise ValueError(f"{name}: expected PE32 i386")
    base = struct.unpack_from("<I", data, opt+28)[0]
    sections = []
    for i in range(count):
        off = opt+opt_size+40*i
        if off+40 > len(data):
            raise ValueError(f"{name}: truncated section table")
        name8, _, rva, length, position = struct.unpack_from("<8sIIII", data, off)
        section = name8.split(b"\0", 1)[0].decode("ascii", "replace")
        if position+length > len(data):
            raise ValueError(f"{name}: section {section} outside file")
        sections.append((section, rva, position, length))
    return base, sections


def row(runtime, prefix):
    return next(x for x in runtime["active_dlls"] if x["name"].startswith(prefix))


def declaration(item):
    source = ROOT/item["source_path"]
    lines = [s.strip() for s in source.read_text(encoding="utf-8").splitlines()
             if "typedef" in s and ("AttackableFn" in s or "CanAttackFn" in s)]
    if not lines:
        raise ValueError(f"{item['name']}: missing native function typedef")
    return {"module": item["name"], "source": item["source_path"],
            "source_state": item["source_state"], "declarations": lines}


def audit():
    current = json.loads((ROOT/"CURRENT.json").read_text(encoding="utf-8"))
    runtime = json.loads((ROOT/current["runtime_manifest"]).read_text(encoding="utf-8"))
    ex = current["exe"]
    binary = (ROOT/ex["path"]).read_bytes()
    if sha(binary) != ex["sha256"] or sha(binary) != runtime["exe"]["sha256"]:
        raise ValueError("EXE SHA256 differs from authoritative CURRENT/runtime manifests")
    base, sections = pe(binary, ex["name"])
    native_rva = ADDRESS-base
    positions = [(name, offset+native_rva-rva) for name,rva,offset,length in sections
                 if rva <= native_rva < rva+length]
    if len(positions) != 1:
        raise ValueError("native address does not uniquely map to EXE file offset")
    section, file_offset = positions[0]
    actual = binary[file_offset:file_offset+len(PROLOGUE)]
    if actual != PROLOGUE:
        raise ValueError("native signature differs from canonical MovementCore V21 guard")
    loot = row(runtime, "WoWAutoLootPP_")
    artifact = loot.get("binary_artifact") or {}
    if artifact.get("kind") != "xz":
        raise ValueError("AutoLootPP exact XZ artifact missing from manifest")
    dll = lzma.decompress((ROOT/artifact["path"]).read_bytes())
    if sha(dll) != loot["sha256"] or sha(dll) != artifact["sha256"] or len(dll) != artifact["size"]:
        raise ValueError("exact AutoLootPP binary hash or size mismatch")
    _, dll_sections = pe(dll, loot["name"])
    needle = struct.pack("<I", ADDRESS)
    refs = []
    for name,rva,offset,length in dll_sections:
        if name != ".text":
            continue
        text = dll[offset:offset+length]
        pos = text.find(needle)
        while pos >= 0:
            start, end = max(0, pos-32), min(len(text), pos+36)
            refs.append({"file_offset": offset+pos, "rva": rva+pos,
                         "context_hex": text[start:end].hex(" ")})
            pos = text.find(needle, pos+1)
    if not refs:
        raise ValueError("exact AutoLootPP has no direct native address reference in .text")
    esp = row(runtime, "WoWPlayerESP_")
    esp_base = ROOT/"src/WoWPlayerESP/WoWPlayerESP_v1_2_range_sweep.c"
    esp_typedef = "typedef BYTE (__thiscall *CanAttackFn)(DWORD selfObj, DWORD targetObj)"
    if esp_typedef not in esp_base.read_text(encoding="utf-8"):
        raise ValueError("included PlayerESP v1.2 native typedef changed")
    return {
        "schema_version": 1, "result": "EVIDENCE_COLLECTED_ABI_UNRESOLVED",
        "address": f"0x{ADDRESS:08X}",
        "exe": {"name": ex["name"], "sha256": sha(binary), "section": section,
                "file_offset": file_offset, "native_prologue": actual.hex(" ")},
        "autolootpp": {**declaration(loot), "exact_binary_sha256": sha(dll),
                       "address_references": refs},
        "movementcore": declaration(row(runtime, "MovementCore_")),
        "playeresp": {"module": esp["name"], "base_source": str(esp_base.relative_to(ROOT)),
                      "declaration": esp_typedef},
        "interpretation": "Native signature and exact DLL reference contexts collected. "
                          "The divergent reconstructed AutoLootPP ABI is NOT validated by "
                          "this report; disassemble the exact DLL callsite before changing runtime."
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="dist/attackable_abi_audit.json")
    args = parser.parse_args()
    try:
        report = audit()
    except (ValueError, OSError, KeyError, StopIteration, struct.error, lzma.LZMAError) as exc:
        print("ABI AUDIT FAILED:", exc)
        return 1
    output = ROOT/args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False)+"\n", encoding="utf-8")
    print("ABI EVIDENCE COLLECTED; CALLING CONVENTION UNRESOLVED")
    print("AutoLootPP native address references:", len(report["autolootpp"]["address_references"]))
    print("Report:", output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
