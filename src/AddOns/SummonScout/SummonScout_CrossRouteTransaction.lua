-- SummonScout CrossRouteTransaction V2 for WoW 1.12.1 / Lua 5.0.
-- One wrapper around canonical fallbackrouter: provider-bound ACK dispatch,
-- live directory reuse, fleet-bot sentence suppression, and blocked-route reason UI.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.GetState)~="function" or type(C)~="table" then return end
local VERSION="2"
local ALLOWED={hydraxian=true,hydraxis=true,hyjal=true,winterspring=true,silithus=true,tanaris=true}
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function now() return GetTime and GetTime() or 0 end
local function fixedSummoner(name)
    local wanted=lower(name); if wanted=="" then return false end
    local map=W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE; local _,master
    if type(map)=="table" then for _,master in pairs(map) do if lower(master)==wanted then return true end end end
    return false
end
local function parseServices(csv)
    local out={}; local token
    for token in string.gfind(lower(csv),"[^,]+") do token=lower(token); if token=="hydraxis" then token="hydraxian" end; if ALLOWED[token] then out[token]=true end end
    return out
end

-- Non-master nodes consume the master's current READY-service capability.
local oldCapability=C.onCapability
if type(oldCapability)=="function" and not C.__crossRouteCapabilityV2 then
    C.onCapability=function(sender,f)
        local r=oldCapability(sender,f)
        if type(C.isMaster)=="function" and not C.isMaster() and type(C.master)=="function" and same(sender,C.master())
            and type(f)=="table" and table.getn(f)==5 and f[1]==C.VERSION then
            local F=H.GetState("fallbackrouter"); if type(F)=="table" then F.directory=parseServices(f[5] or ""); F.remoteDirectorySeenAt=now() end
        end
        return r
    end
    C.__crossRouteCapabilityV2=true
end

local function isControl(raw)
    raw=tostring(raw or ""); return string.sub(raw,1,7)=="[SSFR1]" or string.sub(raw,1,7)=="[SSWR1]" or string.sub(raw,1,5)=="[SSI "
end
local function bareDestination(raw)
    local s=lower(raw); if s=="hydraxis" then s="hydraxian" end; if ALLOWED[s] then return s end; return nil
end
local function suppressFleetSentence(raw,sender)
    if isControl(raw) or not fixedSummoner(sender) then return false end
    if bareDestination(raw) then return false end
    return true
end
local function inspectRouteState(raw,sender)
    if fixedSummoner(sender) then return end
    if type(C.isMaster)~="function" or not C.isMaster() then return end
    local dest=bareDestination(raw)
    if not dest then
        local api=W112_SUMMONSCOUT_API_V1
        if type(api)=="table" and type(api.whisperInviteDecision)=="function" then
            local accept,loc,reason=api.whisperInviteDecision(raw or "")
            if not accept and loc and loc.id and (reason=="other-location" or reason=="ambiguous-location") then dest=lower(loc.id) end
        end
    end
    local P=W112_SUMMONSCOUT_PROVIDER_STATUS_V2
    if dest and type(P)=="table" and type(P.noteBlockedRequest)=="function" then P.noteBlockedRequest(dest,sender) end
end

local function patchRouter()
    local module=H.modules and H.modules["fallbackrouter"] or nil
    if type(module)~="table" or type(module.OnEvent)~="function" then return false end
    if module.__crossRouteWrappedV2 then return true end
    local original=module.OnEvent
    module.OnEvent=function(ev,a1,a2,a3)
        if ev=="CHAT_MSG_WHISPER" then
            local raw=tostring(a1 or ""); local sender=trim(a2 or "")
            if string.sub(raw,1,7)=="[SSFR1]" then
                local A=W112_SUMMONSCOUT_ACK_CORE_V2
                if type(A)=="table" and type(A.HandleRaw)=="function" then
                    local handled=false
                    if pcall then local ok,v=pcall(A.HandleRaw,raw,sender); handled=ok and v and true or false else handled=A.HandleRaw(raw,sender) and true or false end
                    if handled then return true end
                end
            end
            if suppressFleetSentence(raw,sender) then return end
            if not isControl(raw) then inspectRouteState(raw,sender) end
        end
        return original(ev,a1,a2,a3)
    end
    module.__crossRouteWrappedV2=true; module.__crossRouteBaseV2=original
    return true
end
patchRouter()
local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then local nextPatch=0; frame:SetScript("OnUpdate",function() local t=now(); if t<nextPatch then return end; nextPatch=t+0.5; patchRouter() end) end
W112_SUMMONSCOUT_CROSS_ROUTE_TRANSACTION_VERSION=VERSION
