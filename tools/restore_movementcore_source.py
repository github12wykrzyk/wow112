#!/usr/bin/env python3
import argparse
import base64
import hashlib
import lzma
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PART_DIR = ROOT / "artifacts" / "V68" / "source"
PART_NAMES = [
    "WoWMovementCore_v20.c.xz.b64.part000",
    "WoWMovementCore_v20.c.xz.b64.part001",
    "WoWMovementCore_v20.c.xz.b64.part002",
    "WoWMovementCore_v20.c.xz.b64.part003",
]
EXPECTED_XZ_SHA256 = "ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48"
EXPECTED_SOURCE_SHA256 = "764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888"
EXPECTED_XZ_SIZE = 23480
EXPECTED_SOURCE_SIZE = 107833
DEFAULT_OUTPUT = ROOT / "generated" / "WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def restore_bytes():
    encoded_parts = []
    for name in PART_NAMES:
        path = PART_DIR / name
        if not path.is_file():
            raise RuntimeError("missing source part: %s" % path.relative_to(ROOT))
        encoded_parts.append(path.read_text(encoding="ascii").strip())

    try:
        xz_data = base64.b64decode("".join(encoded_parts), validate=True)
    except Exception as exc:
        raise RuntimeError("Base64 decode failed: %s" % exc)

    if len(xz_data) != EXPECTED_XZ_SIZE:
        raise RuntimeError("XZ size mismatch: got %d expected %d" % (len(xz_data), EXPECTED_XZ_SIZE))
    xz_hash = sha256(xz_data)
    if xz_hash != EXPECTED_XZ_SHA256:
        raise RuntimeError("XZ SHA256 mismatch: got %s expected %s" % (xz_hash, EXPECTED_XZ_SHA256))

    try:
        source = lzma.decompress(xz_data, format=lzma.FORMAT_XZ)
    except Exception as exc:
        raise RuntimeError("XZ decompress failed: %s" % exc)

    if len(source) != EXPECTED_SOURCE_SIZE:
        raise RuntimeError("source size mismatch: got %d expected %d" % (len(source), EXPECTED_SOURCE_SIZE))
    source_hash = sha256(source)
    if source_hash != EXPECTED_SOURCE_SHA256:
        raise RuntimeError("source SHA256 mismatch: got %s expected %s" % (source_hash, EXPECTED_SOURCE_SHA256))

    return source


def main():
    parser = argparse.ArgumentParser(description="Restore and verify canonical V68 MovementCore source")
    parser.add_argument("--verify-only", action="store_true", help="verify source archive without writing a file")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="output .c path")
    args = parser.parse_args()

    try:
        source = restore_bytes()
    except RuntimeError as exc:
        print("FAIL: %s" % exc)
        return 1

    print("PASS: V68 MovementCore source archive verified")
    print("  source size: %d" % len(source))
    print("  source SHA256: %s" % EXPECTED_SOURCE_SHA256)

    if args.verify_only:
        return 0

    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(source)
    print("  restored: %s" % output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
