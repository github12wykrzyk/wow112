-- Tiny slash-command compatibility/query shim. It shares the single TELE10
-- ledger storage/API and adds convenient retrospective payment lookup without
-- becoming a second settlement writer.
local Q = CreateFrame("Frame", "SummonScoutTradePaymentLedgerQueryFrame")
Q:RegisterEvent("PLAYER_LOGIN")

local function qTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function qLower(s)
    return string.lower(qTrim(s or ""))
end

local function qSame(a, b)
    local aa = qLower(a)
    local bb = qLower(b)
    return aa ~= "" and aa == bb
end

local function qChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffTELE10 Ledger:|r " .. tostring(text or ""))
    end
end

local function qClock(ts)
    ts = tonumber(ts) or 0
    if ts > 0 and date then return date("%H:%M", ts) end
    return ts > 0 and tostring(ts) or "-"
end

local function qMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < 0 then copper = 0 end
    local g = math.floor(copper / 10000)
    local s = math.floor(math.mod(copper, 10000) / 100)
    local c = math.mod(copper, 100)
    if g > 0 then return tostring(g) .. "g " .. tostring(s) .. "s " .. tostring(c) .. "c" end
    if s > 0 then return tostring(s) .. "s " .. tostring(c) .. "c" end
    return tostring(c) .. "c"
end

local function qCheckPlayer(rest)
    local _, _, who, minutesText = string.find(qTrim(rest), "^(%S+)%s*(%d*)$")
    if not who or who == "" then
        qChat("use: /ssledger check <player> [minutes]")
        return
    end

    local minutes = tonumber(minutesText)
    if minutes and minutes <= 0 then minutes = nil end
    local cutoff = nil
    if minutes and time then cutoff = time() - (minutes * 60) end

    local db = SummonScoutDB and SummonScoutDB.tele10Ledger or nil
    local list = db and db.summons or nil
    if type(list) ~= "table" then
        qChat("CHECK " .. who .. " | NO_LEDGER")
        return
    end

    local found = nil
    local i
    for i = table.getn(list), 1, -1 do
        local rec = list[i]
        if type(rec) == "table" and qSame(rec.client_name, who) then
            local created = tonumber(rec.timestamp_created) or 0
            if not cutoff or created >= cutoff then
                found = rec
                break
            end
        end
    end

    if not found then
        qChat("CHECK " .. who .. " | NO_MATCH" .. (minutes and (" in last " .. tostring(minutes) .. "m") or ""))
        return
    end

    local status = string.upper(tostring(found.payment_status or "unpaid"))
    local paid = status == "PAID" or status == "OVERPAID"
    qChat("CHECK " .. tostring(found.client_name or who)
        .. " | paid=" .. (paid and "YES" or "NO")
        .. " | status=" .. status
        .. " | summon=" .. qClock(found.timestamp_summoned or found.timestamp_created)
        .. " | payment=" .. qClock(found.payment_timestamp)
        .. " | amount=" .. qMoney(found.amount_paid_copper)
        .. " / " .. qMoney(found.expected_price_copper)
        .. " | dest=" .. tostring(found.destination or "?")
        .. " | id=" .. tostring(found.summon_id or "-"))
end

Q:SetScript("OnEvent", function()
    local base = SlashCmdList and SlashCmdList["TELE10LEDGER"] or nil
    local api = W112_TELE10_LEDGER_V1
    if type(base) ~= "function" or type(api) ~= "table" or type(api.ShowSummons) ~= "function" then return end
    SlashCmdList["TELE10LEDGER"] = function(msg)
        msg = qTrim(msg)
        local _, _, cmd, rest = string.find(msg, "^(%S*)%s*(.-)$")
        cmd = qLower(cmd or "")
        rest = qTrim(rest or "")
        if cmd == "check" then
            qCheckPlayer(rest)
            return
        end
        if cmd == "partial" and qLower(rest) ~= "on" and qLower(rest) ~= "off" then
            api.ShowSummons("partial", tonumber(rest) or 10, nil)
            return
        end
        base(msg)
    end
end)
