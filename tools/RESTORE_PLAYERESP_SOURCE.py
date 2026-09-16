from pathlib import Path
import base64
import hashlib
import lzma

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "artifacts"
PREFIX = "WoWPlayerESP_v1_2_range_sweep.c.xz.b64.part"
OUT = ROOT / "src" / "WoWPlayerESP" / "WoWPlayerESP_v1_2_range_sweep.c"
EXPECTED_SHA256 = "c7b64f2a979b533a360caca9033d9e92d61c88f820ecf495ca80851b8a8b9a63"
EXPECTED_SIZE = 81294

parts = [ART / (PREFIX + "%03d" % i) for i in range(5)]
b64 = b"".join(p.read_bytes() for p in parts)
source = lzma.decompress(base64.b64decode(b64))
sha = hashlib.sha256(source).hexdigest()

if len(source) != EXPECTED_SIZE:
    raise SystemExit("size mismatch: %d != %d" % (len(source), EXPECTED_SIZE))
if sha != EXPECTED_SHA256:
    raise SystemExit("sha256 mismatch: %s != %s" % (sha, EXPECTED_SHA256))

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(source)
print("restored:", OUT)
print("size:", len(source))
print("sha256:", sha)
