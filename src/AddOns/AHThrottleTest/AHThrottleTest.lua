-- AHThrottleTest v1.6 retry-model benchmark for WoW 1.12.1 build 5875.
-- Uses WoWAHThrottleNative_5875_v4_RANGE sender. Never bids or buys.
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
local function saveReport()
    AHThrottleTestDB.last={
        timestamp=(date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or 0)),
        mode="retry-model-75-vs-110",
        results=AHT.bench.results
    }
end
local function resetBench()
    restoreBrowse()
    AHT.bench.running=false;AHT.bench.stageActive=false;AHT.bench.stage=0
    AHT.bench.intervalMs=0;AHT.bench.expected=0;AHT.bench.rawEvents=0
    AHT.bench.results={};AHT.bench.startedAt=0
end

function AHThrottleTest_BenchNativeStart()
    if not auctionOpen() then out("SOAK: otworz Auction House");return end
    if auxBusy() then out("SOAK: AuxVmangos skanuje. Zatrzymaj go i nacisnij F5 ponownie.");return end
    if canSend()~=true then out("SOAK: poczekaj az Search bedzie aktywny i nacisnij F5 ponownie.");return end
    resetBench()
    AHT.bench.running=true;AHT.bench.startedAt=now();detachBrowse()
    out("=== AH SOAK RANGE 75-150ms ===")
    out("6 x 500 query. Nie klikaj AH; test potrwa ok. 6-7 min.")
    local ok,err=pcall(QueryAuctionItems,"",nil,nil,0,0,0,0,false,0,false)
    if not ok then out("SOAK baseline ERROR: "..tostring(err));resetBench() end
end

function AHThrottleTest_BenchMarkCapture()
    if AHT.bench.running then out("SOAK DLL: CMSG_AUCTION_LIST_ITEMS captured.") end
end

function AHThrottleTest_BenchStageStart(stage,intervalMs,expected)
    if not AHT.bench.running then return end
    AHT.bench.stageActive=true;AHT.bench.stage=tonumber(stage) or 0
    AHT.bench.intervalMs=tonumber(intervalMs) or 0;AHT.bench.expected=tonumber(expected) or 500
    AHT.bench.rawEvents=0
    out("SOAK START "..tostring(intervalMs).."ms sends="..tostring(expected))
end

function AHThrottleTest_BenchStageDone(stage,intervalMs,sent)
    if not AHT.bench.running then return end
    AHT.bench.stageActive=false
    local expected=tonumber(sent) or AHT.bench.expected
    local recv=AHT.bench.rawEvents
    local miss=expected-recv;if miss<0 then miss=0 end
    local extra=recv-expected;if extra<0 then extra=0 end
    local lossPct=expected>0 and miss*100/expected or 100
    local effective=(50000/(tonumber(intervalMs) or 1))*(math.min(recv,expected)/expected)
    local r={intervalMs=tonumber(intervalMs) or 0,sent=expected,recv=recv,missing=miss,extra=extra,lossPct=lossPct,effective=effective}
    table.insert(AHT.bench.results,r)
    out("SOAK RESULT "..tostring(intervalMs).."ms recv="..tostring(recv).."/"..tostring(expected)..
        " miss="..tostring(miss).." ("..fmt(lossPct).."%) extra="..tostring(extra)..
        " effective~"..fmt(effective).." auc/s")
end

