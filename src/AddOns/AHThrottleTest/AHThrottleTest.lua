-- AHThrottleTest v1.3 event-isolated benchmark for WoW 1.12.1 build 5875.
-- Uses existing WoWAHThrottleNative_5875_v2 sender. Never bids/buys.
AHThrottleTestDB = AHThrottleTestDB or {}

local AHT = {
    open=false,
    bench={
        running=false, stageActive=false, stage=0, intervalMs=0, expected=0,
        rawEvents=0, results={}, startedAt=0, browseWasDetached=false
    }
}

local function out(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[AHT]|r "..tostring(msg)) end
end
local function now() return GetTime and GetTime() or 0 end
local function fmt(v) return string.format("%.3f", tonumber(v) or 0) end
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
        out("UI isolation: AuctionFrameBrowse detached from AUCTION_ITEM_LIST_UPDATE")
    else
        out("UI isolation WARNING: AuctionFrameBrowse not found")
    end
end
local function restoreBrowse()
    if AHT.bench.browseWasDetached and AuctionFrameBrowse and AuctionFrameBrowse.RegisterEvent then
        AuctionFrameBrowse:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
        AHT.bench.browseWasDetached=false
        out("UI isolation: AuctionFrameBrowse restored")
    end
end

local function saveReport()
    local stamp = date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or 0)
    AHThrottleTestDB.last = {
        timestamp=stamp,
        results=AHT.bench.results,
        note="event-isolated raw AUCTION_ITEM_LIST_UPDATE count; stock AuctionFrameBrowse detached during benchmark"
    }
end

local function resetBench()
    restoreBrowse()
    AHT.bench.running=false
    AHT.bench.stageActive=false
    AHT.bench.stage=0
    AHT.bench.intervalMs=0
    AHT.bench.expected=0
    AHT.bench.rawEvents=0
    AHT.bench.results={}
    AHT.bench.startedAt=0
end

function AHThrottleTest_BenchNativeStart()
    if not auctionOpen() then out("BENCH: otworz Auction House"); return end
    if auxBusy() then out("BENCH: AuxVmangos skanuje. Zatrzymaj go i nacisnij F5 ponownie."); return end
    if canSend()~=true then out("BENCH: poczekaj az Search bedzie aktywny i nacisnij F5 ponownie."); return end
    resetBench()
    AHT.bench.running=true
    AHT.bench.startedAt=now()
    detachBrowse()
    out("=== RAW EVENT BENCH V1.3 ===")
    out("Stock Browse UI odlaczone. 25 requestow na etap; liczymy tylko AUCTION_ITEM_LIST_UPDATE.")
    local ok,err=pcall(QueryAuctionItems,"",nil,nil,0,0,0,0,false,0,false)
    if not ok then out("BENCH baseline ERROR: "..tostring(err)); resetBench() end
end

function AHThrottleTest_BenchMarkCapture()
    if AHT.bench.running then out("BENCH DLL: CMSG_AUCTION_LIST_ITEMS captured.") end
end

function AHThrottleTest_BenchStageStart(stage,intervalMs,expected)
    if not AHT.bench.running then return end
    AHT.bench.stageActive=true
    AHT.bench.stage=tonumber(stage) or 0
    AHT.bench.intervalMs=tonumber(intervalMs) or 0
    AHT.bench.expected=tonumber(expected) or 25
    AHT.bench.rawEvents=0
    out("STAGE "..tostring(stage).." interval="..tostring(intervalMs).."ms sends="..tostring(expected))
end

function AHThrottleTest_BenchStageDone(stage,intervalMs,sent)
    if not AHT.bench.running then return end
    AHT.bench.stageActive=false
    local expected=tonumber(sent) or AHT.bench.expected
    local recv=AHT.bench.rawEvents
    local delta=recv-expected
    local miss=expected-recv
    if miss<0 then miss=0 end
    local lossPct=expected>0 and miss*100/expected or 100
    local valid=(recv<=expected)
    local lossless=(recv==expected)
    local effective=(50000/(tonumber(intervalMs) or 1))*(math.min(recv,expected)/expected)
    local r={
        intervalMs=tonumber(intervalMs) or 0,sent=expected,recv=recv,
        delta=delta,missing=miss,lossPct=lossPct,valid=valid,lossless=lossless,effective=effective
    }
    table.insert(AHT.bench.results,r)
    out("RESULT "..tostring(intervalMs).."ms: sent="..tostring(expected)..
        " recv="..tostring(recv).." delta="..tostring(delta)..
        " miss="..fmt(lossPct).."% => "..(lossless and "LOSSLESS" or (valid and "LOSS" or "EXTRA_EVENT")))
