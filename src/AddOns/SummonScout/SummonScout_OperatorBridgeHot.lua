-- WoW112 Summon Operator Console bridge for SummonScout / WoW 1.12.1 / Lua 5.0.
-- Transport/telemetry only. The canonical SummonScout parser, summon engine and
-- trusted payment ledger remain authoritative. This module observes their state,
-- exposes live events and accepts one narrowly typed manual-whisper command.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local OB_VERSION = "2-summon-telemetry"
local OB_MAX_EVENTS = 128
local OB_MAX_SUMMON_LOG = 1000
local OB_MAX_PAYMENT_LOG = 1000
local OB = H.GetState("operatorbridge")
OB.queue = OB.queue or {}
OB.seq = tonumber(OB.seq) or 0
OB.dropped = tonumber(OB.dropped) or 0
OB.pendingManual = OB.pendingManual or {}
OB.lastCommandSeq = tonumber(OB.lastCommandSeq) or 0
OB.pendingSeen = OB.pendingSeen or {}
OB.paymentSeenCounts = OB.paymentSeenCounts or {}
OB.replayedSummonSeq = tonumber(OB.replayedSummonSeq) or 0
OB.replayedPaymentSeq = tonumber(OB.replayedPaymentSeq) or 0
OB.prevActiveName = OB.prevActiveName or ""
OB.prevActiveStarted = OB.prevActiveStarted and true or false
OB.prevActiveRequestSeq = OB.prevActiveRequestSeq or ""
OB.prevActiveDestination = OB.prevActiveDestination or ""
OB.prevActiveError = OB.prevActiveError or ""

local function obTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function obLower(s)
    return string.lower(obTrim(s or ""))
end

local function obNow()
    if GetTime then return GetTime() end
    return 0
end

local function obWallTime()
    if time then return tonumber(time()) or 0 end
    return 0
end

local function obApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table" then return api end
    return nil
end

local function obCoreState()
    local state = W112_SUMMONSCOUT_STATE
    if type(state) == "table" then return state end
    return nil
end

local function obDestination()
    local api = obApi()
    if api and type(api.summonDestinationLabel) == "function" then
        if pcall then
            local ok, value = pcall(api.summonDestinationLabel)
            if ok then return tostring(value or "") end
        else
            return tostring(api.summonDestinationLabel() or "")
        end
    end
    return ""
end

local function obDecision(message)
    local api = obApi()
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

local function obQueue(kind, player, text, result, destination, intent, reason, correlation, summonRequest, extras)
    extras = type(extras) == "table" and extras or {}
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
        keywords = tostring(extras.keywords or ""),
        matchedRule = tostring(extras.matchedRule or ""),
        reason = tostring(reason or ""),
        correlation = tostring(correlation or ""),
        confidenceMilli = tonumber(extras.confidenceMilli) or 0,
        competition = extras.competition and true or false,
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
    if seq == OB.lastCommandSeq then return true end

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
        at = obNow()
    }
    obCommandAck(seq, 2, "")
    return true
end

local function obEnsureTelemetryTables()
    SummonScoutDB = SummonScoutDB or {}
    if type(SummonScoutDB.operatorSummonLog) ~= "table" then SummonScoutDB.operatorSummonLog = {} end
    if type(SummonScoutDB.operatorPaymentLog) ~= "table" then SummonScoutDB.operatorPaymentLog = {} end
    SummonScoutDB.operatorSummonSeq = tonumber(SummonScoutDB.operatorSummonSeq) or 0
    SummonScoutDB.operatorPaymentSeq = tonumber(SummonScoutDB.operatorPaymentSeq) or 0
end

local function obTrimLog(log, limit)
    while table.getn(log) > limit do table.remove(log, 1) end
end