function AHThrottleTest_BenchFinished()
    if not AHT.bench.running then return end
    AHT.bench.stageActive=false
    out("=== AH SOAK FINAL ===")
    local i,r,best=nil
    for i=1,table.getn(AHT.bench.results) do
        r=AHT.bench.results[i]
        out(tostring(r.intervalMs).."ms: recv="..tostring(r.recv).."/"..tostring(r.sent)..
            " miss="..fmt(r.lossPct).."% effective~"..fmt(r.effective).." auc/s")
        if r.extra==0 and (not best or r.effective>best.effective) then best=r end
    end
    if best then
        out("BEST EFFECTIVE RAW = "..tostring(best.intervalMs).."ms ~= "..fmt(best.effective)..
            " auc/s przy miss="..fmt(best.lossPct).."%")
    end
    local r75=nil
    local r110=nil
    for i=1,table.getn(AHT.bench.results) do
        r=AHT.bench.results[i]
        if r.intervalMs==75 then r75=r end
        if r.intervalMs==110 then r110=r end
    end
    if r75 and r110 then
        out("=== SELECTIVE RETRY MODEL ===")
        local retryCount=r75.missing or 0
        local burstSendMs=r75.sent*75
        local retrySendMs=retryCount*110
        local projectedSendMs=burstSendMs+retrySendMs
        local baselineSendMs=r110.sent*110
        local gainMs=baselineSendMs-projectedSendMs
        local gainPct=baselineSendMs>0 and (gainMs*100/baselineSendMs) or 0
        local retrySafe=(r110.missing==0)
        out("75ms burst: missing="..tostring(retryCount).."/"..tostring(r75.sent)..
            " ("..fmt(r75.lossPct).."%)")
        out("110ms reference: missing="..tostring(r110.missing).."/"..tostring(r110.sent)..
            " ("..fmt(r110.lossPct).."%)")
        out("Projected request schedule: 75ms burst + "..tostring(retryCount)..
            " retry @110ms = "..fmt(projectedSendMs/1000).."s")
        out("Full 110ms request schedule = "..fmt(baselineSendMs/1000).."s")
        out("Projected gain = "..fmt(gainMs/1000).."s ("..fmt(gainPct).."%)")
        if retrySafe and gainMs>0 then
            out("MODEL VERDICT: 75ms + selective retry is faster, assuming missing pages can be identified exactly.")
        elseif not retrySafe then
            out("MODEL VERDICT: 110ms was not lossless in this run; retry floor needs a safer interval.")
        else
            out("MODEL VERDICT: full 110ms is not slower in this run.")
        end
        AHThrottleTestDB.lastRetryModel={
            timestamp=(date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or 0)),
            burstIntervalMs=75,
            retryIntervalMs=110,
            burstMissing=retryCount,
            referenceMissing=r110.missing,
            projectedSendMs=projectedSendMs,
            baselineSendMs=baselineSendMs,
            gainMs=gainMs,
            gainPct=gainPct,
            retrySafe=retrySafe
        }
    end
    saveReport();restoreBrowse();AHT.bench.running=false
    out("Wynik zapisany do AHThrottleTestDB.last + lastRetryModel")
end

function AHThrottleTest_BenchAbort(reason)
    out("SOAK ABORT: "..tostring(reason));saveReport();resetBench()
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
        out("soak="..tostring(AHT.bench.running).." stage="..tostring(AHT.bench.stage)..
            " interval="..tostring(AHT.bench.intervalMs).." recv="..tostring(AHT.bench.rawEvents)..
            "/"..tostring(AHT.bench.expected).." CanSend="..tostring(canSend()))
    elseif msg=="soak" or msg=="bench" or msg=="native" then
        out("SOAK: otworz AH, zatrzymaj AUX, poczekaj na aktywny Search i nacisnij F5 raz.")
    elseif msg=="last" then
        if AHThrottleTestDB.last and AHThrottleTestDB.last.results then
            out("LAST "..tostring(AHThrottleTestDB.last.timestamp))
            local i,r
            for i=1,table.getn(AHThrottleTestDB.last.results) do
                r=AHThrottleTestDB.last.results[i]
                out(tostring(r.intervalMs).."ms recv="..tostring(r.recv).."/"..tostring(r.sent)..
                    " miss="..fmt(r.lossPct).."% effective~"..fmt(r.effective).." auc/s")
            end
        else out("brak zapisanego wyniku") end
    else out("/ahtest soak | status | last") end
end

out("loaded v1.6 RETRY MODEL. /ahtest soak -> F5.")
