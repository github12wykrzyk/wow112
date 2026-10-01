-- AHThrottleTest v2.0 native receive-probe benchmark + V8 companion for WoW 1.12.1 build 5875.
-- Uses WoWAHThrottleNative_5875_v8_FASTMARKET sender/receiver observer. Never bids or buys.
AHThrottleTestDB = AHThrottleTestDB or {}

local AHT={open=false,bench={running=false,stageActive=false,stage=0,intervalMs=0,expected=0,rawEvents=0,results={},browseWasDetached=false,startedAt=0}}

local function out(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[AHT]|r "..tostring(msg)) end
end
local function now() return GetTime and GetTime() or 0 end
local function fmt(v) return string.format("%.3f",tonumber(v) or 0) end
local function canSend()
    if not CanSendAuctionQuery then return nil end
    local ok,v=pcall(CanSendAuctionQuery)
    if not ok then return nil end
    return v and true or false
end
local function auctionOpen()
    if AuctionFrame and AuctionFrame.IsVisible and AuctionFrame:IsVisible() then return true end
    return AHT.open
end
local function auxBusy()
    return AVM and (AVM.queryInFlight or AVM.phase~="IDLE" or (AVM.market and AVM.market.active) or (AVM.vendor and AVM.vendor.active))
end
local function detachBrowse()
    if AuctionFrameBrowse and AuctionFrameBrowse.UnregisterEvent then
        AuctionFrameBrowse:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
        AHT.bench.browseWasDetached=true
        out("UI isolation ON")
    else
        out("UI isolation WARNING: AuctionFrameBrowse not found")
    end
end
local function restoreBrowse()
    if AHT.bench.browseWasDetached and AuctionFrameBrowse and AuctionFrameBrowse.RegisterEvent then
        AuctionFrameBrowse:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
        AHT.bench.browseWasDetached=false
        out("UI isolation OFF")
    end
end
local function saveReport(summary)
    AHThrottleTestDB.last={
        timestamp=(date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or 0)),
        mode="repeatability-75-vs-125-rxprobe",
        results=AHT.bench.results,
        summary=summary
    }
end
local function resetBench()
    restoreBrowse()
    AHT.bench.running=false;AHT.bench.stageActive=false;AHT.bench.stage=0
    AHT.bench.intervalMs=0;AHT.bench.expected=0;AHT.bench.rawEvents=0
    AHT.bench.results={};AHT.bench.startedAt=0
end

function AHThrottleTest_BenchNativeStart()
    if not auctionOpen() then out("REPEAT: otworz Auction House");return end
    if auxBusy() then out("REPEAT: AuxVmangos skanuje. Zatrzymaj go i nacisnij F5 ponownie.");return end
    if canSend()~=true then out("REPEAT: poczekaj az Search bedzie aktywny i nacisnij F5 ponownie.");return end
    resetBench()
    AHT.bench.running=true;AHT.bench.startedAt=now();detachBrowse()
    out("=== AH RX PROBE 75ms vs 125ms ===")
    out("native SMSG_AUCTION_LIST_RESULT hook: VERIFIED/ACTIVE")
    out("10 etapow: 75/125 przeplatane, po 500 query. Nie klikaj AH.")
    out("Test potrwa ok. 10-12 min.")
    local ok,err=pcall(QueryAuctionItems,"",nil,nil,0,0,0,0,false,0,false)
    if not ok then out("REPEAT baseline ERROR: "..tostring(err));resetBench() end
end

function AHThrottleTest_BenchMarkCapture()
    if AHT.bench.running then out("REPEAT DLL: CMSG_AUCTION_LIST_ITEMS captured.") end
end

function AHThrottleTest_BenchStageStart(stage,intervalMs,expected)
    if not AHT.bench.running then return end
    AHT.bench.stageActive=true;AHT.bench.stage=tonumber(stage) or 0
    AHT.bench.intervalMs=tonumber(intervalMs) or 0;AHT.bench.expected=tonumber(expected) or 500
    AHT.bench.rawEvents=0
    local rep=math.floor((AHT.bench.stage+1)/2)
    out("RUN "..tostring(rep).."/5 @ "..tostring(intervalMs).."ms sends="..tostring(expected))
end

