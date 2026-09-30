-- AHThrottleTest for World of Warcraft 1.12.1 (build 5875)
-- V1.2.1: debounced result snapshots on top of the existing native V2 sender.
-- Standalone diagnostic. Never bids or buys auctions.

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
        overflow = 0,
        signatures = {},
        results = {},
        startedAt = 0,
        stageStartedAt = 0,
        pendingSnapshot = false,
        snapshotAt = 0,
        lastEventAt = 0,
    },
}

local SNAPSHOT_DEBOUNCE = 0.075

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
    if AuctionFrame and AuctionFrame.IsVisible and AuctionFrame:IsVisible() then return true end
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

local function rowSig(index)
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
        tostring(bid or 0) .. ":" ..
        tostring(owner or "")
end

local function pageSignature()
    local rows, total = pageInfo()
    local parts = { tostring(rows), tostring(total) }
    local i
    for i = 1, rows do
        table.insert(parts, rowSig(i))
    end
    return table.concat(parts, "|"), rows, total
end

local function consumeStableSnapshot()
    if not AHT.bench.running or not AHT.bench.stageActive then return end
    local sig = pageSignature()
    if not AHT.bench.signatures[sig] then
        AHT.bench.signatures[sig] = true
        AHT.bench.uniqueCount = AHT.bench.uniqueCount + 1
        if AHT.bench.uniqueCount > AHT.bench.expected then
            AHT.bench.overflow = AHT.bench.uniqueCount - AHT.bench.expected
        end
    end
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
    AHT.bench.overflow = 0
    AHT.bench.signatures = {}
    AHT.bench.results = {}
    AHT.bench.startedAt = 0
    AHT.bench.stageStartedAt = 0
    AHT.bench.pendingSnapshot = false
    AHT.bench.snapshotAt = 0
    AHT.bench.lastEventAt = 0
end

function AHThrottleTest_BenchNativeStart()
    if not auctionOpen() then out("BENCH: otworz Auction House"); return end
    if auxBusy() then out("BENCH: AuxVmangos skanuje. Zatrzymaj go i nacisnij F5 ponownie."); return end
    if canSend() ~= true then out("BENCH: poczekaj az Search bedzie aktywny i nacisnij F5 ponownie."); return end

    resetBench()
    AHT.bench.running = true
    AHT.bench.startedAt = now()
    out("=== MAX THROUGHPUT BENCH V1.2.1 ===")
    out("Snapshot debounce=75ms; nie klikaj AH i nie uruchamiaj AUX.")
    local ok, err = pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, 0, false, 0, false)
    if not ok then
        out("BENCH baseline ERROR: " .. tostring(err))
        resetBench()
    end
end

function AHThrottleTest_BenchMarkCapture()
    if not AHT.bench.running then return end
    AHT.bench.captured = true
    out("BENCH DLL: exact CMSG_AUCTION_LIST_ITEMS captured.")
end

function AHThrottleTest_BenchStageStart(stage, intervalMs, expected)
    if not AHT.bench.running then return end
    AHT.bench.stage = tonumber(stage) or 0
    AHT.bench.intervalMs = tonumber(intervalMs) or 0
    AHT.bench.expected = tonumber(expected) or 25
    AHT.bench.rawEvents = 0
    AHT.bench.uniqueCount = 0
    AHT.bench.overflow = 0
    AHT.bench.signatures = {}
    AHT.bench.pendingSnapshot = false
    AHT.bench.stageStartedAt = now()
    AHT.bench.stageActive = true
    out("STAGE " .. tostring(stage) ..
        " interval=" .. tostring(intervalMs) .. "ms" ..
        " sends=" .. tostring(expected) ..
        " (~" .. tostring(math.floor(50000 / intervalMs + 0.5)) .. " auctions/s)")
end

