#!/usr/bin/env python3
"""Exact WoW 1.12.1 build 5875 LongPickPocket v0.9 -> v1.0 reproducer."""
from pathlib import Path
import hashlib, sys

OLD_SHA = "764605590462e4161b4c4badb37db990a33a8ae0037e730e03db78233d2c3717"
NEW_SHA = "dc4a8d85b850728f39e07a04c49a7f7b60e72b8ec2fdebb94b86dad3a47474d2"
OFFSET = 0x1497
OLD = bytes.fromhex("0f83cf010000")
NEW = bytes.fromhex("909090909090")

def sha(b): return hashlib.sha256(b).hexdigest()

def main():
    if len(sys.argv) not in (2,3):
        print(f"usage: {sys.argv[0]} <v0.9.dll> [v1.0.dll]")
        return 2
    src=Path(sys.argv[1]); dst=Path(sys.argv[2]) if len(sys.argv)==3 else src.with_name("WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025_REPRODUCED.dll")
    b=bytearray(src.read_bytes())
    if sha(b)!=OLD_SHA: raise SystemExit("input SHA256 is not exact preserved v0.9")
    if bytes(b[OFFSET:OFFSET+len(OLD)])!=OLD: raise SystemExit("v0.9 gate bytes do not match")
    b[OFFSET:OFFSET+len(NEW)]=NEW
    if sha(b)!=NEW_SHA: raise SystemExit("output SHA256 does not match final v1.0")
    dst.write_bytes(b)
    print(f"OK {dst} SHA256={NEW_SHA}")
    return 0
if __name__=="__main__": raise SystemExit(main())
