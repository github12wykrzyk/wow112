-- AHThrottleTest for World of Warcraft 1.12.1 (build 5875)
-- Standalone diagnostic. It does not modify AuxVmangos and never buys auctions.

local AHT = {
    running = false,
    open = false,
    phase = "IDLE",
    tests = { 5.20, 2.00, 1.00, 0.50, 0.25 },
    index = 0,
    page = 0,
    awaiting = nil,
    sentAt = 0,
    controlRtt = nil,
    challengeAt = 0,
    deadline = 0,
    results = {},
    sends = 0,
    events = 0,
    lastTick = 0,
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

local function pageInfo()
    if not GetNumAuctionItems then return 0, 0 end
    local rows, total = GetNumAuctionItems("list")
    return tonumber(rows) or 0, tonumber(total) or 0
end

local function sendQuery(kind)
    AHT.page = AHT.page + 1
    if AHT.page > 50 then AHT.page = 0 end

    local before = canSend()
    local t = now()
    local ok, err = pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, AHT.page, false, 0, false)
    AHT.sends = AHT.sends + 1
    AHT.awaiting = kind
    AHT.sentAt = t

    out("SEND " .. kind ..
        " page=" .. tostring(AHT.page) ..
        " t=" .. fmt(t) ..
        " CanSend=" .. tostring(before) ..
        " pcall=" .. tostring(ok))

    if not ok then
        out("ERROR QueryAuctionItems: " .. tostring(err))
        AHT.running = false
        AHT.phase = "IDLE"
        AHT.awaiting = nil
        return false
    end
    return true
end

local function finish()
    AHT.running = false
    AHT.phase = "IDLE"
    AHT.awaiting = nil

    out("=== RESULT ===")
    local fastest = nil
    local fastBelowFour = false
    local delayedBelowFour = false
    local i
    for i = 1, table.getn(AHT.results) do
        local r = AHT.results[i]
        local status
        if not r.response then
            status = "NO_RESPONSE"
        elseif r.latency <= r.fastLimit then
            status = "FAST"
            if not fastest or r.interval < fastest then fastest = r.interval end
            if r.interval < 4.0 then fastBelowFour = true end
        else
            status = "DELAYED"
            if r.interval < 4.0 then delayedBelowFour = true end
        end
        out("interval=" .. fmt(r.interval) .. "s" ..
            " CanSend=" .. tostring(r.canSendAtSend) ..
            " status=" .. status ..
            " recv=" .. fmt(r.latency) .. "s" ..
            " rows=" .. tostring(r.rows or 0) ..
            " total=" .. tostring(r.total or 0))
    end

    if fastBelowFour then
        out("WNIOSEK: query ponizej 4s dostalo szybka odpowiedz. UI ~5s nie jest twardym limitem dla QueryAuctionItems.")
    elseif delayedBelowFour then
        out("WNIOSEK: query ponizej 4s dostaje odpowiedz dopiero z opoznieniem. Wyglada na kolejke/throttle poza samym przyciskiem UI.")
    else
        out("WNIOSEK: brak szybkich odpowiedzi ponizej 4s. Prawdopodobny twardy throttle w natywnym API lub po stronie serwera.")
    end

    if fastest then
        out("Najszybszy potwierdzony FAST interval: " .. fmt(fastest) .. "s")
    end
    out("sends=" .. tostring(AHT.sends) .. " events=" .. tostring(AHT.events))
end

local function nextCase()
    AHT.index = AHT.index + 1
    if AHT.index > table.getn(AHT.tests) then
        finish()
        return
    end
    AHT.phase = "WAIT_READY"
    AHT.awaiting = nil
    AHT.controlRtt = nil
    out("CASE " .. tostring(AHT.index) .. "/" .. tostring(table.getn(AHT.tests)) ..
        " interval=" .. fmt(AHT.tests[AHT.index]) .. "s")
end

local function start()
    if AHT.running then
        out("test juz trwa; /ahtest status")
        return
    end
    if not auctionOpen() then
        out("otworz Auction House i uruchom /ahtest start")
        return
    end
    if AVM and (AVM.queryInFlight or AVM.phase ~= "IDLE" or (AVM.market and AVM.market.active)) then
        out("AuxVmangos aktualnie skanuje. Zatrzymaj skan przed testem, zeby eventy sie nie mieszaly.")
        return
    end

    AHT.running = true
    AHT.phase = "WAIT_READY"
    AHT.index = 0
    AHT.page = 0
    AHT.awaiting = nil
    AHT.results = {}
    AHT.sends = 0
    AHT.events = 0
    AHT.lastTick = 0
    out("START. Nie klikaj Search/Next i nie uruchamiaj innego skanera do konca testu.")
    nextCase()