function AHThrottleTest_BenchStageDone(stage,intervalMs,sent,nativeRecv,nativeInvalid)
    if not AHT.bench.running then return end
    AHT.bench.stageActive=false
    local expected=tonumber(sent) or AHT.bench.expected
    local recv=AHT.bench.rawEvents
    local nrecv=tonumber(nativeRecv) or 0
    local nbad=tonumber(nativeInvalid) or 0
    local miss=expected-recv;if miss<0 then miss=0 end
    local extra=recv-expected;if extra<0 then extra=0 end
    local nmiss=expected-nrecv;if nmiss<0 then nmiss=0 end
    local nextra=nrecv-expected;if nextra<0 then nextra=0 end
    local lossPct=expected>0 and miss*100/expected or 100
    local nativeLossPct=expected>0 and nmiss*100/expected or 100
    local effective=(50000/(tonumber(intervalMs) or 1))*(math.min(nrecv,expected)/expected)
    local rr={stage=tonumber(stage) or 0,intervalMs=tonumber(intervalMs) or 0,sent=expected,recv=recv,missing=miss,extra=extra,lossPct=lossPct,nativeRecv=nrecv,nativeMissing=nmiss,nativeExtra=nextra,nativeInvalid=nbad,nativeLossPct=nativeLossPct,effective=effective}
    table.insert(AHT.bench.results,rr)
    out("RESULT "..tostring(intervalMs).."ms event="..tostring(recv).."/"..tostring(expected)..
        " native="..tostring(nrecv).."/"..tostring(expected).." nativeBad="..tostring(nbad))
    out("LOSS event="..fmt(lossPct).."% native="..fmt(nativeLossPct).."% effective~"..fmt(effective).." auc/s")
end

local function summarize(interval)
    local n,totalSent,totalRecv,totalMiss,sumLoss,sumSq,worst,best,worstMissing,zeroRuns = 0,0,0,0,0,0,-1,101,0,0
    local totalNativeRecv,totalNativeMiss,sumNativeLoss,sumNativeSq,nativeWorst,nativeWorstMissing,nativeZeroRuns,nativeInvalid = 0,0,0,0,-1,0,0,0
    local i,r
    for i=1,table.getn(AHT.bench.results) do
        r=AHT.bench.results[i]
        if r.intervalMs==interval then
            n=n+1;totalSent=totalSent+r.sent;totalRecv=totalRecv+r.recv;totalMiss=totalMiss+r.missing
            sumLoss=sumLoss+r.lossPct;sumSq=sumSq+r.lossPct*r.lossPct
            if r.lossPct>worst then worst=r.lossPct;worstMissing=r.missing end
            if r.lossPct<best then best=r.lossPct end
            if r.missing==0 then zeroRuns=zeroRuns+1 end
            totalNativeRecv=totalNativeRecv+(r.nativeRecv or 0);totalNativeMiss=totalNativeMiss+(r.nativeMissing or 0)
            sumNativeLoss=sumNativeLoss+(r.nativeLossPct or 0);sumNativeSq=sumNativeSq+(r.nativeLossPct or 0)*(r.nativeLossPct or 0)
            if (r.nativeLossPct or 0)>nativeWorst then nativeWorst=(r.nativeLossPct or 0);nativeWorstMissing=(r.nativeMissing or 0) end
            if (r.nativeMissing or 0)==0 then nativeZeroRuns=nativeZeroRuns+1 end
            nativeInvalid=nativeInvalid+(r.nativeInvalid or 0)
        end
    end
    local mean=n>0 and sumLoss/n or 0
    local var=n>0 and (sumSq/n-mean*mean) or 0;if var<0 then var=0 end
    local sd=math.sqrt(var)
    local aggregateLoss=totalSent>0 and totalMiss*100/totalSent or 100
    local nativeMean=n>0 and sumNativeLoss/n or 0
    local nativeVar=n>0 and (sumNativeSq/n-nativeMean*nativeMean) or 0;if nativeVar<0 then nativeVar=0 end
    local nativeSd=math.sqrt(nativeVar)
    local nativeAggregateLoss=totalSent>0 and totalNativeMiss*100/totalSent or 100
    return {intervalMs=interval,runs=n,totalSent=totalSent,totalRecv=totalRecv,totalMiss=totalMiss,meanLoss=mean,sdLoss=sd,worstLoss=worst,bestLoss=best,worstMissing=worstMissing,zeroRuns=zeroRuns,aggregateLoss=aggregateLoss,totalNativeRecv=totalNativeRecv,totalNativeMiss=totalNativeMiss,nativeMeanLoss=nativeMean,nativeSdLoss=nativeSd,nativeWorstLoss=nativeWorst,nativeWorstMissing=nativeWorstMissing,nativeZeroRuns=nativeZeroRuns,nativeAggregateLoss=nativeAggregateLoss,nativeInvalid=nativeInvalid}
end

