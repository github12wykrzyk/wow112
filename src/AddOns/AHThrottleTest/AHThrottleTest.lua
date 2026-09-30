-- AHThrottleTest for World of Warcraft 1.12.1 (build 5875)
-- Standalone diagnostics. Does not modify AuxVmangos and never buys auctions.

local AHT = {
    open = false,
    bench = {
        running = false,
        captured = false,
        stageActive = false,
        stage = 0,
        intervalMs = 0,
        expected = 0,
        rawEvents = 0,
        uniqueCount = 0,
        signatures = {},
        results = {},
        startedAt = 0,
    },
}

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[AHT]|r " .. tostring(msg))
    end
end

local function now()
    if GetTime then return GetTime() end
    return 0
end

local function fmt(v)
    if v == nil then return "-" end
    return string.format("%.3f", v)
end

local function canSend()
    if not CanSendAuctionQuery then return nil end
    local ok, value = pcall(CanSendAuctionQuery)
    if not ok then return nil end
    return value and true or false
end

local function auctionOpen()
    if AuctionFrame and AuctionFrame.IsVisible and AuctionFrame:IsVisible() then
        return true
    end
    return AHT.open
end

local function auxBusy()
    return AVM and (AVM.queryInFlight or AVM.phase ~= "IDLE" or (AVM.market and AVM.market.active))
end

local function pageInfo()
    if not GetNumAuctionItems then return 0, 0 end
    local rows, total = GetNumAuctionItems("list")
    return tonumber(rows) or 0, tonumber(total) or 0
end

local function auctionRowSignature(index)
    local name, texture, count, quality, canUse, level, minBid, minInc, buyout, bid, highBidder, owner =
        GetAuctionItemInfo("list", index)
    if not name then return "nil" end
    return tostring(name) .. ":" ..
        tostring(count or 0) .. ":" ..
        tostring(quality or 0) .. ":" ..
        tostring(level or 0) .. ":" ..
        tostring(minBid or 0) .. ":" ..
        tostring(minInc or 0) .. ":" ..
        tostring(buyout or 0) .. ":" ..
        tostring(bid or 0)
end

local function pageSignature()
    local rows, total = pageInfo()
    local parts = { tostring(rows), tostring(total) }
    if rows > 0 then
        local probes = { 1, 2, 7, 13, 25, 37, 50 }
        local i, idx
        for i = 1, table.getn(probes) do
            idx = probes[i]
            if idx <= rows then
                table.insert(parts, auctionRowSignature(idx))
            end
        end
    end
    return table.concat(parts, "|"), rows, total
end

local function resetBench()
    AHT.bench.running = false
    AHT.bench.captured = false
    AHT.bench.stageActive = false
    AHT.bench.stage = 0
    AHT.bench.intervalMs = 0
    AHT.bench.expected = 0
    AHT.bench.rawEvents = 0
    AHT.bench.uniqueCount = 0
    AHT.bench.signatures = {}
    AHT.bench.results = {}
    AHT.bench.startedAt = 0
end

function AHThrottleTest_BenchNativeStart()
    if not auctionOpen() then
        out("BENCH: otworz Auction House")
        return
    end
    if auxBusy() then
        out("BENCH: AuxVmangos skanuje. Zatrzymaj skan i nacisnij F5 ponownie.")
        return
    end
    if canSend() ~= true then
        out("BENCH: poczekaj az Search/CanSend bedzie aktywny i nacisnij F5 ponownie.")
        return
    end

    resetBench()
    AHT.bench.running = true
    AHT.bench.startedAt = now()
    out("=== MAX THROUGHPUT BENCH START ===")
    out("Nie klikaj AH i nie uruchamiaj AUX. Test potrwa ok. 60-75 s.")
    out("Baseline QueryAuctionItems page=0; DLL przechwyci exact packet.")
    local ok, err = pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, 0, false, 0, false)
    if not ok then
        out("BENCH baseline ERROR: " .. tostring(err))
        resetBench()
    end
end

function AHThrottleTest_BenchMarkCapture()
    if not AHT.bench.running then return end
    AHT.bench.captured = true
    out("BENCH DLL: packet 0x258 captured; listfrom=0 validated.")
end

function AHThrottleTest_BenchStageStart(stage, intervalMs, expected)
    if not AHT.bench.running then return end
    AHT.bench.stage = tonumber(stage) or 0
    AHT.bench.intervalMs = tonumber(intervalMs) or 0
    AHT.bench.expected = tonumber(expected) or 0
    AHT.bench.rawEvents = 0
    AHT.bench.uniqueCount = 0
    AHT.bench.signatures = {}
    AHT.bench.stageActive = true
    out("STAGE " .. tostring(stage) ..
        " interval=" .. tostring(intervalMs) .. "ms" ..
        " sends=" .. tostring(expected) ..
        " (~" .. tostring(math.floor(50000 / intervalMs + 0.5)) .. " auctions/s)")
