-- SummonScout fleet presence V2 for WoW 1.12.1 / Lua 5.0.
-- FCV is the single provider heartbeat. Online BLOCKED providers remain visible
-- to ProviderStatus, but only READY providers enter fallbackrouter.providers.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.GetState)~="function" or type(C)~="table" or type(C.onHeartbeat)~="function" then return end

local VERSION="2"
local OLD_TRUSTED=C.trusted
local OLD_HEARTBEAT=C.onHeartbeat

local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function lower(v) return string.lower(trim(v)) end
local function fixedSummoner(name)
    local wanted=lower(name); local map=W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE; local _,master
    if wanted=="" or type(map)~="table" then return false end
    for _,master in pairs(map) do if lower(master)==wanted then return true end end
    return false
end
local function allowedService(id)
    id=lower(id); return id=="hydraxian" or id=="hyjal" or id=="winterspring" or id=="silithus" or id=="tanaris"
end
local function normalizeState(v) v=string.upper(trim(v)); if v~="READY" and v~="BLOCKED" then return "READY" end; return v end

local function syncCanonical(sender,csv,state,reason,missing)
    if type(C.isMaster)~="function" or not C.isMaster() or not fixedSummoner(sender) then return end
    local F=H.GetState("fallbackrouter"); if type(F)~="table" then return end
    F.providers=type(F.providers)=="table" and F.providers or {}; F.peers=type(F.peers)=="table" and F.peers or {}
    local key=lower(sender); local destination,providers,token,count= nil,nil,nil,0
    for destination,providers in pairs(F.providers) do
        if type(providers)=="table" then providers[key]=nil; if next(providers)==nil then F.providers[destination]=nil end end
    end
    state=normalizeState(state)
    for token in string.gfind(lower(csv),"[^,]+") do
        token=lower(token)
        if allowedService(token) then
            count=count+1
            if state=="READY" then
                if type(F.providers[token])~="table" then F.providers[token]={} end
                F.providers[token][key]={name=trim(sender),seen=C.now(),lastAssigned=0,routeState=state}
            end
        end
    end
    if count>0 then
        F.peers[key]={name=trim(sender),seen=C.now(),services=lower(csv),routeState=state,routeReason=lower(reason),routeMissing=trim(missing)}
    else F.peers[key]=nil end
    F.directoryDirty=true
    local P=W112_SUMMONSCOUT_PROVIDER_STATUS_V2
    if type(P)=="table" and type(P.observe)=="function" then P.observe(sender,csv,state,reason,missing,C.now()) end
end

C.trusted=function(name)
    if fixedSummoner(name) then return true end
    if type(OLD_TRUSTED)=="function" then return OLD_TRUSTED(name) end
    return false
end

C.onHeartbeat=function(sender,f)
    if type(f)~="table" then return end
    local n=table.getn(f)
    if (n==3 or n>=6) and f[1]==C.VERSION and fixedSummoner(sender) then
        local state=n>=6 and (f[4] or "READY") or "READY"
        local reason=n>=6 and (f[5] or "") or ""
        local missing=n>=6 and (f[6] or "") or ""
        syncCanonical(sender,f[2] or "",state,reason,missing)
        -- Legacy FleetCounter core still expects exactly three fields. Feed it a
        -- normalized compatibility view so online blocked peers remain in roster.
        return OLD_HEARTBEAT(sender,{f[1],f[2] or "",f[3] or "0"})
    end
    return OLD_HEARTBEAT(sender,f)
end

W112_SUMMONSCOUT_FLEET_PRESENCE_BOOTSTRAP_VERSION=VERSION
