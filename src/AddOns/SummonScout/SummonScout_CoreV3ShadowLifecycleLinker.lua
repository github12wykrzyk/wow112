-- SummonScout Core V3 shadow lifecycle evidence linker.
-- Correlates SummonService/PaymentService evidence with an existing TransactionStore txId.
-- Read-only with respect to TransactionStore and all legacy runtime state.

local VERSION="p1-shadow-lifecycle-linker"
local SWEEP=0.10
local MAX_LINKS=512
local L=W112_SUMMON_CORE_V3_LIFECYCLE_LINKER_SHADOW
if type(L)~="table" then L={}; W112_SUMMON_CORE_V3_LIFECYCLE_LINKER_SHADOW=L end
L.version=VERSION
L.summonCursor=tonumber(L.summonCursor) or 0
L.paymentCursor=tonumber(L.paymentCursor) or 0
L.nextSweepAt=tonumber(L.nextSweepAt) or 0
L.links=type(L.links)=="table" and L.links or {}
L.byTxId=type(L.byTxId)=="table" and L.byTxId or {}
L.metrics=type(L.metrics)=="table" and L.metrics or {summonLinked=0,paymentLinked=0,orphan=0}

local function now() return GetTime and (tonumber(GetTime()) or 0) or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function key(v) return string.lower(trim(v)) end

local function appendBounded(list,item,maxCount)
    list[table.getn(list)+1]=item
    while table.getn(list)>maxCount do table.remove(list,1) end
end

local function transactionFor(name,includeClosed)
    local api=W112_SUMMON_CORE_V3_SHADOW_API
    if type(api)~="table" then return nil end

    if type(api.FindNewestOpenForCustomer)=="function" then
        local ok,tx=true,nil
        if pcall then ok,tx=pcall(api.FindNewestOpenForCustomer,name) else tx=api.FindNewestOpenForCustomer(name) end
        if ok and type(tx)=="table" and tx.id then return tx end
    end

    if not includeClosed or type(api.GetState)~="function" then return nil end
    local ok,state=true,nil
    if pcall then ok,state=pcall(api.GetState) else state=api.GetState() end
    if not ok or type(state)~="table" or type(state.transactions)~="table" then return nil end
    local wanted=key(name); local i,tx
    for i=table.getn(state.transactions),1,-1 do
        tx=state.transactions[i]
        if type(tx)=="table" and tx.id and key(tx.customer or "")==wanted then return tx end
    end
    return nil
end

local function link(source,event,name,includeClosed)
    local tx=transactionFor(name,includeClosed)
    local row={
        observedAt=now(),source=source,kind=tostring(event and event.kind or "OBS"),
        sourceSeq=tonumber(event and event.seq) or 0,customer=trim(name),
        txId=tx and tostring(tx.id) or "",requestSeq=trim(event and event.requestSeq or ""),
        copper=math.floor(tonumber(event and event.copper) or 0),detail=tostring(event and event.detail or "")
    }
    if tx then
        local bucket=L.byTxId[row.txId]
        if type(bucket)~="table" then bucket={}; L.byTxId[row.txId]=bucket end
        appendBounded(bucket,row,64)
        if source=="summon" then L.metrics.summonLinked=(tonumber(L.metrics.summonLinked) or 0)+1
        else L.metrics.paymentLinked=(tonumber(L.metrics.paymentLinked) or 0)+1 end
    else
        L.metrics.orphan=(tonumber(L.metrics.orphan) or 0)+1
    end
    appendBounded(L.links,row,MAX_LINKS)
end

local function consumeSummon()
    local api=W112_SUMMON_CORE_V3_SUMMON_SHADOW_API
    if type(api)~="table" or type(api.GetSince)~="function" then return end
    local events=api.GetSince(L.summonCursor); local i,e
    for i=1,table.getn(events) do
        e=events[i]
        if type(e)=="table" then
            link("summon",e,e.customer or "",false)
            if (tonumber(e.seq) or 0)>L.summonCursor then L.summonCursor=tonumber(e.seq) or L.summonCursor end
        end
    end
end

local function consumePayment()
    local api=W112_SUMMON_CORE_V3_PAYMENT_SHADOW_API
    if type(api)~="table" or type(api.GetSince)~="function" then return end
    local events=api.GetSince(L.paymentCursor); local i,e
    for i=1,table.getn(events) do
        e=events[i]
        if type(e)=="table" then
            -- TransactionStore may have already closed the matching tx from the same
            -- legacy payment row earlier in the frame. Payment correlation therefore
            -- permits the newest matching closed tx as a read-only fallback.
            link("payment",e,e.player or "",true)
            if (tonumber(e.seq) or 0)>L.paymentCursor then L.paymentCursor=tonumber(e.seq) or L.paymentCursor end
        end
    end
end

local function evidenceFor(txId)
    return L.byTxId[tostring(txId or "")]
end

local frame=CreateFrame and CreateFrame("Frame","SummonScoutCoreV3ShadowLifecycleLinkerFrame") or nil
if frame then
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<(L.nextSweepAt or 0) then return end
        L.nextSweepAt=t+SWEEP; consumeSummon(); consumePayment()
    end)
end

W112_SUMMON_CORE_V3_LIFECYCLE_LINKER_SHADOW_API={
    version=VERSION,
    GetState=function() return L end,
    EvidenceFor=evidenceFor
}
