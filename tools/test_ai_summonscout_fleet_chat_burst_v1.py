from pathlib import Path

root = Path(__file__).resolve().parents[1]
toc = (root / "src/AddOns/SummonScout/SummonScout.toc").read_text(encoding="utf-8")
guard = (root / "src/AddOns/SummonScout/SummonScout_FleetChatBurstGuard.lua").read_text(encoding="utf-8")

assert "## Version: 1.81" in toc
assert "SummonScout_FleetPresenceBootstrap.lua\nSummonScout_RouteReadinessPresence.lua\nSummonScout_CrossRouteTransaction.lua\nSummonScout_FleetChatBurstGuard.lua" in toc

assert 'local SEND_GAP=2.20' in guard
assert 'C.capability=function(target)' in guard
assert 'C.broadcast=function() return true end' in guard
assert 'F.directoryDirty=false' in guard
assert 'F.lastHelloServices=localServiceCsv()' in guard
assert 'F.nextHelloAt=now()+SUPPRESS_HELLO_FOR' in guard

# Scope guard: do not intercept or redefine transactional routing primitives.
for forbidden in [
    'InviteByName',
    'CastSpell',
    'function C.sendCtl',
    'code=="R"',
    'code=="X"',
    'code=="A"',
]:
    assert forbidden not in guard

# Lua 5.0 safety.
for forbidden in ['table.unpack', 'goto ', 'continue']:
    assert forbidden not in guard

print("SummonScout fleet chat burst contract: PASS")
