-- SummonScout Core V3 shadow PaymentService evidence observer.
-- Publishes legacy wallet-delta payment log rows without mutating transactions or sending chat.

SummonScoutDB = SummonScoutDB or {}

local VERSION="p1-shadow-payment-evidence"
local SWEEP=0.20
local MAX_EVENTS=256
local P=W112_SUMMON_CORE_V3_PAYMENT_SHADOW
if type(P)~="table" then P={}; W112_SUMMON_CORE_V3_PAYMENT_SHADOW=P end
P.version=VERSION
P.seq=tonumber(P.seq) or 0
P.events=type(P.events)=="table" and P.events or {}
P.seenRows=type(P.seenRows)=="table" and P.seenRows or {}
P.nextSweepAt=tonumber(P.nextSweepAt) or 0

local function now() return GetTime and (tonumber(GetTime()) or 0) or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end

local function appendBounded(list,item,maxCount)
    list[table.getn(list)+1]=item
    while table.getn(list)>maxCount do table.remove(list,1) end
end

local function emit(row)
    local copper=math.floor(tonumber(row and row.copper) or 0)
    if copper<=0 then return end
    P.seq=(tonumber(P.seq) or 0)+1
    appendBounded(P.events,{
        seq=P.seq,ts=tonumber(row.ts) or 0,mono=now(),kind="PAYMENT_OBSERVED",
        player=trim(row.player or ""),copper=copper
    },MAX_EVENTS)
end

local function seed()
    P.seenRows={}
    local log=SummonScoutDB and SummonScoutDB.paymentLog
    if type(log)~="table" then return end
    local i,row
    for i=1,table.getn(log) do row=log[i]; if type(row)=="table" then P.seenRows[row]=true end end
end

local function observe()
    local log=SummonScoutDB and SummonScoutDB.paymentLog
    if type(log)~="table" then return end
    local i,row
    for i=1,table.getn(log) do
        row=log[i]
        if type(row)=="table" and not P.seenRows[row] then
            P.seenRows[row]=true
            emit(row)
        end
    end
end

local function getSince(seq)
    local out={}; seq=tonumber(seq) or 0
    local i,e
    for i=1,table.getn(P.events) do
        e=P.events[i]
        if type(e)=="table" and (tonumber(e.seq) or 0)>seq then out[table.getn(out)+1]=e end
    end
    return out
end

local frame=CreateFrame and CreateFrame("Frame","SummonScoutCoreV3ShadowPaymentEvidenceFrame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent",function() if event=="PLAYER_LOGIN" then seed() end end)
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<(P.nextSweepAt or 0) then return end
        P.nextSweepAt=t+SWEEP; observe()
    end)
end

W112_SUMMON_CORE_V3_PAYMENT_SHADOW_API={
    version=VERSION,
    GetState=function() return P end,
    GetSince=getSince
}
