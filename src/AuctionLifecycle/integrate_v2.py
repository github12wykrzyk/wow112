#!/usr/bin/env python3
"""Second-pass Market Maker V2 integration.

V1/canonical source files stay untouched. V2 writes generated adapter/runtime copies inside
the build tree so the tracker can bind before world updates and dispatch marketmaker2 safely.
"""
from pathlib import Path
import sys


def once(text: str, old: str, new: str) -> str:
    n=text.count(old)
    if n!=1: raise ValueError(f"MM2 integration marker mismatch count={n}: {old[:100]!r}")
    return text.replace(old,new,1)


def include_safe(text: str, name: str) -> str:
    # These files are injected with include! after existing items, so crate/module-level
    # inner doc comments are illegal there. Convert comments only; runtime semantics stay unchanged.
    text='\n'.join(('//'+line[3:]) if line.startswith('//!') else line for line in text.split('\n'))
    if name=='market_maker_v2_inventory.rs':
        text=once(text,'#[derive(Clone,Copy,Debug,PartialEq,Eq)]\nstruct Mm2PhysicalSlot',
                       '#[derive(Clone,Copy,Debug,PartialEq,Eq,Hash)]\nstruct Mm2PhysicalSlot')
        old='if s.pushes.len()>128{s.pushes.drain(..s.pushes.len()-128);}'
        new='if s.pushes.len()>128{let trim=s.pushes.len()-128;s.pushes.drain(..trim);}'
        text=once(text,old,new)
    if name=='market_maker_v2_io.rs':
        # lifecycle_observe_raw is the one global observer reached by canonical and MM2 reads.
        # The generated adapter fans that hook into the MM2 tracker, so do not observe twice here.
        old='if lifecycle_enabled(){lifecycle_observe_raw(header.opcode,&payload);market_maker_observe_raw(header.opcode,&payload);}market_maker_v2_observe_raw(header.opcode,&payload);'
        new='if lifecycle_enabled(){lifecycle_observe_raw(header.opcode,&payload);market_maker_observe_raw(header.opcode,&payload);}'
        text=once(text,old,new)
    if name=='market_maker_v2_canary.rs':
        # Prompt-2 live path must use the stricter canary CANCEL whose final market authority is
        # targeted exact-item depth. Keep the generic dormant runtime primitive unchanged.
        text=once(text,'mm2_guarded_cancel(stream,crypto,targets.auctioneer,player,&choice.own,&mut saga,&mut recovery)?;',
                       'mm2_canary_guarded_cancel_fresh(stream,crypto,targets.auctioneer,player,&choice.own,&mut saga,&mut recovery)?;')
    return text


