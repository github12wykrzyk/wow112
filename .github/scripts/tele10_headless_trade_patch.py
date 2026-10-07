from pathlib import Path

ACCEPTOR = Path('probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs')
s = ACCEPTOR.read_text(encoding='utf-8')

marker = 'tele10_cache_named_guid(&pay_target, summoner_guid, "summon_request");'
if marker in s:
    print('TELE10_HEADLESS_TRADE_SOURCE_PATCH_OK already_stored=true')
    raise SystemExit(0)

old = '''                            let summoner_guid =
                                u64::from_le_bytes(payload[0..8].try_into().unwrap());
                            let area ='''
new = '''                            let summoner_guid =
                                u64::from_le_bytes(payload[0..8].try_into().unwrap());
                            if let Some(pay_target) = tele10_pay_target() {
                                tele10_cache_named_guid(
                                    &pay_target,
                                    summoner_guid,
                                    "summon_request",
                                );
                            }
                            let area ='''
if old not in s:
    raise SystemExit('PATCH_ANCHOR_MISSING authoritative summon-request guid')
s = s.replace(old, new, 1)
ACCEPTOR.write_text(s, encoding='utf-8')
print('TELE10_HEADLESS_TRADE_SOURCE_PATCH_OK authoritative_guid=true')
