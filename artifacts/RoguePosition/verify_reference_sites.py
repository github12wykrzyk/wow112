#!/usr/bin/env python3
"""Read-only exact-hash audit; no patch is created."""
import hashlib, pathlib, struct, sys
SHA='9a735271283a49d16ca670d6a6fc8bb12937deca07221087c608b27c2ffd42a2'
SITES=(('BEHIND',0x2e2528,0x87056c,b'SPELL_FAILED_NOT_BEHIND'),('INFRONT',0x2e253a,0x87051c,b'SPELL_FAILED_NOT_INFRONT'),('Spell.dbc',0x183720,0x859e30,b'DBFilesClient\\Spell.dbc'))
def run(path):
 b=pathlib.Path(path).read_bytes()
 assert len(b)==4907008 and hashlib.sha256(b).hexdigest()==SHA,'wrong EXE'
 assert b[:2]==b'MZ'
 pe=struct.unpack_from('<I',b,0x3c)[0]
 assert b[pe:pe+4]==b'PE\\0\\0' and struct.unpack_from('<H',b,pe+4)[0]==0x14c and struct.unpack_from('<H',b,pe+24)[0]==0x10b
 for name,off,va,needle in SITES:
  assert b[off:off+6]==b'\\xb8'+struct.pack('<I',va)+b'\\xc3',(name,'instruction mismatch')
  assert b.find(needle)==va-0x400000,(name,'string offset mismatch')
  print(name,'offset',hex(off),'VA',hex(off+0x400000),'bytes',b[off:off+6].hex(' '))
 print('PASS exact-byte reference-site audit; no positional predicate proven')
if __name__=='__main__':
 assert len(sys.argv)==2,'usage: python verify_reference_sites.py <exact client.exe>'
 run(sys.argv[1])
