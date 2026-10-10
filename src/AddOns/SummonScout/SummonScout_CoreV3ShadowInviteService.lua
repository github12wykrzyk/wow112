-- SummonScout Core V3 shadow InviteService.
-- Stage 5: evaluate invite eligibility and compare with observed legacy invites.
-- This module never executes InviteByName and never mutates legacy queues/state.

SummonScoutDB = SummonScoutDB or {}

local VERSION="p1-shadow-invite-service"
local SWEEP=0.20
local MAX_OBS=256
local I=W112_SUMMON_CORE_V3_INVITE_SHADOW
if type(I)~="table" then I={}; W112_SUMMON_CORE_V3_INVITE_SHADOW=I end
I.version=VERSION
I.nextSweepAt=tonumber(I.nextSweepAt) or 0
I.lastInviteName=tostring(I.lastInviteName or "")
I.lastInviteAt=tonumber(I.lastInviteAt) or 0
I.observations=type(I.observations)=="table" and I.observations or {}
I.parity=type(I.parity)=="table" and I.parity or {matches=0,mismatches=0,unknown=0}

local function now() return GetTime and (tonumber(GetTime()) or 0) or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function key(v) return string.lower(trim(v)) end
local function me() return trim(UnitName and UnitName("player") or "") end
local function same(a,b) a=key(a); b=key(b); return a~="" and a==b end

local function appendBounded(list,item,maxCount)
    list[table.getn(list)+1]=item
    while table.getn(list)>maxCount do table.remove(list,1) end
end

local function inGroup(name)
    local wanted=key(name); if wanted=="" then return false end
    local i,n
    for i=1,(GetNumPartyMembers and GetNumPartyMembers() or 0) do
        n=UnitName and UnitName("party"..i) or nil; if key(n)==wanted then return true end
    end
    for i=1,(GetNumRaidMembers and GetNumRaidMembers() or 0) do
        n=GetRaidRosterInfo and GetRaidRosterInfo(i) or (UnitName and UnitName("raid"..i) or nil)
        if key(n)==wanted then return true end
    end
    return false
end

local function serviceSet()
    local set={}; local raw=key(SummonScoutDB and SummonScoutDB.service or "")
    if raw=="" or raw=="all" then return set,true end
    local token
    for token in string.gfind(raw,"[^,]+") do token=key(token); if token~="" then set[token]=true end end
    return set,false
end

local function localDestinationFallback()
    local set,all=serviceSet(); if all then return nil end
    local count=0; local found=nil; local id
    for id in pairs(set) do count=count+1; found=id end
    if count==1 then return found end
    return nil
end

local function resolveDestination(name)
    local api=W112_SUMMON_CORE_V3_SHADOW_API
    if type(api)=="table" and type(api.FindNewestOpenForCustomer)=="function" then
        local ok,tx=true,nil
        if pcall then ok,tx=pcall(api.FindNewestOpenForCustomer,name) else tx=api.FindNewestOpenForCustomer(name) end
        if ok and type(tx)=="table" then
            local id=key(tx.destinationId or "")
            if id~="" and id~="unknown" and id~="ambiguous_dm" then return id,"transaction" end
        end
    end
    local fallback=localDestinationFallback()
    if fallback then return fallback,"single-service" end
    return nil,"unknown"
end

local function blacklisted(name)
    local list=SummonScoutDB and SummonScoutDB.inviteBlacklist
    return type(list)=="table" and list[key(name)]~=nil
end

-- skipGrouped is used only when comparing against an invite that legacy already executed.
-- Current group membership is post-action evidence and cannot safely reconstruct the pre-invite gate.
local function evaluate(name,destination,skipGrouped)
    name=trim(name); destination=key(destination)
    if name=="" or same(name,me()) then return "BLOCK","invalid-player" end
    if blacklisted(name) then return "BLOCK","blacklisted" end
    if not skipGrouped and inGroup(name) then return "BLOCK","already-grouped" end
    if not SummonScoutDB or SummonScoutDB.enabled~=true then return "BLOCK","addon-disabled" end

    local own=W112_SUMMON_CORE_V3_OWNERSHIP_SHADOW_API
    if type(own)~="table" or type(own.GetState)~="function" then return "UNKNOWN","ownership-unavailable" end
    local state=own.GetState()
    if type(state)~="table" then return "UNKNOWN","ownership-unavailable" end
    if state.role=="SLAVE" then return "BLOCK","slave-cannot-serve-customer" end
    if state.role=="MASTER" and state.ready~=true then return "BLOCK","ownership-not-ready" end
    if state.role~="MASTER" then return "UNKNOWN","ownership-profile-unknown" end

    if destination=="" then return "UNKNOWN","destination-unknown" end
    local services,all=serviceSet()
    if not all and not services[destination] then return "BLOCK","wrong-service" end

    return "ALLOW","eligible"
end

local function observeLegacyInvite(core)
    if type(core)~="table" then return end
    local name=trim(core.lastInvitedName or ""); local at=tonumber(core.lastInvitedAt) or 0
    if name=="" or at<=0 then return end
    if name==I.lastInviteName and at==I.lastInviteAt then return end
    I.lastInviteName=name; I.lastInviteAt=at

    local destination,source=resolveDestination(name)
    local decision,reason=evaluate(name,destination or "",true)
    local parity
    if decision=="ALLOW" then I.parity.matches=(tonumber(I.parity.matches) or 0)+1; parity="MATCH"
    elseif decision=="BLOCK" then I.parity.mismatches=(tonumber(I.parity.mismatches) or 0)+1; parity="MISMATCH"
    else I.parity.unknown=(tonumber(I.parity.unknown) or 0)+1; parity="UNKNOWN" end
    I.parity.updatedAt=now()
    appendBounded(I.observations,{
        at=at,observedAt=now(),player=name,destination=destination or "",
        destinationSource=source,decision=decision,reason=reason,parity=parity
    },MAX_OBS)
end

local frame=CreateFrame and CreateFrame("Frame","SummonScoutCoreV3ShadowInviteFrame") or nil
if frame then
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<(I.nextSweepAt or 0) then return end
        I.nextSweepAt=t+SWEEP
        observeLegacyInvite(W112_SUMMONSCOUT_STATE)
    end)
end

W112_SUMMON_CORE_V3_INVITE_SHADOW_API={
    version=VERSION,
    GetState=function() return I end,
    Evaluate=evaluate,
    ResolveDestination=resolveDestination
}
