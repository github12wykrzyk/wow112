-- WoW112 Operator Console bridge for SummonScout / WoW 1.12.1 / Lua 5.0.
-- Transport only: observes the existing whisper flow and accepts a narrowly typed
-- manual-whisper command. It does not own summon parsing, invites, payment logic,
-- login/world protocol, AH logic or any economic mutation.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local OB_VERSION = "1"
local OB_MAX_EVENTS = 128
local OB = H.GetState("operatorbridge")
OB.queue = OB.queue or {}
OB.seq = tonumber(OB.seq) or 0
OB.dropped = tonumber(OB.dropped) or 0
OB.pendingManual = OB.pendingManual or {}
OB.lastCommandSeq = tonumber(OB.lastCommandSeq) or 0

local function obTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function obLower(s)
    return string.lower(obTrim(s or ""))
end

local function obFindDecisionApi(fn, depth)
    if type(fn) ~= "function" or depth > 3 then return nil end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
    local i
    for i = 1, 32 do
        local ok, name, value
        if pcall then
            ok, name, value = pcall(debug.getupvalue, fn, i)
            if not ok then return nil end
        else
            name, value = debug.getupvalue(fn, i)
        end
        if not name then break end
        if type(value) == "table" and type(value.whisperInviteDecision) == "function" then
            return value
        end
    end
    for i = 1, 32 do
        local ok, name, value
        if pcall then
            ok, name, value = pcall(debug.getupvalue, fn, i)
            if not ok then return nil end
        else
            name, value = debug.getupvalue(fn, i)
        end
        if not name then break end
        if type(value) == "function" then
            local found = obFindDecisionApi(value, depth + 1)
            if found then return found end
        end
    end
    return nil
end

local function obDecision(message)
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript then
        return false, "", "parser-unavailable"
    end
    local api = obFindDecisionApi(frame:GetScript("OnEvent"), 0)
    if not api or type(api.whisperInviteDecision) ~= "function" then
        return false, "", "parser-unavailable"
    end
    if pcall then
        local ok, accepted, loc, reason = pcall(api.whisperInviteDecision, message or "")
        if not ok then return false, "", "parser-error" end
        return accepted and true or false, tostring(loc or ""), tostring(reason or "")
    end
    local accepted, loc, reason = api.whisperInviteDecision(message or "")
    return accepted and true or false, tostring(loc or ""), tostring(reason or "")
end

local function obQueue(kind, player, text, result, destination, intent, reason, correlation, summonRequest)
    OB.seq = OB.seq + 1
    local item = {
        seq = OB.seq,
        kind = tonumber(kind) or 0,
        character = UnitName and tostring(UnitName("player") or "") or "",
        player = obTrim(player or ""),
        text = tostring(text or ""),
        result = tostring(result or ""),
        destination = tostring(destination or ""),
        intent = tostring(intent or ""),
        keywords = "",
        matchedRule = "",
        reason = tostring(reason or ""),
        correlation = tostring(correlation or ""),
        confidenceMilli = 0,
        competition = false,
        summonRequest = summonRequest and true or false
    }
    table.insert(OB.queue, item)
    while table.getn(OB.queue) > OB_MAX_EVENTS do
        table.remove(OB.queue, 1)
        OB.dropped = OB.dropped + 1
    end
end

local function obSet(name, value)
    setglobal(name, tostring(value or ""))
end

local function obPop()
    local item = table.remove(OB.queue, 1)
    if not item then
        obSet("W112_OPERATOR_EVT_SEQ", "0")
        obSet("W112_OPERATOR_EVT_DROPPED", OB.dropped)
        return false
    end
    obSet("W112_OPERATOR_EVT_SEQ", item.seq)
    obSet("W112_OPERATOR_EVT_KIND", item.kind)
    obSet("W112_OPERATOR_EVT_CHARACTER", item.character)
    obSet("W112_OPERATOR_EVT_PLAYER", item.player)
    obSet("W112_OPERATOR_EVT_TEXT", item.text)
    obSet("W112_OPERATOR_EVT_RESULT", item.result)
    obSet("W112_OPERATOR_EVT_DESTINATION", item.destination)
    obSet("W112_OPERATOR_EVT_INTENT", item.intent)
    obSet("W112_OPERATOR_EVT_KEYWORDS", item.keywords)
    obSet("W112_OPERATOR_EVT_MATCHED_RULE", item.matchedRule)
    obSet("W112_OPERATOR_EVT_REASON", item.reason)
    obSet("W112_OPERATOR_EVT_CORRELATION", item.correlation)
    obSet("W112_OPERATOR_EVT_CONFIDENCE", item.confidenceMilli)
    obSet("W112_OPERATOR_EVT_COMPETITION", item.competition and 1 or 0)
    obSet("W112_OPERATOR_EVT_SUMMON_REQUEST", item.summonRequest and 1 or 0)
    obSet("W112_OPERATOR_EVT_DROPPED", OB.dropped)
    return true
end

