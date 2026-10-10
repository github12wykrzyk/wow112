-- SummonScout 1.84: read-only route transport diagnostics for WoW 1.12.1 / Lua 5.0.
--
-- Purpose: distinguish SSFR1 route protocol failures without changing routing semantics.
-- Observes X/A/R submit, CHAT_MSG_WHISPER_INFORM delivery confirmation, inbound control
-- packets, provider freshness at ACK evaluation, and server flood-control messages.
-- No retries, no invites, no route mutation, no payment/summon mutation.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.GetState) ~= "function" then return end

local VERSION = "1"
local PROTO = "[SSFR1]"
local MAX_EVENTS = 50
local F = H.GetState("fallbackrouter")
local R = { hub = nil, provider = nil, installed = false, sendBase = nil, nextTick = 0 }

local function now()
    if GetTime then return GetTime() end
    return 0
end

local function wall()
    if time then return time() end
    return 0
end

local function trim(v)
    local s = tostring(v or "")
    s = string.gsub(s, "^%s+", "")
    return string.gsub(s, "%s+$", "")
end

local function lower(v)
    return string.lower(trim(v))
end

local function player()
    return trim(UnitName and UnitName("player") or "")
end

local function db()
    if not SummonScoutDB then SummonScoutDB = {} end
    if type(SummonScoutDB.routeTransportDiag) ~= "table" then
        SummonScoutDB.routeTransportDiag = {}
    end
    local d = SummonScoutDB.routeTransportDiag
    if type(d.events) ~= "table" then d.events = {} end
    d.version = VERSION
    return d
end

local function short(v, limit)
    local s = tostring(v or "")
    limit = tonumber(limit) or 120
    s = string.gsub(s, "[%c\r\n]", " ")
    if string.len(s) > limit then s = string.sub(s, 1, limit) end
    return s
end

local function push(tag, detail)
    local d = db()
    local events = d.events
    events[table.getn(events) + 1] = {
        t = now(),
        wall = wall(),
        char = player(),
        tag = tostring(tag or "?"),
        detail = short(detail or "", 180)
    }
    while table.getn(events) > MAX_EVENTS do table.remove(events, 1) end
end

local function split(s, delimiter)
    local out = {}
    local startAt = 1
    s = tostring(s or "")
    delimiter = tostring(delimiter or ":")
    while true do
        local at = string.find(s, delimiter, startAt, true)
        if at then
            out[table.getn(out) + 1] = string.sub(s, startAt, at - 1)
            startAt = at + string.len(delimiter)
        else
            out[table.getn(out) + 1] = string.sub(s, startAt)
            break
        end
    end
    return out
end

local function unhex(s)
    s = tostring(s or "")
    if math.mod(string.len(s), 2) ~= 0 or string.find(s, "[^0-9a-fA-F]") then return nil end
    local out = ""
    local i
    for i = 1, string.len(s), 2 do
        local b = tonumber(string.sub(s, i, i + 1), 16)
        if not b then return nil end
        out = out .. string.char(b)
    end
    return out
end