end

local function stop()
    if not AHT.running then
        out("test nie jest aktywny")
        return
    end
    AHT.running = false
    AHT.phase = "IDLE"
    AHT.awaiting = nil
    out("STOP")
end

local function status()
    out("running=" .. tostring(AHT.running) ..
        " phase=" .. tostring(AHT.phase) ..
        " case=" .. tostring(AHT.index) .. "/" .. tostring(table.getn(AHT.tests)) ..
        " sends=" .. tostring(AHT.sends) ..
        " events=" .. tostring(AHT.events) ..
        " CanSend=" .. tostring(canSend()))
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
        if AHT.running then
            out("AH zamkniety - test przerwany")
            stop()
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        if not AHT.running or not AHT.awaiting then return end

        AHT.events = AHT.events + 1
        local t = now()
        local latency = t - AHT.sentAt
        local rows, total = pageInfo()
        local kind = AHT.awaiting
        AHT.awaiting = nil

        out("RECV " .. kind ..
            " dt=" .. fmt(latency) .. "s" ..
            " rows=" .. tostring(rows) ..
            " total=" .. tostring(total) ..
            " CanSend=" .. tostring(canSend()))

        if kind == "control" then
            AHT.controlRtt = latency
            local interval = AHT.tests[AHT.index]
            AHT.challengeAt = AHT.sentAt + interval
            if AHT.challengeAt < t + 0.05 then AHT.challengeAt = t + 0.05 end
            AHT.phase = "WAIT_CHALLENGE"
        elseif kind == "challenge" then
            local r = AHT.results[AHT.index]
            if r then
                r.response = true
                r.latency = latency
                r.rows = rows
                r.total = total
            end
            AHT.phase = "WAIT_RECOVERY"
            AHT.deadline = t + 0.25
        end
    end
end)

frame:SetScript("OnUpdate", function()
    if not AHT.running then return end
    local t = now()
    if t - AHT.lastTick < 0.05 then return end
    AHT.lastTick = t

    if not auctionOpen() then
        out("AH nie jest otwarty - test przerwany")
        stop()
        return
    end

    if AHT.phase == "WAIT_READY" then
        if canSend() == true then
            if sendQuery("control") then
                AHT.phase = "WAIT_CONTROL"
                AHT.deadline = t + 6.50
            end
        end
    elseif AHT.phase == "WAIT_CONTROL" then
        if not AHT.awaiting then
            return
        end
        if t >= AHT.deadline then
            out("CONTROL_TIMEOUT - nie mozna wiarygodnie kontynuowac")
            stop()
        end
    elseif AHT.phase == "WAIT_CHALLENGE" then
        if t >= AHT.challengeAt then
            local interval = AHT.tests[AHT.index]
            local controlRtt = AHT.controlRtt or 0.25
            local fastLimit = controlRtt * 4 + 0.25
            if fastLimit < 1.25 then fastLimit = 1.25 end
            if fastLimit > 2.00 then fastLimit = 2.00 end

            AHT.results[AHT.index] = {
                interval = interval,
                canSendAtSend = canSend(),
                response = false,
                latency = nil,
                rows = 0,
                total = 0,
                fastLimit = fastLimit,
            }

            if sendQuery("challenge") then
                AHT.phase = "WAIT_CHALLENGE_RESULT"
                AHT.deadline = t + 6.50
            end
        end
    elseif AHT.phase == "WAIT_CHALLENGE_RESULT" then
        if not AHT.awaiting then
            return
        end
        if t >= AHT.deadline then
            local r = AHT.results[AHT.index]
            if r then
                r.response = false
                r.latency = nil
            end
            AHT.awaiting = nil
            out("NO_RESPONSE challenge interval=" .. fmt(AHT.tests[AHT.index]) .. "s")
            AHT.phase = "WAIT_RECOVERY"
            AHT.deadline = t + 0.25
        end
    elseif AHT.phase == "WAIT_RECOVERY" then
        -- Start the next controlled pair only after the stock client gate is open
        -- again. This prevents one failed challenge from contaminating the next case.
        if t >= AHT.deadline and canSend() == true then
            nextCase()
        end
    end
end)

SLASH_AHTHROTTLETEST1 = "/ahtest"
SlashCmdList["AHTHROTTLETEST"] = function(msg)
    msg = string.lower(msg or "")
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")
    if msg == "" or msg == "status" then
        status()
    elseif msg == "start" or msg == "quick" then
        start()
    elseif msg == "stop" then
        stop()
    elseif msg == "help" then
        out("/ahtest start | stop | status")
    else
        out("nieznana komenda; /ahtest help")
    end
end

out("loaded. Otworz AH i wpisz /ahtest start")
