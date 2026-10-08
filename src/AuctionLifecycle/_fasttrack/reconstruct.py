from pathlib import Path
import base64,gzip,hashlib,sys
root=Path(__file__).resolve().parent
parts=['patch.p01.b64','patch.p02.b64','patch.p03.b64','patch.p04.b64','patch.p05.b64','patch.p06a.b64','patch.p06b1.b64','patch.p06b2.b64','patch.p07.b64','patch.p08.b64','patch.p09.b64','patch.p10.b64','patch.p11.b64']
b64=''.join((root/p).read_text(encoding='ascii').strip() for p in parts)
gz=base64.b64decode(b64,validate=True)+bytes.fromhex((root/'patch.p12.hex').read_text(encoding='ascii').strip())
raw=gzip.decompress(gz)
want='c135454b44a63e34383588dfefade2b8d288573ba4cd29b65854ed14ce12b0fa'
got=hashlib.sha256(raw).hexdigest()
if got!=want: raise SystemExit(f'patch sha mismatch {got} != {want}')
out=Path(sys.argv[1]);out.write_bytes(raw)
print(f'FASTTRACK_PATCH_RECONSTRUCT_PASS bytes={len(raw)} sha256={got}')