local function obAppendSummon(eventName, player, destination, reason, requestSeq)
    obEnsureTelemetryTables()
    SummonScoutDB.operatorSummonSeq = SummonScoutDB.operatorSummonSeq + 1
    local entry = {
        id = SummonScoutDB.operatorSummonSeq,
        ts = obWallTime(),
        event = tostring(eventName or ""),
        player = obTrim(player or ""),
        destination = tostring(destination or ""),
        reason = tostring(reason or ""),
        requestSeq = tostring(requestSeq or "")
    }
    table.insert(SummonScoutDB.operatorSummonLog, entry)
    obTrimLog(SummonScoutDB.operatorSummonLog, OB_MAX_SUMMON_LOG)
    return entry
end

local function obFindLastDestination(player)
    obEnsureTelemetryTables()
    local wanted = obLower(player)
    local i
    for i = table.getn(SummonScoutDB.operatorSummonLog), 1, -1 do
        local e = SummonScoutDB.operatorSummonLog[i]
        if type(e) == "table" and e.event == "completed" and obLower(e.player) == wanted then
            return tostring(e.destination or "")
        end
    end
    return ""
end

local function obPaymentFingerprint(ts, player, copper)
    return tostring(tonumber(ts) or 0) .. "\31" .. obLower(player) .. "\31" .. tostring(tonumber(copper) or 0)
end

local function obRebuildPaymentSeen()
    obEnsureTelemetryTables()
    OB.paymentSeenCounts = {}
    local i
    for i = 1, table.getn(SummonScoutDB.operatorPaymentLog) do
        local e = SummonScoutDB.operatorPaymentLog[i]
        if type(e) == "table" then
            local fp = tostring(e.fingerprint or obPaymentFingerprint(e.ts, e.player, e.copper))
            OB.paymentSeenCounts[fp] = (OB.paymentSeenCounts[fp] or 0) + 1
        end
    end
end

local function obScanTrustedPayments()
    obEnsureTelemetryTables()
    local source = SummonScoutDB.paymentLog
    if type(source) ~= "table" then return end
    local occurrences = {}
    local i
    for i = 1, table.getn(source) do
        local p = source[i]
        if type(p) == "table" then
            local ts = tonumber(p.ts) or 0
            local player = obTrim(p.player or "")
            local copper = tonumber(p.copper) or 0
            if player ~= "" and copper > 0 then
                local fp = obPaymentFingerprint(ts, player, copper)
                occurrences[fp] = (occurrences[fp] or 0) + 1
                local known = OB.paymentSeenCounts[fp] or 0
                if occurrences[fp] > known then
                    SummonScoutDB.operatorPaymentSeq = SummonScoutDB.operatorPaymentSeq + 1
                    local e = {
                        id = SummonScoutDB.operatorPaymentSeq,
                        ts = ts,
                        player = player,
                        copper = copper,
                        destination = obFindLastDestination(player),
                        fingerprint = fp
                    }
                    table.insert(SummonScoutDB.operatorPaymentLog, e)
                    obTrimLog(SummonScoutDB.operatorPaymentLog, OB_MAX_PAYMENT_LOG)
                    OB.paymentSeenCounts[fp] = known + 1
                end
            end
        end
    end
end

local function obSummonKind(eventName)
    if eventName == "queued" then return 4 end
    if eventName == "started" then return 5 end
    if eventName == "completed" then return 6 end
    if eventName == "failed" then return 7 end
    return 0
end

