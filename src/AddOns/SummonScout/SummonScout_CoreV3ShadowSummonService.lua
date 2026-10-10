-- SummonScout Core V3 shadow SummonService evidence observer.
-- Publishes summon lifecycle evidence only. It never casts, retries or changes legacy state.

local VERSION="p1-shadow-summon-evidence"
local SWEEP=0.10
local MAX_EVENTS=256
local S=W112_SUMMON_CORE_V3_SUMMON_SHADOW
if type(S)~="table" then S={}; W112_SUMMON_CORE_V3_SUMMON_SHADOW=S end
S.version=VERSION
S.seq=tonumber(S.seq) or 0
S.events=type(S.events)=="table" and S.events or {}
S.nextSweepAt=tonumber(S.nextSweepAt) or 0
S.lastName=tostring(S.lastName or "")
S.lastRequestSeq=tostring(S.lastRequestSeq or "")
S.lastStarted=S.lastStarted and true or false
S.lastNativeStatus=tostring(S.lastNativeStatus or "")

local function now() return GetTime and (tonumber(GetTime()) or 0) or 0 end
local function wall() return time and (tonumber(time()) or 0) or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end

local function appendBounded(list,item,maxCount)
    list[table.getn(list)+1]=item
    while table.getn(list)>maxCount do table.remove(list,1) end
end

local function emit(kind,name,requestSeq,detail)
    S.seq=(tonumber(S.seq) or 0)+1
    appendBounded(S.events,{
        seq=S.seq,ts=wall(),mono=now(),kind=tostring(kind or "OBS"),
        customer=trim(name),requestSeq=trim(requestSeq),detail=tostring(detail or "")
    },MAX_EVENTS)
end

local function observe()
    local core=W112_SUMMONSCOUT_STATE
    if type(core)~="table" then return end
    local name=trim(core.summonActiveName or "")
    local requestSeq=trim(tostring(core.summonActiveRequestSeq or ""))
    local started=core.summonActiveStarted and true or false
    local nativeStatus=trim(tostring(W112_AUTOSUMMON_NATIVE_STATUS or ""))

    if name~="" and name~=S.lastName then
        emit("SUMMON_ACTIVE",name,requestSeq,"legacy-active")
    end
    if name~="" and requestSeq~="" and requestSeq~=S.lastRequestSeq then
        emit("CAST_REQUESTED",name,requestSeq,"native-bridge-request")
    end
    if name~="" and started and (name~=S.lastName or not S.lastStarted) then
        emit("CAST_STARTED",name,requestSeq,nativeStatus~="" and nativeStatus or "legacy-started")
    end
    if name~="" and nativeStatus~="" and nativeStatus~=S.lastNativeStatus then
        emit("NATIVE_STATUS",name,requestSeq,nativeStatus)
    end
    if S.lastName~="" and name=="" then
        -- Slot clearing is intentionally weak evidence. TransactionStore must not
        -- translate this event into SUMMON_COMPLETED without a stronger signal.
        emit("SUMMON_SLOT_CLEARED",S.lastName,S.lastRequestSeq,S.lastStarted and "after-start" or "without-start")
    end

    S.lastName=name
    S.lastRequestSeq=requestSeq
    S.lastStarted=started
    S.lastNativeStatus=nativeStatus
end

local function getSince(seq)
    local out={}; seq=tonumber(seq) or 0
    local i,e
    for i=1,table.getn(S.events) do
        e=S.events[i]
        if type(e)=="table" and (tonumber(e.seq) or 0)>seq then out[table.getn(out)+1]=e end
    end
    return out
end

local frame=CreateFrame and CreateFrame("Frame","SummonScoutCoreV3ShadowSummonEvidenceFrame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent",function()
        if event~="PLAYER_LOGIN" then return end
        local core=W112_SUMMONSCOUT_STATE
        S.lastName=type(core)=="table" and trim(core.summonActiveName or "") or ""
        S.lastRequestSeq=type(core)=="table" and trim(tostring(core.summonActiveRequestSeq or "")) or ""
        S.lastStarted=type(core)=="table" and core.summonActiveStarted and true or false
        S.lastNativeStatus=trim(tostring(W112_AUTOSUMMON_NATIVE_STATUS or ""))
    end)
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<(S.nextSweepAt or 0) then return end
        S.nextSweepAt=t+SWEEP; observe()
    end)
end

W112_SUMMON_CORE_V3_SUMMON_SHADOW_API={
    version=VERSION,
    GetState=function() return S end,
    GetSince=getSince
}