end

function AHThrottleTest_BenchStageDone(stage, intervalMs, sent)
    if not AHT.bench.running then return end
    AHT.bench.stageActive = false
    local unique = AHT.bench.uniqueCount
    local expected = tonumber(sent) or AHT.bench.expected
    local loss = expected - unique
    if loss < 0 then loss = 0 end
    local lossless = (unique == expected)
    local r = {
        stage = tonumber(stage) or 0,
        intervalMs = tonumber(intervalMs) or 0,
        sent = expected,
        unique = unique,
        rawEvents = AHT.bench.rawEvents,
        loss = loss,
        lossless = lossless,
    }
    table.insert(AHT.bench.results, r)
    out("RESULT " .. tostring(intervalMs) .. "ms: sent=" .. tostring(expected) ..
        " unique=" .. tostring(unique) ..
        " loss=" .. tostring(loss) ..
        " rawEvents=" .. tostring(AHT.bench.rawEvents) ..
        " => " .. (lossless and "LOSSLESS" or "LOSS/INVALID"))
end

function AHThrottleTest_BenchFinished()
    if not AHT.bench.running then return end
    AHT.bench.stageActive = false
    out("=== MAX THROUGHPUT RESULT ===")
    local fastest = nil
    local i, r
    for i = 1, table.getn(AHT.bench.results) do
        r = AHT.bench.results[i]
        out(tostring(r.intervalMs) .. "ms: " ..
            tostring(r.unique) .. "/" .. tostring(r.sent) ..
            " unique, loss=" .. tostring(r.loss) ..
            " [" .. (r.lossless and "PASS" or "FAIL") .. "]")
        if r.lossless and (not fastest or r.intervalMs < fastest.intervalMs) then
            fastest = r
        end
    end
    if fastest then
        local qps = 1000 / fastest.intervalMs
        local aps = qps * 50
        out("FASTEST LOSSLESS = " .. tostring(fastest.intervalMs) .. "ms" ..
            " = " .. fmt(qps) .. " query/s" ..
            " ~= " .. fmt(aps) .. " auctions/s")
        out("To jest punkt do dalszej walidacji dlugim soak testem przed AUX.")
    else
        out("Brak etapu 25/25. Potrzebny wolniejszy lub dluzszy test diagnostyczny.")
    end
    AHT.bench.running = false
end

function AHThrottleTest_BenchAbort(reason)
    out("BENCH ABORT: " .. tostring(reason))
    resetBench()
end

local frame = CreateFrame("Frame", "AHThrottleTestFrame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

frame:SetScript("OnEvent", function()
    if event == "AUCTION_HOUSE_SHOW" then
        AHT.open = true
    elseif event == "AUCTION_HOUSE_CLOSED" then
        AHT.open = false
        if AHT.bench.running then
            out("BENCH ABORT: Auction House closed")
            resetBench()
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        if AHT.bench.running and AHT.bench.stageActive then
            AHT.bench.rawEvents = AHT.bench.rawEvents + 1
            local sig = pageSignature()
            if not AHT.bench.signatures[sig] then
                AHT.bench.signatures[sig] = true
                AHT.bench.uniqueCount = AHT.bench.uniqueCount + 1
            end
        end
    end
end)

SLASH_AHTHROTTLETEST1 = "/ahtest"
SlashCmdList["AHTHROTTLETEST"] = function(msg)
    msg = string.lower(msg or "")
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")
    if msg == "" or msg == "status" then
        out("bench=" .. tostring(AHT.bench.running) ..
            " stage=" .. tostring(AHT.bench.stage) ..
            " unique=" .. tostring(AHT.bench.uniqueCount) ..
            "/" .. tostring(AHT.bench.expected) ..
            " CanSend=" .. tostring(canSend()))
    elseif msg == "bench" or msg == "native" then
        out("MAX BENCH: otworz AH, zatrzymaj AUX, poczekaj az Search aktywny, potem nacisnij F5 jeden raz.")
    elseif msg == "help" then
        out("/ahtest bench | status  (bench uruchamiasz F5)")
    else
        out("nieznana komenda; /ahtest help")
    end
end

out("loaded v1.2 MAXBENCH. /ahtest bench -> F5.")
