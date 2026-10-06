from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc05_hello_live_discovery_patch.py WORLD_POC05_RETRY_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

old = '''    if let Ok(value) = env::var("WOW112_AH_GUID") {\n        let guid = parse_guid_override("WOW112_AH_GUID", &value)?;\n        println!("[AH] using configured auctioneer guid=0x{guid:016X}");\n        auctioneers.insert(guid);\n    }\n'''
new = '''    if let Ok(value) = env::var("WOW112_AH_GUID") {\n        let guid = parse_guid_override("WOW112_AH_GUID", &value)?;\n        println!(\n            "[AH] configured auctioneer guid=0x{guid:016X} preferred_only=YES live_observation_required=YES"\n        );\n        // Never let a persisted/configured GUID satisfy discovery by itself.\n        // It becomes eligible only if the current world update stream observes it.\n    }\n'''

if s.count(old) != 1:
    raise SystemExit(f'hello live-discovery marker mismatch count={s.count(old)}')
s = s.replace(old, new, 1)

required = [
    'preferred_only=YES live_observation_required=YES',
    'let preferred = env::var("WOW112_AH_GUID")',
    '.filter(|guid| discovered.contains(guid));',
    'server did not return MSG_AUCTION_HELLO within 512 packets',
]
for marker in required:
    if marker not in s:
        raise SystemExit('missing hello guard marker: ' + marker)

if 'auctioneers.insert(guid);' in s.split('fn discover_poc05_context_retry', 1)[1].split('fn poc05_send_auction_hello_candidates', 1)[0]:
    raise SystemExit('configured AH GUID still contaminates live discovery set')

p.write_text(s, encoding='utf-8')
print('[AH-HELLO-LIVE-GUARD] PASS configured_guid=preferred_only live_observation_required=YES')