local function control(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local rest = trim(string.sub(raw, string.len(PROTO) + 1))
    local parts = split(rest, ":")
    local code = parts[1]
    if not code or code == "" then return nil end
    local fields = {}
    local i
    for i = 2, table.getn(parts) do
        local v = unhex(parts[i])
        if v == nil then return code, nil end
        fields[table.getn(fields) + 1] = v
    end
    return code, fields
end

local function routeKey(fields)
    if type(fields) ~= "table" then return "" end
    return lower(fields[1] or "") .. "@" .. lower(fields[2] or "")
end

local function markBackground(code)
    if code == "FCV" or code == "FCE" or code == "H" or code == "D" then
        local d = db()
        d.lastBackgroundCode = code
        d.lastBackgroundAt = now()
    end
end

local function bgAgeText()
    local d = db()
    if not d.lastBackgroundAt then return "bg=none" end
    return "bg=" .. tostring(d.lastBackgroundCode or "?") .. "/" .. string.format("%.1fs", now() - (tonumber(d.lastBackgroundAt) or 0))
end

local function observeSubmit(message, chatType, target)
    if tostring(chatType or "") ~= "WHISPER" then return end
    local code, fields = control(message)
    if code then
        markBackground(code)
        if code == "R" or code == "X" or code == "A" or code == "FCV" or code == "FCE" then
            local key = routeKey(fields)
            push("TX_" .. code .. "_SUBMIT", "to=" .. trim(target) .. " key=" .. key .. " fields=" .. tostring(type(fields) == "table" and table.getn(fields) or -1) .. " " .. bgAgeText())
            if code == "X" then
                R.hub = { at = now(), key = key, target = trim(target), xInform = false, aRx = false, flood = false, summary = false }
            elseif code == "A" then
                if not R.provider then R.provider = { at = now(), key = key, xRx = false, aSubmit = false, aInform = false, flood = false, summary = false } end
                R.provider.aSubmit = true
                R.provider.aSubmitAt = now()
            end
        end
        return
    end

    local raw = tostring(message or "")
    if string.sub(raw, 1, 19) == "Got it - checking the" then
        push("TX_CHECK_SUBMIT", "to=" .. trim(target) .. " " .. bgAgeText())
        if R.hub then R.hub.checkSubmitAt = now() end
    end
end

local function installSendObserver()
    if R.installed then return true end
    if type(SendChatMessage) ~= "function" then return false end
    R.sendBase = SendChatMessage
    local base = R.sendBase
    W112_SUMMONSCOUT_ROUTE_DIAG_SEND_WRAPPER = function(message, chatType, language, target)
        if pcall then pcall(observeSubmit, message, chatType, target) else observeSubmit(message, chatType, target) end
        return base(message, chatType, language, target)
    end
    SendChatMessage = W112_SUMMONSCOUT_ROUTE_DIAG_SEND_WRAPPER
    R.installed = true
    push("DIAG_SEND_WRAP", "installed")
    return true
end

local function providerState(destination, sender)
    local providers = type(F.providers) == "table" and F.providers[lower(destination)] or nil
    local item = type(providers) == "table" and providers[lower(sender)] or nil
    if type(item) ~= "table" then return false, -1 end
    return true, now() - (tonumber(item.seen) or 0)
end

local function observeInbound(raw, sender)
    local code, fields = control(raw)
    if not code then return end
    if code ~= "R" and code ~= "X" and code ~= "A" then return end
    local key = routeKey(fields)
    push("RX_" .. code, "from=" .. trim(sender) .. " key=" .. key .. " fields=" .. tostring(type(fields) == "table" and table.getn(fields) or -1))

    if code == "X" then
        R.provider = { at = now(), key = key, xRx = true, aSubmit = false, aInform = false, flood = false, summary = false }
    elseif code == "A" and type(fields) == "table" then
        if R.hub then R.hub.aRx = true; R.hub.aRxAt = now() end
        local pending = type(F.pendingRoute) == "table" and F.pendingRoute[key] or nil
        local fresh, age = providerState(fields[2] or "", sender)
        push("ACK_EVAL", "key=" .. key .. " pending=" .. (type(pending) == "table" and "1" or "0") .. " provider=" .. (fresh and "1" or "0") .. " age=" .. string.format("%.1f", age) .. " origin=" .. trim(fields[3] or "") .. " status=" .. trim(fields[4] or ""))
    end
end

local function observeInform(raw, target)
    local code, fields = control(raw)
    if code then
        if code == "R" or code == "X" or code == "A" then
            local key = routeKey(fields)
            push("INFORM_" .. code, "to=" .. trim(target) .. " key=" .. key)
            if code == "X" and R.hub and R.hub.key == key then R.hub.xInform = true; R.hub.xInformAt = now() end
            if code == "A" and R.provider and R.provider.key == key then R.provider.aInform = true; R.provider.aInformAt = now() end
        end
        return
    end
    local msg = tostring(raw or "")
    if string.sub(msg, 1, 19) == "Got it - checking the" then
        push("INFORM_CHECK", "to=" .. trim(target))
        if R.hub then R.hub.checkInformAt = now() end
    end
end

local function observeFlood(text)
    local s = lower(text)
    if string.find(s, "must wait", 1, true) or string.find(s, "before speaking again", 1, true) then
        push("FLOOD", short(text, 140))
        if R.hub then R.hub.flood = true end
        if R.provider then R.provider.flood = true end
    end
end

local function chat(text)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[SSI ROUTE DIAG]|r " .. tostring(text or "")) end
end

local function summaries()
    local t = now()
    if R.hub and not R.hub.summary and (t - (tonumber(R.hub.at) or t)) >= 6.6 then
        R.hub.summary = true
        local msg = "hub " .. tostring(R.hub.key or "?") .. " Xinform=" .. (R.hub.xInform and "1" or "0") .. " A_rx=" .. (R.hub.aRx and "1" or "0") .. " flood=" .. (R.hub.flood and "1" or "0") .. " " .. bgAgeText()
        push("HUB_SUMMARY", msg)
        chat(msg)
    end
    if R.provider and R.provider.xRx and not R.provider.summary and (t - (tonumber(R.provider.at) or t)) >= 3.6 then
        R.provider.summary = true
        local msg = "provider " .. tostring(R.provider.key or "?") .. " X_rx=1 A_submit=" .. (R.provider.aSubmit and "1" or "0") .. " A_inform=" .. (R.provider.aInform and "1" or "0") .. " flood=" .. (R.provider.flood and "1" or "0") .. " " .. bgAgeText()
        push("PROVIDER_SUMMARY", msg)
        chat(msg)
    end
end

local function dump()
    local events = db().events
    chat("trace events=" .. tostring(table.getn(events)) .. " version=" .. VERSION)
    local first = math.max(1, table.getn(events) - 14)
    local i, e
    for i = first, table.getn(events) do
        e = events[i]
        if type(e) == "table" then
            chat(string.format("%02d %.1f %s %s", i, tonumber(e.t) or 0, tostring(e.tag or "?"), tostring(e.detail or "")))
        end
    end
end

SLASH_SUMMONSCOUTROUTETRACE1 = "/ssroute"
SlashCmdList["SUMMONSCOUTROUTETRACE"] = function(msg)
    if lower(msg) == "clear" then
        db().events = {}
        R.hub = nil
        R.provider = nil
        chat("trace cleared")
        return
    end
    dump()
end

local frame = CreateFrame and CreateFrame("Frame", "SummonScoutRouteTransportDiagFrame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("CHAT_MSG_WHISPER")
    frame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    frame:RegisterEvent("CHAT_MSG_SYSTEM")
    frame:RegisterEvent("UI_ERROR_MESSAGE")
    frame:SetScript("OnEvent", function()
        if event == "PLAYER_LOGIN" then
            push("PLAYER_LOGIN", "diag ready")
            return
        end
        if event == "CHAT_MSG_WHISPER" then
            observeInbound(arg1 or "", arg2 or "")
            return
        end
        if event == "CHAT_MSG_WHISPER_INFORM" then
            observeInform(arg1 or "", arg2 or "")
            return
        end
        if event == "CHAT_MSG_SYSTEM" then
            observeFlood(arg1 or "")
            return
        end
        if event == "UI_ERROR_MESSAGE" then
            observeFlood(tostring(arg1 or "") .. " " .. tostring(arg2 or ""))
        end
    end)
    frame:SetScript("OnUpdate", function()
        local t = now()
        if t < (R.nextTick or 0) then return end
        R.nextTick = t + 0.20
        if not R.installed and t > 0.50 then installSendObserver() end
        summaries()
    end)
end

W112_SUMMONSCOUT_ROUTE_TRANSPORT_DIAG_VERSION = VERSION
