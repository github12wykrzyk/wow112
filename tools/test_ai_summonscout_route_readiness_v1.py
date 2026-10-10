from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
TOC = (ADDON / "SummonScout.toc").read_text(encoding="utf-8")
SRC = (ADDON / "SummonScout_RouteReadinessPresence.lua").read_text(encoding="utf-8")
PRESENCE = (ADDON / "SummonScout_FleetPresenceBootstrap.lua").read_text(encoding="utf-8")
GUARD = (ADDON / "SummonScout_LocalDestinationInviteGuard.lua").read_text(encoding="utf-8")

assert "## Version: 1.80" in TOC
assert TOC.index("SummonScout_FleetPresenceBootstrap.lua") < TOC.index("SummonScout_RouteReadinessPresence.lua")
assert TOC.index("SummonScout_RouteReadinessPresence.lua") < TOC.index("SummonScout_CrossRouteTransaction.lua")

# Route presence is fail-closed on the same two conditions as the hard invite guard.
assert "SummonScoutDB.enabled~=true" in SRC
assert "W112_SUMMONSCOUT_SLAVE_SAFETY_READY==false" in SRC
assert "W112_SUMMONSCOUT_SLAVE_SAFETY_READY == false" in GUARD

# A blocked subordinate must advertise an empty service set through existing FCV.
assert 'if not routeReady() then return "" end' in SRC
assert "syncCanonical(sender,f[2] or \"\")" in PRESENCE
assert "providers[key]=nil" in PRESENCE

# FleetCounter's own stale peer must also be dropped on explicit empty readiness.
assert "C.peers[lower(sender)]=nil" in SRC

# Master has no self-FCV, so its local provider must be removed directly when blocked.
assert "removeBlockedLocalMaster" in SRC
assert "providers[key]=nil" in SRC

# Preserve the explicit 1.79 enable across the same-cold-load slave readiness gate.
assert "gate.desiredEnabled=true" in SRC
assert "routeReadinessReconciledByCharacter" in SRC

# No route safety bypass: this bridge must not call InviteByName or tryWhisperInvite.
assert "InviteByName" not in SRC
assert "tryWhisperInvite" not in SRC

print("PASS: SummonScout route-readiness presence contract")