function AHThrottleTest_BenchFinished()
    if not AHT.bench.running then return end
    AHT.bench.stageActive=false
    out("=== REPEATABILITY FINAL ===")
    local s75=summarize(75)
    local s125=summarize(125)
    out("75ms EVENT: recv="..tostring(s75.totalRecv).."/"..tostring(s75.totalSent)..
        " miss="..fmt(s75.aggregateLoss).."% worst="..fmt(s75.worstLoss).."%")
    out("75ms NATIVE: recv="..tostring(s75.totalNativeRecv).."/"..tostring(s75.totalSent)..
        " miss="..fmt(s75.nativeAggregateLoss).."% worst="..fmt(s75.nativeWorstLoss)..
        "% zero-loss="..tostring(s75.nativeZeroRuns).."/"..tostring(s75.runs).." bad="..tostring(s75.nativeInvalid))
    out("125ms EVENT: recv="..tostring(s125.totalRecv).."/"..tostring(s125.totalSent)..
        " miss="..fmt(s125.aggregateLoss).."% worst="..fmt(s125.worstLoss).."%")
    out("125ms NATIVE: recv="..tostring(s125.totalNativeRecv).."/"..tostring(s125.totalSent)..
        " miss="..fmt(s125.nativeAggregateLoss).."% worst="..fmt(s125.nativeWorstLoss)..
        "% zero-loss="..tostring(s125.nativeZeroRuns).."/"..tostring(s125.runs).." bad="..tostring(s125.nativeInvalid))

    local avgRetryCount=s75.totalNativeMiss/math.max(1,s75.runs)
    local projected75=500*75 + avgRetryCount*125
    local full125=500*125
    local gain=full125-projected75
    local gainPct=gain*100/full125
    local worstProjected75=500*75 + s75.nativeWorstMissing*125
    local worstGain=full125-worstProjected75
    local worstGainPct=worstGain*100/full125

    out("=== NATIVE RECEIVE VERDICT ===")
    local decision
    if s75.totalNativeMiss==0 and s125.totalNativeMiss==0 and s75.nativeInvalid==0 and s125.nativeInvalid==0 then
        decision="native RX is lossless in this run; Lua event misses are not missing SMSG responses"
    elseif s75.totalNativeMiss>0 or s125.totalNativeMiss>0 then
        decision="real native RX gaps observed; retry/correlation work remains necessary"
    else
        decision="native RX payload sanity failed; do not interpret event misses as packet loss"
    end
    out("DECISION: "..decision)
    if s75.totalNativeMiss>0 then
        out("Projected 75ms + retry@125 from NATIVE gaps: avg gain="..fmt(gainPct).."% worst="..fmt(worstGainPct).."%")
    else
        out("No native 75ms gaps -> selective retry is unnecessary for this run.")
    end

    local summary={s75=s75,s125=s125,avgRetryCount=avgRetryCount,projected75ms=projected75,baseline125ms=full125,gainMs=gain,gainPct=gainPct,worstProjected75ms=worstProjected75,worstGainMs=worstGain,worstGainPct=worstGainPct,decision=decision}
    saveReport(summary);restoreBrowse();AHT.bench.running=false
    out("Wynik zapisany do AHThrottleTestDB.last")
end

function AHThrottleTest_BenchAbort(reason)
    out("REPEAT ABORT: "..tostring(reason));saveReport(nil);resetBench()
end

local frame=CreateFrame("Frame","AHThrottleTestFrame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
frame:SetScript("OnEvent",function()
    if event=="AUCTION_HOUSE_SHOW" then AHT.open=true
    elseif event=="AUCTION_HOUSE_CLOSED" then
        AHT.open=false
        if AHT.bench.running then AHThrottleTest_BenchAbort("Auction House closed") end
    elseif event=="AUCTION_ITEM_LIST_UPDATE" and AHT.bench.running and AHT.bench.stageActive then
        AHT.bench.rawEvents=AHT.bench.rawEvents+1
    end
end)

SLASH_AHTHROTTLETEST1="/ahtest"
SlashCmdList["AHTHROTTLETEST"]=function(msg)
    msg=string.lower(msg or "");msg=string.gsub(msg,"^%s+","");msg=string.gsub(msg,"%s+$","")
    if msg=="" or msg=="status" then
        out("repeat="..tostring(AHT.bench.running).." stage="..tostring(AHT.bench.stage)..
            " interval="..tostring(AHT.bench.intervalMs).." recv="..tostring(AHT.bench.rawEvents)..
            "/"..tostring(AHT.bench.expected).." CanSend="..tostring(canSend()))
    elseif msg=="repeat" or msg=="soak" or msg=="bench" or msg=="native" then
        out("REPEAT: otworz AH, zatrzymaj AUX, poczekaj na aktywny Search i nacisnij F5 raz.")
    elseif msg=="last" then
        if AHThrottleTestDB.last and AHThrottleTestDB.last.summary then
            local s=AHThrottleTestDB.last.summary
            out("LAST "..tostring(AHThrottleTestDB.last.timestamp))
            out("75ms EVENT miss="..fmt(s.s75.aggregateLoss).."% NATIVE miss="..fmt(s.s75.nativeAggregateLoss).."%")
            out("125ms EVENT miss="..fmt(s.s125.aggregateLoss).."% NATIVE miss="..fmt(s.s125.nativeAggregateLoss).."%")
            out("native bad payloads="..tostring((s.s75.nativeInvalid or 0)+(s.s125.nativeInvalid or 0)).." decision="..tostring(s.decision))
        else out("brak kompletnego zapisanego wyniku") end
    else out("/ahtest repeat | status | last") end
end

out("loaded v2.0 RXPROBE/V8. /ahtest repeat -> F5; FAST MARKET -> F6.")
