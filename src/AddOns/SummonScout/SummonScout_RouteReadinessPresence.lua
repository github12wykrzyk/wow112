-- SummonScout route-readiness presence bridge for WoW 1.12.1 / Lua 5.0.
-- Presence means "can accept a routed invite now", not merely "client online".
-- Reuses the existing FCV/FCE control traffic; no new network messages.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.Register)~="function" or type(H.GetState)~="function"
    or type(C)~="table" or type(C.localServices)~="function" then return end

local VERSION="1"
local S=H.GetState("routereadinesspresence")
local OLD_LOCAL=C.localServices
local OLD_HEARTBEAT=C.onHeartbeat
local TOKEN={}
S.ownerToken=TOKEN
S.lastReady=nil
S.nextAt=0

local function trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+","")
    return string.gsub(s,"%s+$","")
end
local function lower(v) return string.lower(trim(v)) end
local function me() return trim(UnitName and UnitName("player") or "") end
local function routeReady()
    if not SummonScoutDB or SummonScoutDB.enabled~=true then return false end
    if W112_SUMMONSCOUT_SLAVE_SAFETY_READY==false then return false end
    return true
end

-- Profile 1.79 explicitly enabled the canonical summoner. SlaveMasterPair loads
-- first, so its safety gate may already be active during the same cold load.
-- Preserve that later explicit enable as the value to restore when slaves are ready.
local function reconcileStartupGate()
    if not SummonScoutDB then return end
    local k=lower(me())
    local profiles=SummonScoutDB.fleetProfileBootstrapByCharacter
    if type(profiles)~="table" or tonumber(profiles[k])~=1 then return end
    if type(SummonScoutDB.routeReadinessReconciledByCharacter)~="table" then
        SummonScoutDB.routeReadinessReconciledByCharacter={}
    end
    if SummonScoutDB.routeReadinessReconciledByCharacter[k] then return end
    local gates=SummonScoutDB.slaveSafetyGateByCharacter
    local gate=type(gates)=="table" and gates[k] or nil
    if type(gate)=="table" and gate.active==true then gate.desiredEnabled=true end
    SummonScoutDB.routeReadinessReconciledByCharacter[k]=true
end

-- A blocked subordinate sends an empty service set. FleetPresenceBootstrap's
-- existing FCV wrapper consumes that and removes the sender from canonical
-- fallbackrouter.providers immediately.
C.localServices=function()
    if not routeReady() then return "" end
    return OLD_LOCAL()
end

-- FleetCounter itself historically ignores empty-service heartbeats. Remove the
-- peer there too so ACTIVE/coverage does not claim a route that cannot invite.
if type(OLD_HEARTBEAT)=="function" then
    C.onHeartbeat=function(sender,f)
        local result=OLD_HEARTBEAT(sender,f)
        if type(C.isMaster)=="function" and C.isMaster()
            and type(f)=="table" and table.getn(f)==3 and f[1]==C.VERSION
            and type(C.trusted)=="function" and C.trusted(sender)
            and type(C.services)=="function" and C.services(f[2] or "")=="" then
            if type(C.peers)=="table" then C.peers[lower(sender)]=nil end
            if type(C.broadcast)=="function" then C.broadcast() end
        end
        return result
    end
end

-- The master does not send FCV to itself. Remove its local canonical provider
-- directly while its own slave-safety/addon gate is blocked. FallbackRouter will
-- re-register it on normal maintenance once readiness returns.
local function removeBlockedLocalMaster()
    if type(C.isMaster)~="function" or not C.isMaster() or routeReady() then return end
    local F=H.GetState("fallbackrouter")
    if type(F)~="table" or type(F.providers)~="table" then return end
    local key=lower(me()); local destination,providers
    for destination,providers in pairs(F.providers) do
        if type(providers)=="table" then
            providers[key]=nil
            if next(providers)==nil then F.providers[destination]=nil end
        end
    end
    F.directoryDirty=true
end

local M={}
function M.Init()
    reconcileStartupGate()
    S.lastReady=routeReady()
    S.nextAt=0
    C.nextHb=0
    removeBlockedLocalMaster()
    W112_SUMMONSCOUT_ROUTE_READINESS_PRESENCE_VERSION=VERSION
end
function M.OnUpdate()
    local t=GetTime and GetTime() or 0
    if t<(S.nextAt or 0) then return end
    S.nextAt=t+0.5
    reconcileStartupGate()
    local ready=routeReady()
    if ready~=S.lastReady then
        S.lastReady=ready
        -- Force the next existing heartbeat immediately on readiness changes.
        C.nextHb=0
    end
    removeBlockedLocalMaster()
end
function M.Shutdown()
    if S.ownerToken~=TOKEN then return end
    if C.localServices~=OLD_LOCAL then C.localServices=OLD_LOCAL end
    if type(OLD_HEARTBEAT)=="function" and C.onHeartbeat~=OLD_HEARTBEAT then C.onHeartbeat=OLD_HEARTBEAT end
end

H.Register("routereadinesspresence",M,VERSION)
W112_SUMMONSCOUT_ROUTE_READINESS_PRESENCE_VERSION=VERSION
