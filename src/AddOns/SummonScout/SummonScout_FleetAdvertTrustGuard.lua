-- Trust guard for FleetAdvertCoordinator.
-- Only peers already known by the canonical FallbackRouter directory may register as advert providers.
-- This prevents arbitrary players from spoofing FAH control whispers and becoming selected speakers.

local A=W112_SUMMONSCOUT_FLEET_ADVERT
if type(A)~="table" or type(A.onHeartbeat)~="function" then return end

local original=A.onHeartbeat

local function fallbackState()
    local h=W112_SUMMONSCOUT_HOT
    if not h or type(h.GetState)~="function" then return nil end
    if pcall then
        local ok,s=pcall(h.GetState,"fallbackrouter")
        if ok and type(s)=="table" then return s end
        return nil
    end
    local s=h.GetState("fallbackrouter")
    if type(s)=="table" then return s end
    return nil
end

local function trusted(name)
    if A.same(name,A.me()) or A.same(name,A.master()) then return true end
    local key=A.lower(name)
    if key=="" then return false end
    local f=fallbackState(); local destination,providers
    if not f then return false end
    if type(f.peers)=="table" and f.peers[key] then return true end
    if type(f.providers)=="table" then
        for destination,providers in pairs(f.providers) do
            if type(providers)=="table" and providers[key] then return true end
        end
    end
    return false
end

A.trustedPeer=trusted
A.onHeartbeat=function(sender,fields)
    if not trusted(sender) then
        A.metrics.suppressed=(tonumber(A.metrics.suppressed) or 0)+1
        A.debug("ignored untrusted FAH from "..tostring(sender or "?"))
        return
    end
    return original(sender,fields)
end

W112_SUMMONSCOUT_FLEET_ADVERT_TRUST_GUARD_VERSION="1"