local function obReplayTelemetry()
    obEnsureTelemetryTables()
    local i
    for i = 1, table.getn(SummonScoutDB.operatorSummonLog) do
        local e = SummonScoutDB.operatorSummonLog[i]
        local id = type(e) == "table" and tonumber(e.id) or 0
        if id > OB.replayedSummonSeq then
            local kind = obSummonKind(e.event)
            if kind > 0 then
                local summary = "Summon " .. tostring(e.event) .. ": " .. tostring(e.player or "?")
                if tostring(e.destination or "") ~= "" then summary = summary .. " -> " .. tostring(e.destination) end
                obQueue(kind, e.player, summary, e.event, e.destination, "summon", e.reason,
                    "summon:" .. tostring(id), false,
                    { keywords = e.requestSeq, matchedRule = e.ts })
            end
            OB.replayedSummonSeq = id
        end
    end

    for i = 1, table.getn(SummonScoutDB.operatorPaymentLog) do
        local e = SummonScoutDB.operatorPaymentLog[i]
        local id = type(e) == "table" and tonumber(e.id) or 0
        if id > OB.replayedPaymentSeq then
            local copper = tonumber(e.copper) or 0
            obQueue(8, e.player,
                "Payment received: " .. tostring(e.player or "?") .. " -> " .. tostring(copper) .. " copper",
                "paid", e.destination, "payment", "trusted SummonScoutDB.paymentLog",
                "payment:" .. tostring(id), false,
                { keywords = copper, matchedRule = e.ts })
            OB.replayedPaymentSeq = id
        end
    end
end

local function obObservePending(state, destination)
    if type(state.summonPending) ~= "table" then return end
    local key, item
    for key, item in pairs(state.summonPending) do
        if type(item) == "table" then
            local player = obTrim(item.name or key or "")
            local queuedAt = tonumber(item.queuedAt) or 0
            local signature = obLower(player) .. ":" .. tostring(queuedAt)
            if player ~= "" and not OB.pendingSeen[signature] then
                OB.pendingSeen[signature] = obNow()
                obAppendSummon("queued", player, destination, "canonical summonPending", "")
            end
        end
    end
end

local function obObserveActive(state, destination)
    local active = obTrim(state.summonActiveName or "")
    local started = state.summonActiveStarted and true or false
    local requestSeq = tostring(state.summonActiveRequestSeq or "")
    local err = tostring(state.lastSummonError or "")

    if OB.prevActiveName ~= "" and active ~= OB.prevActiveName then
        if OB.prevActiveStarted then
            obAppendSummon("completed", OB.prevActiveName, OB.prevActiveDestination, "canonical active summon completed", OB.prevActiveRequestSeq)
        else
            local reason = OB.prevActiveError ~= "" and OB.prevActiveError or "canonical active summon ended before cast start"
            obAppendSummon("failed", OB.prevActiveName, OB.prevActiveDestination, reason, OB.prevActiveRequestSeq)
        end
    end

    if active ~= "" and started and (OB.prevActiveName ~= active or not OB.prevActiveStarted) then
        obAppendSummon("started", active, destination, "canonical summonActiveStarted", requestSeq)
    end

    OB.prevActiveName = active
    OB.prevActiveStarted = started
    OB.prevActiveRequestSeq = requestSeq
    OB.prevActiveDestination = active ~= "" and destination or ""
    OB.prevActiveError = err
end

local function obObserveSummons()
    local state = obCoreState()
    if not state then return end
    local destination = obDestination()
    obObservePending(state, destination)
    obObserveActive(state, destination)
end

local function obSweepPendingSeen()
    local t = obNow()
    local key, at
    for key, at in pairs(OB.pendingSeen) do
        if t - (tonumber(at) or t) > 600 then OB.pendingSeen[key] = nil end
    end
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
    obEnsureTelemetryTables()
    obRebuildPaymentSeen()
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
    local t = obNow()
    local key, pending
    for key, pending in pairs(OB.pendingManual) do
        if type(pending) ~= "table" or t - (tonumber(pending.at) or t) > 30 then
            if type(pending) == "table" then
                obQueue(9, key, tostring(pending.text or ""), "uncertain", "", "manual",
                    "no CHAT_MSG_WHISPER_INFORM within 30s; no automatic retry",
                    tostring(pending.correlation or ""), false)
            end
            OB.pendingManual[key] = nil
        end
    end

    obObserveSummons()
    obScanTrustedPayments()
    obReplayTelemetry()
    obSweepPendingSeen()
end

H.Register("operatorbridge", M, OB_VERSION)