def integrate(root: Path) -> None:
    gen=root/'probes/Wow112HeadlessAndroid/src'
    life=root/'src/AuctionLifecycle'
    main=gen/'main.rs'; world7=gen/'world_poc07.rs'
    if not main.exists() or not world7.exists(): raise FileNotFoundError('generated canonical source missing')

    m=main.read_text(encoding='utf-8-sig')
    anchor='#[path = "../../../src/AuctionLifecycle/market_maker_policy.rs"]\nmod market_maker_policy;'
    m=once(m,anchor,anchor+'\n'+'\n'.join([
      '#[path = "../../../src/AuctionLifecycle/market_maker_v2_policy.rs"]','mod market_maker_v2_policy;',
      '#[path = "../../../src/AuctionLifecycle/market_maker_v2_recovery.rs"]','mod market_maker_v2_recovery;',
      '#[path = "../../../src/AuctionLifecycle/market_maker_v2_saga.rs"]','mod market_maker_v2_saga;']))

    # Generated V2 adapter: bind tracker while lifecycle_bind still knows the canonical realm id.
    # Read-only MM2 diagnostics/reconcile deliberately do not acquire the economic mutation lock,
    # so they remain available to inspect an unresolved `.pending` without gaining SEND authority.
    # Mutation modes still use the normal character-scoped coordinator binding.
    a=(life/'adapter.rs').read_text(encoding='utf-8-sig')
    old='    let server=env::var("WOW112_SERVER_ID").unwrap_or_else(|_|"octowow".into());\n    let session=mutations::bind(&server,realm,player)?;'
    new='    let server=env::var("WOW112_SERVER_ID").unwrap_or_else(|_|"octowow".into());\n    let action=env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default();\n    let mm2_mode=env::var("WOW112_MM2_MODE").unwrap_or_else(|_|"capability".into()).trim().to_ascii_lowercase();\n    let mm2_read_only=action=="marketmaker2" && matches!(mm2_mode.as_str(),"capability"|"read-only"|"readonly"|"inventory"|"inventory-tracker"|"mailbox"|"mailbox-resolver"|"auction-capability"|"ah-capability"|"depth"|"targeted-depth"|"reconcile"|"mm2-reconcile");\n    let session=if mm2_read_only{mutations::bind_read_only()}else{mutations::bind(&server,realm,player)?};'
    a=once(a,old,new)
    old='LIFE_OBSERVED.with(|s| *s.borrow_mut()=LifecycleObserved {player,..Default::default()});\n    Ok(session)'
    new='LIFE_OBSERVED.with(|s| *s.borrow_mut()=LifecycleObserved {player,..Default::default()});\n    if env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default()=="marketmaker2" { market_maker_v2_bind(player,realm); }\n    Ok(session)'
    a=once(a,old,new)
    old='fn lifecycle_observe_raw(op:u16,payload:&[u8]) {\n    if !lifecycle_enabled() {return;}'
    new='fn lifecycle_observe_raw(op:u16,payload:&[u8]) {\n    if !lifecycle_enabled() {return;}\n    if env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default()=="marketmaker2" { market_maker_v2_observe_raw(op,payload); }'
    a=once(a,old,new)
    (gen/'mm2_adapter.rs').write_text(a,encoding='utf-8')

    # Generated V2 dispatch copy: V1 implementation remains byte-for-byte untouched in repo.
    # Prompt-2 UNDERCUT is intercepted by a dedicated arm/effect gate. The runtime's historical
    # hard-block remains a second barrier for every accidental direct dispatch.
    mm=(life/'market_maker.rs').read_text(encoding='utf-8-sig')
    old='fn lifecycle_dispatch(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String>{\n    if env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default()=="marketmaker"{market_maker_run(stream,crypto,player)}else{lifecycle_run(stream,crypto,player)}\n}'
    new='fn lifecycle_dispatch(stream:&mut TcpStream,crypto:&mut HeaderCrypto,player:u64)->Result<(),String>{\n    match env::var("WOW112_LIFECYCLE_ACTION").unwrap_or_default().as_str(){\n        "marketmaker"=>market_maker_run(stream,crypto,player),\n        "marketmaker2"=>{\n            let mode=env::var("WOW112_MM2_MODE").unwrap_or_else(|_|"capability".into()).trim().to_ascii_lowercase();\n            if mode=="undercut-canary"{market_maker_v2_prompt2_undercut_canary(stream,crypto,player)}else{market_maker_v2_run(stream,crypto,player)}\n        },\n        _=>lifecycle_run(stream,crypto,player),\n    }\n}'
    mm=once(mm,old,new)
    (gen/'mm2_market_maker_v1.rs').write_text(mm,encoding='utf-8')

    runtime_names=[
      'market_maker_v2_inventory.rs','market_maker_v2_io.rs','market_maker_v2_targets.rs',
      'market_maker_v2_depth.rs','market_maker_v2_runtime.rs','market_maker_v2_canary_cancel.rs',
      'market_maker_v2_canary.rs','market_maker_v2_prompt2_guard.rs']
    for name in runtime_names:
        src=(life/name).read_text(encoding='utf-8-sig')
        (gen/name).write_text(include_safe(src,name),encoding='utf-8')

    w=world7.read_text(encoding='utf-8-sig')
    w=once(w,'include!("../../../src/AuctionLifecycle/adapter.rs");','include!("mm2_adapter.rs");')
    w=once(w,'include!("../../../src/AuctionLifecycle/market_maker.rs");','include!("mm2_market_maker_v1.rs");')
    marker='include!("mm2_market_maker_v1.rs");\n'
    tail=marker+''.join(f'include!("{name}");\n' for name in runtime_names)
    w=once(w,marker,tail)

    main.write_text(m,encoding='utf-8');world7.write_text(w,encoding='utf-8')
    print('MARKET MAKER V2 INTEGRATION PASS; canonical login/BUY/V1 source files untouched')

if __name__=='__main__': integrate(Path(sys.argv[1] if len(sys.argv)>1 else '.').resolve())
