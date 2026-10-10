#!/usr/bin/env python3
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
ADD=ROOT/'src'/'AddOns'/'SummonScout'

def read(name):
    return (ADD/name).read_text(encoding='utf-8')

def test_toc_loads_fix_after_router_and_before_burst_guard():
    toc=read('SummonScout.toc')
    assert '## Version: 1.83' in toc
    assert toc.index('SummonScout_FallbackRouterHot.lua') < toc.index('SummonScout_RouteAckHubFix.lua')
    assert toc.index('SummonScout_CrossRouteTransaction.lua') < toc.index('SummonScout_RouteAckHubFix.lua')
    assert toc.index('SummonScout_RouteAckHubFix.lua') < toc.index('SummonScout_FleetChatBurstGuard.lua')

def test_hub_origin_remote_provider_ack_is_consumed():
    s=read('SummonScout_RouteAckHubFix.lua')
    assert 'parts[1]~="A"' in s
    assert 'same(me,master) and same(origin,me)' in s
    assert 'F.pendingRoute[key]' in s
    assert 'liveProvider(F,destination,a2)' in s
    assert 'F.pendingRoute[key]=nil' in s
    assert 'sendCustomer(customer,destination,status)' in s
    assert 'return true' in s

def test_fix_does_not_bypass_transaction_or_invite_guards():
    s=read('SummonScout_RouteAckHubFix.lua')
    assert 'InviteByName' not in s
    assert 'tryWhisperInvite' not in s
    assert 'frControl' not in s
    assert 'Ritual' not in s
    assert 'payment' not in s.lower()
    assert 'PROVIDER_TTL=38.0' in s

def test_ack_requires_live_provider_and_existing_pending_route():
    s=read('SummonScout_RouteAckHubFix.lua')
    assert 'if type(pending)=="table" and liveProvider(F,destination,a2) then' in s
    assert '(now()-(tonumber(item.seen) or 0))<=PROVIDER_TTL' in s

if __name__=='__main__':
    test_toc_loads_fix_after_router_and_before_burst_guard()
    test_hub_origin_remote_provider_ack_is_consumed()
    test_fix_does_not_bypass_transaction_or_invite_guards()
    test_ack_requires_live_provider_and_existing_pending_route()
    print('SummonScout 1.83 hub-origin ACK regression contract: PASS')