end

function AHThrottleTest_BenchFinished()
    if not AHT.bench.running then return end
    AHT.bench.stageActive=false
    out("=== RAW EVENT RESULT V1.3 ===")
    local fastest=nil
    local i,r
    for i=1,table.getn(AHT.bench.results) do
        r=AHT.bench.results[i]
        out(tostring(r.intervalMs).."ms: "..tostring(r.recv).."/"..tostring(r.sent)..
            " miss="..fmt(r.lossPct).."% delta="..tostring(r.delta)..
            " effective~"..fmt(r.effective).." auc/s ["..
            (r.lossless and "PASS" or (r.valid and "FAIL" or "INVALID")).."]")
        if r.lossless and (not fastest or r.intervalMs<fastest.intervalMs) then fastest=r end
    end
    if fastest then
        out("FASTEST RAW LOSSLESS = "..tostring(fastest.intervalMs).."ms = "..
            fmt(1000/fastest.intervalMs).." query/s ~= "..fmt(50000/fastest.intervalMs).." auctions/s")
    else
        out("FASTEST RAW LOSSLESS = brak")
    end
    saveReport()
    restoreBrowse()
    AHT.bench.running=false
    out("Wynik zapisany do AHThrottleTestDB.last")
end

function AHThrottleTest_BenchAbort(reason)
    out("BENCH ABORT: "..tostring(reason))
    saveReport()
    resetBench()
end

local frame=CreateFrame("Frame","AHThrottleTestFrame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
frame:SetScript("OnEvent",function()
    if event=="AUCTION_HOUSE_SHOW" then
        AHT.open=true
    elseif event=="AUCTION_HOUSE_CLOSED" then
        AHT.open=false
        if AHT.bench.running then AHThrottleTest_BenchAbort("Auction House closed") end
    elseif event=="AUCTION_ITEM_LIST_UPDATE" and AHT.bench.running and AHT.bench.stageActive then
        AHT.bench.rawEvents=AHT.bench.rawEvents+1
    end
end)

SLASH_AHTHROTTLETEST1="/ahtest"
SlashCmdList["AHTHROTTLETEST"]=function(msg)
    msg=string.lower(msg or "")
    msg=string.gsub(msg,"^%s+","")
    msg=string.gsub(msg,"%s+$","")
    if msg=="" or msg=="status" then
        out("bench="..tostring(AHT.bench.running).." stage="..tostring(AHT.bench.stage)..
            " interval="..tostring(AHT.bench.intervalMs).."ms recv="..tostring(AHT.bench.rawEvents)..
            "/"..tostring(AHT.bench.expected).." CanSend="..tostring(canSend()))
    elseif msg=="bench" or msg=="native" then
        out("V1.3: otworz AH, zatrzymaj AUX, poczekaj na aktywny Search i nacisnij F5 raz.")
    elseif msg=="last" then
        if AHThrottleTestDB.last and AHThrottleTestDB.last.results then
            out("LAST "..tostring(AHThrottleTestDB.last.timestamp))
            local i,r
            for i=1,table.getn(AHThrottleTestDB.last.results) do
                r=AHThrottleTestDB.last.results[i]
                out(tostring(r.intervalMs).."ms recv="..tostring(r.recv).."/"..tostring(r.sent)..
                    " miss="..fmt(r.lossPct).."%")
            end
        else out("brak zapisanego wyniku") end
    elseif msg=="help" then
        out("/ahtest bench | status | last")
    else
        out("nieznana komenda; /ahtest help")
    end
end

out("loaded v1.3 RAW EVENT BENCH. /ahtest bench -> F5.")
