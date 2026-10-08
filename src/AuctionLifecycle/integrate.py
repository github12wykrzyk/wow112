#!/usr/bin/env python3
"""Attach Lifecycle to generated canonical sources, after all existing V4 patches.
Fail closed on source drift; never edits login implementation or BUY body.
"""
from pathlib import Path
import sys


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'canonical integration marker mismatch: {old[:90]!r}, count={text.count(old)}')
    return text.replace(old, new, 1)


def integrate(root):
    src = root / 'probes/Wow112HeadlessAndroid/src'
    changes = {}
    p = src / 'main.rs'
    changes[p] = replace(p.read_text(encoding='utf-8-sig'), 'mod auth;',
                        'mod auth;\n#[path = "../../../src/AuctionLifecycle/coordinator.rs"]\nmod auction_mutations;')
    p = src / 'world_poc07.rs'
    changes[p] = replace(p.read_text(), 'fn poc07_buy_exact_one(', 'fn poc07_buy_exact_one_canonical(') + '\ninclude!("../../../src/AuctionLifecycle/adapter.rs");\n'
    p = src / 'world.rs'
    s = replace(p.read_text(), '    Ok((header.opcode, payload))',
                '    lifecycle_observe_raw(header.opcode, &payload);\n    Ok((header.opcode, payload))')
    s = replace(s, '    let header = encrypter.encrypt_client_header(size, opcode);',
                '    crate::auction_mutations::before_send(opcode, payload)?;\n    let header = encrypter.encrypt_client_header(size, opcode);')
    changes[p] = s
    logins = [src/'world_poc07_vendorlive.rs']
    if (src/'world_poc08_unified.rs').exists():
        logins.append(src/'world_poc08_unified.rs')
    for p in logins:
        s = replace(p.read_text(encoding='utf-8-sig'), '    let player_guid = selected.guid.guid();',
                    '    let player_guid = selected.guid.guid();\n    let _mutation_session = lifecycle_bind(player_guid, u32::from(server_id))?;')
        s = replace(s, '.map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;',
                    '.map_err(|e| format!("read world opcode failed before login verify: {e:?}"))?;\n        lifecycle_observe_message(&opcode);')
        marker = ('if !login_verified { return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string()); }' if p.name == 'world_poc08_unified.rs' else 'return Err("world session did not reach SMSG_LOGIN_VERIFY_WORLD within 256 packets".to_string());\n    }')
        s = replace(s, marker, marker+'\n    if lifecycle_enabled() { return lifecycle_run(stream, &mut crypto, player_guid); }')
        changes[p] = s

    # Repost inventory evidence must fail closed without becoming permanently poisoned.
    # Real Octo sessions occasionally contain partial/malformed object updates. On such
    # a packet, discard all previously verified inventory evidence. A later POST is
    # permitted only after a subsequent successfully parsed update explicitly proves
    # owner + entry + stack again. This preserves safety while allowing MAIL -> POST
    # recovery in the same session.
    adapter = root / 'src/AuctionLifecycle/adapter.rs'
    adapter_text = adapter.read_text(encoding='utf-8')
    adapter_text = replace(
        adapter_text,
        'Err(_)=>LIFE_OBSERVED.with(|s|s.borrow_mut().inventory_bad=true),',
        'Err(_)=>LIFE_OBSERVED.with(|s|{let mut s=s.borrow_mut();s.inventory.items.clear();s.verified_items.clear();s.inventory_bad=false;}),'
    )
    changes[adapter] = adapter_text

    # Validate every anchor before any write; a second run is an explicit error.
    for p, text in changes.items():
        p.write_text(text, encoding='utf-8')
    print('LIFECYCLE CANONICAL INTEGRATION PASS; BUY/login preserved; inventory evidence resets fail-closed on malformed update')

if __name__=='__main__':
    integrate(Path(sys.argv[1] if len(sys.argv)>1 else '.').resolve())
