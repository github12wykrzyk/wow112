#!/usr/bin/env python3
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
ADD=ROOT/'src'/'AddOns'/'SummonScout'

def read(name):
    return (ADD/name).read_text(encoding='utf-8')

def test_toc_version_and_order():
    toc=read('SummonScout.toc')
    assert '## Version: 1.82' in toc
    assert toc.index('SummonScout_FleetPresenceBootstrap.lua') < toc.index('SummonScout_FleetChatBurstGuard.lua')
    assert toc.index('SummonScout_FleetChatBurstGuard.lua') < toc.index('SummonScout_FleetAdvertCoordinator.lua')
    assert toc.index('SummonScout_LocalDestinationInviteGuard.lua') > toc.index('SummonScout_FallbackRouterHot.lua')

def test_control_cadence_is_not_per_fcv_stream():
    s=read('SummonScout_FleetChatBurstGuard.lua')
    assert 'local SEND_GAP=4.50' in s
    assert 'local KEEPALIVE=28.0' in s
    assert 'C.capability=function(target)' in s
    assert 'G.lastSent[key]==nil' in s
    assert 'age>=KEEPALIVE' in s
    assert 'C.broadcast=function()' in s
    assert 'G.globalHash=""' in s
    assert 'queueStateChange()' in s and 'queueKeepalives()' in s
    assert 'baseCapability(best.name)' in s
    assert 'F.nextHelloAt=now()+SUPPRESS_HELLO_FOR' in s
    assert 'F.nextDirectoryPushAt=now()+SUPPRESS_HELLO_FOR' in s

def test_route_reason_diagnostics_preserve_hard_guards():
    s=read('SummonScout_LocalDestinationInviteGuard.lua')
    assert 'slave-safety-blocked' in s
    assert 'wrong-service-hard-guard' in s
    assert '[SSI ROUTEFAIL]' in s
    assert 'W112_SUMMONSCOUT_ROUTE_LAST_FAILURE' in s
    assert 'local ok,reason=base(name, loc)' in s
    assert 'reason~="duplicate-event"' in s
    assert 'return false, "slave-safety-blocked"' in s
    assert 'return false, "wrong-service-hard-guard"' in s

def test_no_new_transaction_bypass():
    burst=read('SummonScout_FleetChatBurstGuard.lua')
    guard=read('SummonScout_LocalDestinationInviteGuard.lua')
    assert 'InviteByName' not in burst
    assert 'InviteByName' not in guard
    assert '"R"' not in burst and '"X"' not in burst and '"A"' not in burst
    assert 'W112_SUMMONSCOUT_SLAVE_SAFETY_READY == false' in guard

if __name__=='__main__':
    test_toc_version_and_order()
    test_control_cadence_is_not_per_fcv_stream()
    test_route_reason_diagnostics_preserve_hard_guards()
    test_no_new_transaction_bypass()
    print('SummonScout 1.82 Claude-reviewed regression contract: PASS')
