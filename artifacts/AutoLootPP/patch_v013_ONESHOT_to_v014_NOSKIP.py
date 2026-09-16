#!/usr/bin/env python3
"""Exact binary reproducer: WoWAutoLootPP v0.13 ONESHOT -> v0.14 NOSKIP.

Target: World of Warcraft 1.12.1 build 5875, Windows x86.
This patches the preserved exact v0.13 DLL into the supplied exact v0.14 DLL.
"""
from __future__ import print_function
import hashlib
import sys

V13_SHA256 = "641b64187e387fabfea41426962734ff3c1e5d0c2bbc4652e7df823d51e20a73"
V14_SHA256 = "05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845"
EXPECTED_SIZE = 20992
PATCH_OFFSET = 0x00000F07
OLD = bytes.fromhex("0f93c4")
NEW = bytes.fromhex("30e490")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if len(sys.argv) != 3:
        print("usage: patch_v013_ONESHOT_to_v014_NOSKIP.py <v0.13.dll> <v0.14.dll>", file=sys.stderr)
        return 2

    src_path, dst_path = sys.argv[1], sys.argv[2]
    with open(src_path, "rb") as f:
        data = bytearray(f.read())

    if len(data) != EXPECTED_SIZE:
        raise SystemExit("input size mismatch: got %d, expected %d" % (len(data), EXPECTED_SIZE))
    got = sha256_bytes(data)
    if got != V13_SHA256:
        raise SystemExit("input SHA256 mismatch: got %s, expected %s" % (got, V13_SHA256))
    if bytes(data[PATCH_OFFSET:PATCH_OFFSET + len(OLD)]) != OLD:
        raise SystemExit("input bytes mismatch at 0x%X" % PATCH_OFFSET)

    data[PATCH_OFFSET:PATCH_OFFSET + len(NEW)] = NEW

    out_sha = sha256_bytes(data)
    if out_sha != V14_SHA256:
        raise SystemExit("output SHA256 mismatch: got %s, expected %s" % (out_sha, V14_SHA256))

    with open(dst_path, "wb") as f:
        f.write(data)

    print("OK")
    print("input : %s" % V13_SHA256)
    print("patch : file+0x%08X  %s -> %s" % (PATCH_OFFSET, OLD.hex(), NEW.hex()))
    print("output: %s" % out_sha)
    return 0


if __name__ == "__main__":
    sys.exit(main())