function AHThrottleTest_BenchStageDone(stage, intervalMs, sent)
    if not AHT.bench.running then return end
    if AHT.bench.pendingSnapshot then
        consumeStableSnapshot()
        AHT.bench.pendingSnapshot = false
    end
    AHT.bench.stageActive = false

    local expected = tonumber(sent) or AHT.bench.expected
    local unique = AHT.bench.uniqueCount
    local capped = unique
    if capped > expected then capped = expected end
    local missing = expected - capped
    if missing < 0 then missing = 0 end
    local lossPct = expected > 0 and (missing * 100 / expected) or 100
    local overflow = unique > expected and (unique - expected) or 0
    local valid = overflow == 0
    local lossless = valid and missing == 0

    local theoretical = 50000 / (tonumber(intervalMs) or 1)
    local effective = theoretical * (capped / expected)

    local r = {
        intervalMs = tonumber(intervalMs) or 0,
        sent = expected,
        unique = unique,
        capped = capped,
        missing = missing,
        lossPct = lossPct,
        overflow = overflow,
        rawEvents = AHT.bench.rawEvents,
        valid = valid,
        lossless = lossless,
        effective = effective,
    }
    table.insert(AHT.bench.results, r)

    out("RESULT " .. tostring(intervalMs) .. "ms: stable=" .. tostring(capped) ..
        "/" .. tostring(expected) ..
        " miss=" .. tostring(missing) ..
        " (" .. fmt(lossPct) .. "%)" ..
        " rawEvents=" .. tostring(AHT.bench.rawEvents) ..
        " overflow=" .. tostring(overflow) ..
        " => " .. (lossless and "LOSSLESS" or (valid and "LOSS" or "CONTAMINATED")))
end

function AHThrottleTest_BenchFinished()
    if not AHT.bench.running then return end
    AHT.bench.stageActive = false
    out("=== MAX THROUGHPUT RESULT V1.2.1 ===")
    local fastest = nil
    local bestEffective = nil
    local i, r
    for i = 1, table.getn(AHT.bench.results) do
        r = AHT.bench.results[i]
        out(tostring(r.intervalMs) .. "ms: " ..
            tostring(r.capped) .. "/" .. tostring(r.sent) ..
            " miss=" .. fmt(r.lossPct) .. "%" ..
            " overflow=" .. tostring(r.overflow) ..
            " effective~" .. fmt(r.effective) .. " auc/s" ..
            " [" .. (r.lossless and "PASS" or (r.valid and "FAIL" or "INVALID")) .. "]")
        if r.lossless and (not fastest or r.intervalMs < fastest.intervalMs) then fastest = r end
        if r.valid and (not bestEffective or r.effective > bestEffective.effective) then
            bestEffective = r
        end
    end
    if fastest then
        out("FASTEST LOSSLESS = " .. tostring(fastest.intervalMs) .. "ms = " ..
            fmt(1000 / fastest.intervalMs) .. " query/s ~= " ..
            fmt(50000 / fastest.intervalMs) .. " auctions/s")
    else
        out("FASTEST LOSSLESS = brak")
    end
    if bestEffective then
        out("BEST EFFECTIVE = " .. tostring(bestEffective.intervalMs) .. "ms ~= " ..
            fmt(bestEffective.effective) .. " auctions/s przy miss=" ..
            fmt(bestEffective.lossPct) .. "%")
    end
    out("overflow>0 nadal oznacza kontaminacje i taki etap nie jest podstawa do wyboru predkosci.")
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
        if AHT.bench.running then out("BENCH ABORT: Auction House closed"); resetBench() end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" and AHT.bench.running and AHT.bench.stageActive then
        AHT.bench.rawEvents = AHT.bench.rawEvents + 1
        AHT.bench.lastEventAt = now()
        AHT.bench.snapshotAt = AHT.bench.lastEventAt + SNAPSHOT_DEBOUNCE
        AHT.bench.pendingSnapshot = true
    end
end)

frame:SetScript("OnUpdate", function()
    if AHT.bench.running and AHT.bench.stageActive and AHT.bench.pendingSnapshot then
        if now() >= AHT.bench.snapshotAt then
            AHT.bench.pendingSnapshot = false
            consumeStableSnapshot()
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
            " interval=" .. tostring(AHT.bench.intervalMs) .. "ms" ..
            " stable=" .. tostring(AHT.bench.uniqueCount) ..
            "/" .. tostring(AHT.bench.expected) ..
            " raw=" .. tostring(AHT.bench.rawEvents) ..
            " CanSend=" .. tostring(canSend()))
    elseif msg == "bench" or msg == "native" then
        out("BENCH: otworz AH, zatrzymaj AUX, poczekaj az Search aktywny i nacisnij F5 jeden raz.")
    elseif msg == "help" then
        out("/ahtest bench | status")
    else
        out("nieznana komenda; /ahtest help")
    end
end

out("loaded v1.2.1 DEBOUNCED BENCH. /ahtest bench -> F5.")
