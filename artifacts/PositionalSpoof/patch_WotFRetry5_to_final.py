from pathlib import Path
import hashlib, sys

EXPECTED_IN = '767130d6f02ea26664d116fad34c6b1c0ea52b53bbbef821e4e35b93be0c93f5'
EXPECTED_OUT = 'deab16a21ab201e8edc4d8a245a739a6b879e57f7c11efe922451ee0eea9823b'
PATCHES = [
    (0x0B7F, bytes.fromhex('e89c080000'), bytes.fromhex('9090909090')),
    (0x3F2B, bytes.fromhex('e8f0d4ffff'), bytes.fromhex('9090909090')),
    (0x4E81, bytes.fromhex('e89ac5ffff'), bytes.fromhex('9090909090')),
    (0x59D9, bytes.fromhex('c7042400706e00'), bytes.fromhex('e9610000009090')),
]

def sha(b): return hashlib.sha256(b).hexdigest()

def main():
    if len(sys.argv) != 3:
        print('usage: patch_WotFRetry5_to_final.py <WotFRetry5.dll> <final.dll>')
        return 2
    src, dst = map(Path, sys.argv[1:])
    b = bytearray(src.read_bytes())
    if sha(b) != EXPECTED_IN:
        raise SystemExit('input SHA256 mismatch: ' + sha(b))
    for off, old, new in PATCHES:
        if bytes(b[off:off+len(old)]) != old:
            raise SystemExit('byte signature mismatch at 0x%X' % off)
        b[off:off+len(new)] = new
    if sha(b) != EXPECTED_OUT:
        raise SystemExit('output SHA256 mismatch: ' + sha(b))
    dst.write_bytes(b)
    print('OK', dst, EXPECTED_OUT)
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
