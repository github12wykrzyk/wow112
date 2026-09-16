#!/usr/bin/env python3
import argparse
import json
import struct
import sys
from pathlib import Path

EXPECTED_MACHINE = 0x014C
EXPECTED_MAGIC = 0x010B
EXPORT_NAME = "W112_Control_GetModuleV1"

def u16(data, off):
    return struct.unpack_from("<H", data, off)[0]

def u32(data, off):
    return struct.unpack_from("<I", data, off)[0]

def parse_exports(path):
    data = Path(path).read_bytes()
    if len(data) < 0x100 or data[:2] != b"MZ":
        raise ValueError("not a PE image")
    pe = u32(data, 0x3C)
    if data[pe:pe+4] != b"PE\0\0":
        raise ValueError("missing PE signature")
    coff = pe + 4
    machine = u16(data, coff)
    sections = u16(data, coff + 2)
    opt_size = u16(data, coff + 16)
    opt = coff + 20
    magic = u16(data, opt)
    if magic != EXPECTED_MAGIC:
        raise ValueError("expected PE32 optional header")
    export_rva = u32(data, opt + 96)
    export_size = u32(data, opt + 100)
    sec = opt + opt_size

    section_rows = []
    for i in range(sections):
        off = sec + i * 40
        virtual_size = u32(data, off + 8)
        virtual_address = u32(data, off + 12)
        raw_size = u32(data, off + 16)
        raw_ptr = u32(data, off + 20)
        section_rows.append((virtual_address, max(virtual_size, raw_size), raw_ptr))

    def rva_to_off(rva):
        for va, span, raw in section_rows:
            if va <= rva < va + span:
                return raw + (rva - va)
        if rva < len(data):
            return rva
        raise ValueError("RVA outside mapped sections: 0x%08X" % rva)

    exports = []
    if export_rva:
        e = rva_to_off(export_rva)
        number_of_names = u32(data, e + 24)
        address_of_names = u32(data, e + 32)
        names_off = rva_to_off(address_of_names)
        for i in range(number_of_names):
            name_rva = u32(data, names_off + i * 4)
            noff = rva_to_off(name_rva)
            end = data.find(b"\0", noff)
            if end < 0:
                raise ValueError("unterminated export name")
            exports.append(data[noff:end].decode("ascii", "strict"))

    return {
        "path": str(path),
        "machine": "0x%04X" % machine,
        "pe_magic": "0x%04X" % magic,
        "export_directory_size": export_size,
        "exports": exports,
        "provider_export": EXPORT_NAME in exports,
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dll", nargs="+")
    ap.add_argument("--json-out")
    args = ap.parse_args()
    rows = []
    failed = False
    for dll in args.dll:
        try:
            row = parse_exports(dll)
            if row["machine"] != "0x014C" or row["pe_magic"] != "0x010B" or not row["provider_export"]:
                failed = True
            rows.append(row)
        except Exception as exc:
            failed = True
            rows.append({"path": dll, "error": str(exc), "provider_export": False})
    report = {"expected_export": EXPORT_NAME, "dlls": rows, "result": "FAIL" if failed else "PASS"}
    text = json.dumps(report, indent=2)
    print(text)
    if args.json_out:
        out = Path(args.json_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text + "\n", encoding="utf-8")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