local function obHexNibble(c)
    local b = string.byte(c or "") or -1
    if b >= 48 and b <= 57 then return b - 48 end
    if b >= 65 and b <= 70 then return b - 55 end
    if b >= 97 and b <= 102 then return b - 87 end
    return -1
end

local function obDecodeHex(hex)
    hex = tostring(hex or "")
    if math.mod(string.len(hex), 2) ~= 0 then return nil end
    local out = ""
    local i
    for i = 1, string.len(hex), 2 do
        local hi = obHexNibble(string.sub(hex, i, i))
        local lo = obHexNibble(string.sub(hex, i + 1, i + 1))
        if hi < 0 or lo < 0 then return nil end
        out = out .. string.char(hi * 16 + lo)
    end
    return out
end

local function obValidPlayer(player)
    local n = string.len(player or "")
    if n < 1 or n > 63 then return false end
    local i
    for i = 1, n do
        local b = string.byte(player, i)
        if not b or b < 33 or b == 127 or b == 124 then return false end
    end
    return true
end

local function obCommandAck(seq, status, err)
    OB.lastCommandSeq = tonumber(seq) or OB.lastCommandSeq
    obSet("W112_OPERATOR_CMD_ACK_SEQ", seq)
    obSet("W112_OPERATOR_CMD_ACK_STATUS", status)
    obSet("W112_OPERATOR_CMD_ACK_ERROR", err or "")
end

local function obReceive(seq, playerHex, textHex, correlationHex)
    seq = tonumber(seq) or 0
    if seq <= 0 then
        obCommandAck(seq, 3, "invalid sequence")
        return false
    end
    if seq == OB.lastCommandSeq then
        return true
    end

    local player = obDecodeHex(playerHex)
    local text = obDecodeHex(textHex)
    local correlation = obDecodeHex(correlationHex) or ""
    if not player or not obValidPlayer(player) then
        obCommandAck(seq, 3, "invalid player")
        return false
    end
    if not text or string.len(text) < 1 or string.len(text) > 240 then
        obCommandAck(seq, 3, "invalid whisper length")
        return false
    end
    if string.find(text, "|", 1, true) then
        obCommandAck(seq, 3, "literal pipe is unsafe in WoW chat")
        return false
    end
    if type(SendChatMessage) ~= "function" then
        obCommandAck(seq, 3, "SendChatMessage unavailable")
        return false
    end

    if H.ManualChatLock then H.ManualChatLock(player, true) end
    local ok, err = true, nil
    if pcall then
        ok, err = pcall(SendChatMessage, text, "WHISPER", nil, player)
    else
        SendChatMessage(text, "WHISPER", nil, player)
    end
    if not ok then
        obCommandAck(seq, 3, tostring(err or "SendChatMessage failed"))
        return false
    end

    OB.pendingManual[obLower(player)] = {
        seq = seq,
        text = text,
        correlation = correlation,
        at = GetTime and GetTime() or 0
    }
    obCommandAck(seq, 2, "")
    return true
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    W112_OPERATOR_BRIDGE_POP = obPop
    W112_OPERATOR_BRIDGE_RECEIVE = obReceive
    W112_OPERATOR_BRIDGE_VERSION = OB_VERSION
    obSet("W112_OPERATOR_CMD_ACK_SEQ", 0)
    obSet("W112_OPERATOR_CMD_ACK_STATUS", 0)
    obSet("W112_OPERATOR_CMD_ACK_ERROR", "")
end

function M.Shutdown()
    if W112_OPERATOR_BRIDGE_POP == obPop then W112_OPERATOR_BRIDGE_POP = nil end
    if W112_OPERATOR_BRIDGE_RECEIVE == obReceive then W112_OPERATOR_BRIDGE_RECEIVE = nil end
end

function M.OnEvent(ev, a1, a2)
    if ev == "CHAT_MSG_WHISPER" then
        local message = a1 or ""
        local sender = obTrim(a2 or "")
        if sender == "" then return end
        local accepted, loc, reason = obDecision(message)
        obQueue(1, sender, message,
            accepted and "accepted" or "rejected",
            loc,
            accepted and "summon_request" or "",
            reason,
            "",
            accepted)
        return
    end

    if ev == "CHAT_MSG_WHISPER_INFORM" then
        local message = a1 or ""
        local player = obTrim(a2 or "")
        if player == "" then return end
        local key = obLower(player)
        local pending = OB.pendingManual[key]
        if pending and pending.text == message then
            OB.pendingManual[key] = nil
            obQueue(2, player, message, "sent", "", "manual", "", pending.correlation, false)
        else
            obQueue(3, player, message, "sent", "", "automation", "", "", false)
        end
    end
end

function M.OnUpdate()
    local t = GetTime and GetTime() or 0
    local key, pending
    for key, pending in pairs(OB.pendingManual) do
        if type(pending) ~= "table" or t - (tonumber(pending.at) or t) > 30 then
            OB.pendingManual[key] = nil
        end
    end
end

H.Register("operatorbridge", M, OB_VERSION)
