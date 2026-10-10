-- SummonScout Core V3 shadow OwnershipService.
-- Stage 5: canonical read-only projection of fixed master/slave ownership and readiness.
-- No invites, accepts, promotions or legacy state writes.

local VERSION = "p1-shadow-ownership"
local SWEEP = 0.50
local O = W112_SUMMON_CORE_V3_OWNERSHIP_SHADOW
if type(O) ~= "table" then O = {}; W112_SUMMON_CORE_V3_OWNERSHIP_SHADOW = O end
O.version = VERSION
O.nextSweepAt = tonumber(O.nextSweepAt) or 0
O.state = type(O.state) == "table" and O.state or {}
O.parity = type(O.parity) == "table" and O.parity or {matches=0,mismatches=0,unknown=0}

local function now() return GetTime and (tonumber(GetTime()) or 0) or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function key(v) return string.lower(trim(v)) end
local function me() return trim(UnitName and UnitName("player") or "") end

local function pairMaps()
    local raw=W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE
    local slaveToMaster={}; local masterToSlaves={}
    if type(raw)~="table" then return slaveToMaster,masterToSlaves end
    local slave,master,mk
    for slave,master in pairs(raw) do
        slaveToMaster[key(slave)]=trim(master)
        mk=key(master)
        if mk~="" then
            if type(masterToSlaves[mk])~="table" then masterToSlaves[mk]={} end
            masterToSlaves[mk][table.getn(masterToSlaves[mk])+1]=trim(slave)
        end
    end
    local _,list
    for _,list in pairs(masterToSlaves) do table.sort(list) end
    return slaveToMaster,masterToSlaves
end

local function groupSet()
    local set={}; local i,name
    if UnitName then
        set[key(me())]=true
        for i=1,(GetNumPartyMembers and GetNumPartyMembers() or 0) do
            name=UnitName("party"..i); if trim(name or "")~="" then set[key(name)]=true end
        end
        for i=1,(GetNumRaidMembers and GetNumRaidMembers() or 0) do
            name=GetRaidRosterInfo and GetRaidRosterInfo(i) or UnitName("raid"..i)
            if trim(name or "")~="" then set[key(name)]=true end
        end
    end
    return set
end

local function project()
    local player=me(); local pk=key(player)
    local slaveToMaster,masterToSlaves=pairMaps()
    local group=groupSet()
    local nextState={player=player,playerKey=pk,role="INACTIVE",owner="",ready=true,present=0,total=0,missing={},reason=""}

    local owner=slaveToMaster[pk]
    if owner then
        nextState.role="SLAVE"; nextState.owner=owner; nextState.ready=true; nextState.reason="owned-slave"
    elseif type(masterToSlaves[pk])=="table" then
        nextState.role="MASTER"
        local list=masterToSlaves[pk]; nextState.total=table.getn(list)
        local i,slave
        for i=1,table.getn(list) do
            slave=list[i]
            if group[key(slave)] then nextState.present=nextState.present+1
            else nextState.missing[table.getn(nextState.missing)+1]=slave end
        end
        nextState.ready=nextState.total>0 and nextState.present==nextState.total
        if not nextState.ready then nextState.reason="missing-slaves" end
    end

    local legacy=W112_SUMMONSCOUT_SLAVE_SAFETY_READY
    if nextState.role=="MASTER" and type(legacy)=="boolean" then
        nextState.legacyReady=legacy
        if legacy==nextState.ready then O.parity.matches=(tonumber(O.parity.matches) or 0)+1
        else O.parity.mismatches=(tonumber(O.parity.mismatches) or 0)+1 end
    else
        O.parity.unknown=(tonumber(O.parity.unknown) or 0)+1
    end
    O.parity.updatedAt=now()
    O.state=nextState
end

local function trustedInviter(inviter)
    local pk=key(me()); local ik=key(inviter)
    if pk=="" or ik=="" then return false,"" end
    local slaveToMaster,masterToSlaves=pairMaps()
    local owner=slaveToMaster[pk]
    if owner and key(owner)==ik then return true,"MASTER" end
    local slaves=masterToSlaves[pk]
    if type(slaves)=="table" then
        local i
        for i=1,table.getn(slaves) do if key(slaves[i])==ik then return true,"SLAVE" end end
    end
    return false,""
end

local frame=CreateFrame and CreateFrame("Frame","SummonScoutCoreV3ShadowOwnershipFrame") or nil
if frame then
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<(O.nextSweepAt or 0) then return end
        O.nextSweepAt=t+SWEEP; project()
    end)
end

W112_SUMMON_CORE_V3_OWNERSHIP_SHADOW_API={
    version=VERSION,
    GetState=function() return O.state end,
    IsReady=function() return O.state and O.state.ready==true end,
    TrustedInviter=trustedInviter,
    Refresh=project
}
