-- SummonScout route-readiness bridge V2 for WoW 1.12.1 / Lua 5.0.
-- Readiness no longer hides provider presence. ProviderStatusV2 carries READY/BLOCKED
-- plus reason to the master; fallbackrouter.providers still contains READY only.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.Register)~="function" or type(H.GetState)~="function" or type(C)~="table" then return end

local VERSION="2"
local S=H.GetState("routereadinesspresence")
S.lastSig=S.lastSig or ""; S.nextAt=0
local function now() return GetTime and GetTime() or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function lower(v) return string.lower(trim(v)) end
local function me() return trim(UnitName and UnitName("player") or "") end

local function reconcileStartupGate()
    if not SummonScoutDB then return end
    local k=lower(me()); local profiles=SummonScoutDB.fleetProfileBootstrapByCharacter
    if type(profiles)~="table" or tonumber(profiles[k])~=1 then return end
    if type(SummonScoutDB.routeReadinessReconciledByCharacter)~="table" then SummonScoutDB.routeReadinessReconciledByCharacter={} end
    if SummonScoutDB.routeReadinessReconciledByCharacter[k] then return end
    local gates=SummonScoutDB.slaveSafetyGateByCharacter; local gate=type(gates)=="table" and gates[k] or nil
    if type(gate)=="table" and gate.active==true then gate.desiredEnabled=true end
    SummonScoutDB.routeReadinessReconciledByCharacter[k]=true
end

local function removeBlockedLocalMaster()
    if type(C.isMaster)~="function" or not C.isMaster() then return end
    local P=W112_SUMMONSCOUT_PROVIDER_STATUS_V2
    if type(P)~="table" or type(P.localVerdict)~="function" then return end
    local state=P.localVerdict(); if state=="READY" then return end
    local F=H.GetState("fallbackrouter"); if type(F)~="table" or type(F.providers)~="table" then return end
    local key=lower(me()); local destination,providers
    for destination,providers in pairs(F.providers) do if type(providers)=="table" then providers[key]=nil; if next(providers)==nil then F.providers[destination]=nil end end end
    F.directoryDirty=true
end

local M={}
function M.Init()
    reconcileStartupGate(); S.nextAt=0; C.nextHb=0; removeBlockedLocalMaster()
    W112_SUMMONSCOUT_ROUTE_READINESS_PRESENCE_VERSION=VERSION
end
function M.OnUpdate()
    local t=now(); if t<(S.nextAt or 0) then return end; S.nextAt=t+0.25
    reconcileStartupGate(); removeBlockedLocalMaster()
    local P=W112_SUMMONSCOUT_PROVIDER_STATUS_V2
    if type(P)=="table" and type(P.localVerdict)=="function" then
        local st,rs,mi,svc=P.localVerdict(); local sig=tostring(st).."|"..tostring(rs).."|"..tostring(mi).."|"..tostring(svc)
        if sig~=S.lastSig then S.lastSig=sig; C.nextHb=0 end
    end
end
function M.Shutdown() end
H.Register("routereadinesspresence",M,VERSION)
W112_SUMMONSCOUT_ROUTE_READINESS_PRESENCE_VERSION=VERSION
