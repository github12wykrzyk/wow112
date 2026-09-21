#!/usr/bin/env python3
"""Read-only, SHA-pinned inspection of the accepted AutoLootPP scanner code."""
import hashlib
import lzma
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
EXPECTED = "05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845"
CACHE = ROOT / "artifacts/runtime_cache" / (EXPECTED + ".dll.xz")


def main():
    binary = lzma.decompress(CACHE.read_bytes())
    digest = hashlib.sha256(binary).hexdigest()
    if digest != EXPECTED or len(binary) != 20992:
        raise SystemExit("Unrecognized AutoLootPP binary: do not patch")
    with tempfile.TemporaryDirectory(prefix="wow112-pp-probe-") as td:
        dll = Path(td) / NAME
        dll.write_bytes(binary)
        proc = subprocess.run(
            ["objdump", "-d", "-M", "intel", "-j", ".text", str(dll)],
            text=True, capture_output=True, check=True)
        lines = proc.stdout.splitlines()
        matches = []
        for index, line in enumerate(lines):
            if re.search(r"\b(?:cmp|sub|add)\b.*\b0x(?:64|50|5|15e)\b", line):
                matches.append(index)
        print("BASE_SHA256:", digest)
        print("MATCHES:", len(matches))
        for index in matches[:120]:
            print("\n=== CANDIDATE ===")
            for line in lines[max(0, index-5):index+7]:
                print(line)
        for query in ("0x606980", "0x605570", "0x10001f", "0x100018"):
            found = [i for i, ln in enumerate(lines) if query in ln.lower()]
            print("\\n=== FILTER REFERENCES", query, "count=", len(found), "===")
            for index in found[:12]:
                for line in lines[max(0,index-14):index+20]:
                    print(line)
                print("----")
        print("\\n=== SELECTOR DISASSEMBLY 0x10001d00-0x10001f90 ===")
        for line in lines:
            m = re.search(r"^\\s*([0-9a-f]{8}):", line)
            if m and 0x10001d00 <= int(m.group(1),16) < 0x10001f90:
                print(line)
        print("\nINSPECTION_ONLY: no DLL changed")


if __name__ == "__main__":
    main()
