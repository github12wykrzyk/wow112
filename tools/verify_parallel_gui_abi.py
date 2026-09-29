#!/usr/bin/env python3
"""Fast Win32 ABI preflight for the parallel ESP native GUI."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/WoWPlayerESP/WoWPlayerESP_v1_3_CHALLENGES.c"

def main():
    text = SOURCE.read_text(encoding="utf-8")
    prototypes = re.findall(
        r"__declspec\\(dllimport\\)\\s+HFONT\\s+WINAPI\\s+CreateFontA\\s*\\(([^()]*)\\)\\s*;",
        text,
    )
    if len(prototypes) != 1:
        print("ERROR: expected one explicit CreateFontA Win32 import prototype")
        return 1
    types = [x.strip() for x in prototypes[0].split(",")]
    expected = ["int"] * 5 + ["DWORD"] * 8 + ["LPCSTR"]
    if types != expected:
        print("ERROR: CreateFontA Win32 ABI requires 5 int + 8 DWORD + LPCSTR (14 arguments)")
        print("GOT:", types)
        return 1
    calls = re.findall(r"\\bCreateFontA\\s*\\(([^()]*)\\)", text)
    if len(calls) < 3:
        print("ERROR: expected CreateFontA declaration and both GUI font allocations")
        return 1
    for call in calls:
        argc = len(call.split(","))
        if argc != 14:
            print("ERROR: CreateFontA declaration/call has", argc, "arguments; expected 14")
            return 1
    print("PARALLEL_GUI_WIN32_ABI: PASS (CreateFontA prototype and %d calls)" % (len(calls)-1))
    return 0

if __name__ == "__main__":
    sys.exit(main())
