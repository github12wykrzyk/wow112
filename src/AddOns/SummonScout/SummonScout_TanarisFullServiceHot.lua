-- Tanaris fleet/routing integration for SummonScout / WoW 1.12.1 Lua 5.0.
-- Core location parsing already contains Tanaris; this module fills fleet/runtime gaps.
local H=W112_SUMMONSCOUT_HOT
if not H or type(H.Register)~="function" or type(H.GetState)~="function" then return end
local VERSION="1-tanaris-full-service"
local S=H.GetState("tanarisfullservice")
local TANARIS="tanaris"

local function lower(v) return string.lower(tostring(v or "")) end
local function me() return lower(UnitName and UnitName("player") or "") end
local function ensureProfile()
    SummonScoutDB=SummonScoutDB or {}
    if me()=="teletanaris" then
        local service=lower(SummonScoutDB.service or "")
        if service=="" or service=="all" then SummonScoutDB.service=TANARIS end
    end
end
local function patchFallback()
    local F=H.GetState("fallbackrouter"); if type(F)~="table" then return end
    F.directory=F.directory or {}; F.providers=F.providers or {}; F.totalPoolOwners=F.totalPoolOwners or {}
    F.directory[TANARIS]=true
    if type(F.totalPoolOwners[TANARIS])~="table" then F.totalPoolOwners[TANARIS]={} end
    local providers=F.providers[TANARIS]
    if type(providers)=="table" then
        local k,p
        for k,p in pairs(providers) do
            if type(p)=="table" and tostring(p.name or "")~="" then
                F.totalPoolOwners[TANARIS][lower(k)]=tostring(p.name)
                p.totalPoolSticky=true
            end
        end
    end
    W112_SUMMONSCOUT_TOTAL_POOL_CSV="silithus,winterspring,hydraxian,hyjal,tanaris"
end
local function patchFleet()
    local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1; if type(C)~="table" then return end
    C.EXPECTED={"hydraxian","hyjal","winterspring","silithus","tanaris"}
    C.LABEL=C.LABEL or {}; C.LABEL.tanaris="TANARIS"
    C.ALLOWED=C.ALLOWED or {}; C.ALLOWED.tanaris=true
    if S.fleetRolloutPatched then return end
    C.rollout=function()
        if not C.isMaster() then return end
        if tonumber(SummonScoutDB.fleetCounterRolloutVersion)~=2 then
            SummonScoutDB.fleetCounterRolloutVersion=2; SummonScoutDB.fleetCounterRolloutReady=false
        end
        local required=table.getn(C.EXPECTED)
        if not SummonScoutDB.fleetCounterRolloutReady and C.coverage(C.freshServices())>=required and C.owners()>=required then
            SummonScoutDB.fleetCounterRolloutReady=true
            if type(C.chat)=="function" then C.chat("rollout READY "..tostring(required).."/"..tostring(required).." services + owners") end
        end
    end
    S.fleetRolloutPatched=true
end
local M={}
function M.Init() ensureProfile(); patchFallback(); patchFleet(); W112_SUMMONSCOUT_TANARIS_FULL_SERVICE_VERSION=VERSION end
function M.OnUpdate() ensureProfile(); patchFallback(); patchFleet() end
function M.Shutdown() end
H.Register("tanarisfullservice",M,VERSION)
W112_SUMMONSCOUT_TANARIS_FULL_SERVICE_VERSION=VERSION
