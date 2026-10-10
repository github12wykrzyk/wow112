-- SummonScout cross-route transaction stabilizer for WoW 1.12.1 / Lua 5.0.
-- Cold-loaded intentionally: patches already-loaded canonical router/counter only.
-- Goals:
--   * use the master's FCV/FCE live service view as the non-master route directory;
--   * prevent customer-facing bot replies from recursively becoming new customer requests;
--   * keep SSFR1 control traffic and explicit bare-destination probes untouched.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.GetState)~="function" or type(C)~="table" then return end

local VERSION="1"
local ALLOWED={hydraxian=true,hyjal=true,winterspring=true,silithus=true,tanaris=true}
local BARE={hydraxian=true,hydraxis=true,hyjal=true,winterspring=true,silithus=true,tanaris=true}

local function trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+","")
    return string.gsub(s,"%s+$","")
end
local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function now() return GetTime and GetTime() or 0 end

local function fixedSummoner(name)
    local wanted=lower(name)
    if wanted=="" then return false end
    local map=W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE
    local _,master
    if type(map)=="table" then
        for _,master in pairs(map) do if lower(master)==wanted then return true end end
    end
    local F=H.GetState("fallbackrouter")
    if type(F)=="table" and type(F.peers)=="table" and F.peers[wanted] then return true end
    return false
end

local function parseServices(csv)
    local out={}; local token
    for token in string.gfind(lower(csv),"[^,]+") do
        token=lower(token)
        if ALLOWED[token] then out[token]=true end
    end
    return out
end

-- FleetCounter already receives an FCE capability from the master after every
-- accepted FCV heartbeat. Reuse field 5 (fresh live services) to keep each
-- non-master's fallback directory current instead of waiting on the older D path.
local oldCapability=C.onCapability
if type(oldCapability)=="function" and not C.__crossRouteCapabilityV1 then
    C.onCapability=function(sender,f)
        local r=oldCapability(sender,f)
        if type(C.isMaster)=="function" and not C.isMaster()
            and type(C.master)=="function" and same(sender,C.master())
            and type(f)=="table" and table.getn(f)==5 and f[1]==C.VERSION then
            local F=H.GetState("fallbackrouter")
            if type(F)=="table" then
                F.directory=parseServices(f[5] or "")
                F.remoteDirectorySeenAt=now()
            end
        end
        return r
    end
    C.__crossRouteCapabilityV1=true
end

local function isControl(raw)
    raw=tostring(raw or "")
    return string.sub(raw,1,7)=="[SSFR1]" or string.sub(raw,1,7)=="[SSWR1]" or string.sub(raw,1,5)=="[SSI "
end

local function isBareDestination(raw)
    local s=lower(raw)
    return BARE[s] and true or false
end

-- Fleet summoners are infrastructure peers, not ordinary customers. Allow a
-- bare destination word for deliberate live probing, but suppress generated
-- sentences so "unavailable"/"checking"/"inviting" replies cannot ping-pong.
local function suppressFleetSentence(raw,sender)
    if isControl(raw) or not fixedSummoner(sender) then return false end
    if isBareDestination(raw) then return false end
    return true
end

local function patchRouter()
    local module=H.modules and H.modules["fallbackrouter"] or nil
    if type(module)~="table" or type(module.OnEvent)~="function" then return false end
    if module.__crossRouteWrappedV1 then return true end
    local original=module.OnEvent
    module.OnEvent=function(ev,a1,a2,a3)
        if ev=="CHAT_MSG_WHISPER" and suppressFleetSentence(a1,a2) then return end
        return original(ev,a1,a2,a3)
    end
    module.__crossRouteWrappedV1=true
    return true
end

patchRouter()

-- Re-apply the wrapper if a hot fanout replaces fallbackrouter later in-session.
local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    local nextPatch=0
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<nextPatch then return end; nextPatch=t+1.0; patchRouter()
    end)
end

W112_SUMMONSCOUT_CROSS_ROUTE_TRANSACTION_VERSION=VERSION
