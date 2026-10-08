-- SummonScout Whisper Conversation Relay V1 for WoW 1.12.1 / Lua 5.0.
--
-- P0 goals:
--   * capture every ordinary inbound customer whisper as RAW + NORMALIZED data,
--   * persist conversation/session history in SummonScoutDB,
--   * mirror conversations to the configured Master through guarded control whispers,
--   * let the Master reply through the exact summoner that owns the session,
--   * link canonical invite / roster / Ritual / payment signals into the same history,
--   * fail closed on ambiguous, stale, unauthorised or cross-owned reply targets.
--
-- This module does not replace SummonScout parsing, routing, summon lifecycle, payment
-- accounting, queueing or native coordination.  It consumes canonical public state.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-whisper-conversation-relay"
local R = H.GetState("whisperrelay")
R.inboundRecent = R.inboundRecent or {}
R.pendingMasterOut = R.pendingMasterOut or {}
R.pendingInboundChunks = R.pendingInboundChunks or {}
R.pendingReplyChunks = R.pendingReplyChunks or {}
R.relayQueue = R.relayQueue or {}
R.groupState = R.groupState or {}
R.replyNonceSeq = tonumber(R.replyNonceSeq) or 0
R.nextMaintenanceAt = tonumber(R.nextMaintenanceAt) or 0
R.nextHelloAt = tonumber(R.nextHelloAt) or 0
R.nextLifecyclePollAt = tonumber(R.nextLifecyclePollAt) or 0
R.lastInviteSignature = R.lastInviteSignature or ""
R.activeRitualSessionId = R.activeRitualSessionId or nil
R.masterReady = R.masterReady and true or false
R.masterReadyName = R.masterReadyName or ""

local PROTO = "[SSWR1]"
local EXISTING_CONTROL_PREFIX = "[SSFR1]"
local EXISTING_MASTER_PREFIX = "[SSI "
local MAX_CONTROL = 235
local CHUNK_SIZE = 110
local MAX_CUSTOMER_REPLY = 220
local DUPLICATE_WINDOW = 0.80
local SESSION_REUSE_TTL = 1800
local ACTIVE_TTL = 1800
local COMPLETE_TTL = 600
local SESSION_LIMIT = 220
local EVENT_LIMIT = 140
local PAYMENT_SEEN_LIMIT = 500
local CHUNK_TTL = 15
local HELLO_INTERVAL = 5
local TRUST_TTL = 65
local RELAY_QUEUE_LIMIT = 80

local function wrNow()
    if GetTime then return GetTime() end
    return 0
end

local function wrWall()
    if time then return time() end
    return 0
end

local function wrTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function wrLower(s)
    return string.lower(wrTrim(s or ""))
end

local function wrSame(a, b)
    a = wrLower(a)
    b = wrLower(b)
    return a ~= "" and a == b
end

local function wrPlayer()
    return wrTrim(UnitName and UnitName("player") or "")
end

local function wrMaster()
    return wrTrim(SummonScoutDB and SummonScoutDB.masterName or "")
end

local function wrNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return wrTrim(s)
end

local function wrPhrase(normalized, phrase)
    normalized = " " .. wrNormalize(normalized) .. " "
    phrase = " " .. wrNormalize(phrase) .. " "
    return string.find(normalized, phrase, 1, true) ~= nil
end

local function wrStarts(raw, prefix)
    raw = tostring(raw or "")
    prefix = tostring(prefix or "")
    return prefix ~= "" and string.sub(raw, 1, string.len(prefix)) == prefix
end

local function wrValidName(name)
    name = wrTrim(name)
    if name == "" or string.len(name) > 32 then return false end
    if string.find(name, "[%c%s:;,=|]") then return false end
    return true
end

local function wrChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonRelay:|r " .. tostring(text or ""))
    end
end

local function wrClock(ts)
    ts = tonumber(ts) or wrWall()
    if date and ts > 0 then
        local ok, value
        if pcall then
            ok, value = pcall(date, "%H:%M", ts)
            if ok and value then return value end
        else
            return date("%H:%M", ts)
        end
    end
    return tostring(ts)
end

local function wrFormatMoney(copper)
    copper = tonumber(copper) or 0
    local g = math.floor(copper / 10000)
    local s = math.floor(math.mod(copper, 10000) / 100)
    local c = math.mod(copper, 100)
    if g > 0 then return tostring(g) .. "g" .. tostring(s) .. "s" .. tostring(c) .. "c" end
    if s > 0 then return tostring(s) .. "s" .. tostring(c) .. "c" end
    return tostring(c) .. "c"
end

local function wrEnsureDb()
    SummonScoutDB = SummonScoutDB or {}
    if type(SummonScoutDB.whisperRelayV1) ~= "table" then SummonScoutDB.whisperRelayV1 = {} end
    local D = SummonScoutDB.whisperRelayV1
    D.version = 1
    D.nextSessionSeq = tonumber(D.nextSessionSeq) or 0
    if type(D.sessions) ~= "table" then D.sessions = {} end
    if type(D.sessionOrder) ~= "table" then D.sessionOrder = {} end
    if type(D.knownSummoners) ~= "table" then D.knownSummoners = {} end
    if type(D.trustedSummoners) ~= "table" then D.trustedSummoners = {} end
    if type(D.seenPayments) ~= "table" then D.seenPayments = {} end
    if type(D.seenPaymentOrder) ~= "table" then D.seenPaymentOrder = {} end
    return D
end

local function wrServiceDestination()
    local service = wrLower(SummonScoutDB and SummonScoutDB.service or "")
    if service == "" or service == "all" then return "" end
    local _, _, first = string.find(service, "^%s*([^,]+)")
    return wrTrim(first or service)
end

local function wrResolveDestination(raw)
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table" and type(api.FindLocation) == "function" then
        local ok, loc
        if pcall then
            ok, loc = pcall(api.FindLocation, raw)
            if ok and type(loc) == "table" then
                return wrLower(loc.id or loc.label or "")
            end
        else
            loc = api.FindLocation(raw)
            if type(loc) == "table" then return wrLower(loc.id or loc.label or "") end
        end
    end
    return wrServiceDestination()
end

local function wrIntent(raw)
    local n = wrNormalize(raw)
    if n == "" then return "UNKNOWN" end

    if n == "ty" or n == "thx" or n == "thanks" or n == "thank you"
        or wrPhrase(n, "thank you") then
        return "THANKS"
    end
    if wrPhrase(n, "wait") or wrPhrase(n, "one sec") or wrPhrase(n, "sec")
        or wrPhrase(n, "brb") or wrPhrase(n, "relog") or wrPhrase(n, "relogging") then
        return "WAIT"
    end
    if n == "ready" or n == "here" or wrPhrase(n, "im ready") or wrPhrase(n, "i am ready") then
        return "READY"
    end
    if wrPhrase(n, "my alt") or wrPhrase(n, "my friend") or wrPhrase(n, "another")
        or wrPhrase(n, "second summon") or wrPhrase(n, "summon my") then
        return "SECOND_SUMMON"
    end
    if wrPhrase(n, "how much") or wrPhrase(n, "price") or wrPhrase(n, "cost")
        or wrPhrase(n, "pay") or wrPhrase(n, "fee") then
        return "PAYMENT_QUESTION"
    end
    if wrPhrase(n, "where") or wrPhrase(n, "which destination") or wrPhrase(n, "locations")
        or wrPhrase(n, "where to") then
        return "DESTINATION_QUESTION"
    end

    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table" and type(api.whisperInviteDecision) == "function" then
        local ok, accept
        if pcall then
            ok, accept = pcall(api.whisperInviteDecision, raw)
            if ok and accept then return "SUMMON_REQUEST" end
        else
            accept = api.whisperInviteDecision(raw)
            if accept then return "SUMMON_REQUEST" end
        end
    end

    if wrPhrase(n, "summon") or wrPhrase(n, "summ") or wrPhrase(n, "invite")
        or wrPhrase(n, "inv") or wrPhrase(n, "need one") or n == "123" then
        return "SUMMON_REQUEST"
    end
    return "UNKNOWN"
end

local function wrEscape(s)
    s = tostring(s or "")
    s = string.gsub(s, "%%", "%%25")
    s = string.gsub(s, ":", "%%3A")
    s = string.gsub(s, "|", "%%7C")
    s = string.gsub(s, "\r", "%%0D")
    s = string.gsub(s, "\n", "%%0A")
    return s
end

local function wrUnescape(s)
    s = tostring(s or "")
    s = string.gsub(s, "%%0A", "\n")
    s = string.gsub(s, "%%0D", "\r")
    s = string.gsub(s, "%%7[Cc]", "|")
    s = string.gsub(s, "%%3[Aa]", ":")
    s = string.gsub(s, "%%25", "%%")
    return s
end

local function wrEncodedChunks(raw, maxEncoded)
    raw = tostring(raw or "")
    maxEncoded = tonumber(maxEncoded) or CHUNK_SIZE
    local chunks = {}
    local current = ""
    local currentEncoded = 0
    local i
    for i = 1, string.len(raw) do
        local ch = string.sub(raw, i, i)
        local encodedLen = string.len(wrEscape(ch))
        if current ~= "" and (currentEncoded + encodedLen) > maxEncoded then
            chunks[table.getn(chunks) + 1] = current
            current = ""
            currentEncoded = 0
        end
        current = current .. ch
        currentEncoded = currentEncoded + encodedLen
    end
    if current ~= "" or table.getn(chunks) == 0 then
        chunks[table.getn(chunks) + 1] = current
    end
    return chunks
end

local function wrSplit(raw)
    local result = {}
    local startAt = 1
    raw = tostring(raw or "")
    while true do
        local at = string.find(raw, ":", startAt, true)
        if not at then
            result[table.getn(result) + 1] = string.sub(raw, startAt)
            break
        end
        result[table.getn(result) + 1] = string.sub(raw, startAt, at - 1)
        startAt = at + 1
    end
    return result
end

local function wrPacket(code, fields)
    local text = PROTO .. " " .. tostring(code or "")
    local i
    for i = 1, table.getn(fields or {}) do
        text = text .. ":" .. wrEscape(fields[i] or "")
    end
    return text
end

local function wrParsePacket(raw)
    raw = tostring(raw or "")
    if not wrStarts(raw, PROTO) then return nil end
    local rest = wrTrim(string.sub(raw, string.len(PROTO) + 1))
    if rest == "" then return nil end
    local parts = wrSplit(rest)
    local code = parts[1]
    if not code or code == "" then return nil end
    local fields = {}
    local i
    for i = 2, table.getn(parts) do
        fields[table.getn(fields) + 1] = wrUnescape(parts[i])
    end
    return code, fields
end

local function wrSendRawWhisper(target, text)
    target = wrTrim(target)
    text = tostring(text or "")
    if not wrValidName(target) or text == "" or string.len(text) > MAX_CONTROL or not SendChatMessage then
        return false
    end
    if pcall then
        local ok = pcall(SendChatMessage, text, "WHISPER", nil, target)
        return ok and true or false
    end
    SendChatMessage(text, "WHISPER", nil, target)
    return true
end

local function wrSendPacket(target, code, fields)
    local packet = wrPacket(code, fields or {})
    if string.len(packet) > MAX_CONTROL then return false end
    return wrSendRawWhisper(target, packet)
end

local function wrSessionId(summoner, customer)
    local D = wrEnsureDb()
    D.nextSessionSeq = (tonumber(D.nextSessionSeq) or 0) + 1
    local a = string.sub(wrLower(summoner), 1, 8)
    local b = string.sub(wrLower(customer), 1, 8)
    return a .. "-" .. b .. "-" .. tostring(wrWall()) .. "-" .. tostring(D.nextSessionSeq)
end

local function wrTrimOldSessions(D)
    while table.getn(D.sessionOrder) > SESSION_LIMIT do
        local sid = table.remove(D.sessionOrder, 1)
        if sid then D.sessions[sid] = nil end
    end
end

local function wrCreateSession(summoner, customer, destination, sid)
    local D = wrEnsureDb()
    summoner = wrTrim(summoner)
    customer = wrTrim(customer)
    destination = wrLower(destination or "")
    sid = wrTrim(sid or "")
    if sid == "" then sid = wrSessionId(summoner, customer) end
    if type(D.sessions[sid]) == "table" then return D.sessions[sid] end

    local t = wrWall()
    local session = {
        session_id = sid,
        summoner_name = summoner,
        customer_name = customer,
        destination = destination,
        created_at = t,
        last_activity_at = t,
        summon_state = "NONE",
        payment_state = "UNPAID",
        paid_amount = 0,
        status = "ACTIVE",
        event_seq = 0,
        events = {}
    }
    D.sessions[sid] = session
    D.sessionOrder[table.getn(D.sessionOrder) + 1] = sid
    wrTrimOldSessions(D)
    return session
end

local function wrSessionActive(session)
    if type(session) ~= "table" then return false end
    if session.status ~= "ACTIVE" then return false end
    local age = wrWall() - (tonumber(session.last_activity_at) or 0)
    return age >= 0 and age <= ACTIVE_TTL
end

local function wrFindSessions(summoner, customer, activeOnly)
    local D = wrEnsureDb()
    local out = {}
    local i
    for i = table.getn(D.sessionOrder), 1, -1 do
        local session = D.sessions[D.sessionOrder[i]]
        if type(session) == "table"
            and (not summoner or wrSame(session.summoner_name, summoner))
            and (not customer or wrSame(session.customer_name, customer))
            and (not activeOnly or wrSessionActive(session)) then
            out[table.getn(out) + 1] = session
        end
    end
    return out
end

local function wrFindOrCreateLocalSession(customer, destination)
    local me = wrPlayer()
    local matches = wrFindSessions(me, customer, true)
    local session = matches[1]
    if session and (wrWall() - (tonumber(session.last_activity_at) or 0)) <= SESSION_REUSE_TTL then
        if wrTrim(destination) ~= "" then session.destination = wrLower(destination) end
        return session
    end
    return wrCreateSession(me, customer, destination, nil)
end

local function wrAppend(session, kind, data)
    if type(session) ~= "table" then return nil end
    data = data or {}
    if type(session.events) ~= "table" then session.events = {} end
    session.event_seq = (tonumber(session.event_seq) or 0) + 1
    local eventRow = {
        seq = session.event_seq,
        ts = tonumber(data.ts) or wrWall(),
        kind = tostring(kind or "EVENT"),
        raw = data.raw,
        normalized = data.normalized,
        intent = data.intent,
        from = data.from,
        to = data.to,
        destination = data.destination or session.destination,
        value = data.value
    }
    session.events[table.getn(session.events) + 1] = eventRow
    while table.getn(session.events) > EVENT_LIMIT do table.remove(session.events, 1) end
    session.last_activity_at = eventRow.ts
    return eventRow
end

local function wrIsMasterLocal()
    local me = wrPlayer()
    local master = wrMaster()
    return me ~= "" and master ~= "" and wrSame(me, master)
end

local function wrFallbackPeerTrusted(name)
    local F = H.GetState("fallbackrouter")
    local key = wrLower(name)
    if type(F) ~= "table" then return false end
    local peer = type(F.peers) == "table" and F.peers[key] or nil
    if type(peer) == "table" then
        local seen = tonumber(peer.seen) or 0
        if (wrNow() - seen) <= TRUST_TTL then return true end
    end
    local destination, providers
    if type(F.providers) == "table" then
        for destination, providers in pairs(F.providers) do
            local item = type(providers) == "table" and providers[key] or nil
            if type(item) == "table" and (wrNow() - (tonumber(item.seen) or 0)) <= TRUST_TTL then
                return true
            end
        end
    end
    return false
end

local function wrTrustedSummoner(name)
    local D = wrEnsureDb()
    local key = wrLower(name)
    if key == "" then return false end
    if wrSame(name, wrPlayer()) then return true end
    if D.trustedSummoners[key] then return true end
    return wrFallbackPeerTrusted(name)
end

local function wrRememberSummoner(name, services, trusted)
    local D = wrEnsureDb()
    local key = wrLower(name)
    if key == "" then return end
    D.knownSummoners[key] = {
        name = wrTrim(name),
        services = tostring(services or ""),
        last_seen = wrWall(),
        trusted = trusted and true or false
    }
end

local function wrQueueRelay(item)
    R.relayQueue[table.getn(R.relayQueue) + 1] = item
    while table.getn(R.relayQueue) > RELAY_QUEUE_LIMIT do table.remove(R.relayQueue, 1) end
end

local function wrSendInboundRelay(session, eventRow)
    local master = wrMaster()
    if master == "" or wrSame(master, wrPlayer()) then
        wrChat("[" .. tostring(session.summoner_name) .. "] <" .. tostring(session.customer_name) .. ">: " .. tostring(eventRow.raw or ""))
        return true
    end

    local base = {
        session.session_id,
        session.customer_name,
        session.destination or "",
        eventRow.intent or "UNKNOWN",
        session.payment_state or "UNPAID",
        session.summon_state or "NONE",
        tostring(eventRow.seq or 0),
        tostring(eventRow.ts or 0)
    }
    local single = wrPacket("I", {
        base[1], base[2], base[3], base[4], base[5], base[6], base[7], base[8], eventRow.raw or ""
    })

    if not R.masterReady or not wrSame(R.masterReadyName, master) then
        wrQueueRelay({ kind = "INBOUND", session = session, event = eventRow })
        return false
    end

    if string.len(single) <= MAX_CONTROL then
        return wrSendRawWhisper(master, single)
    end

    local chunks = wrEncodedChunks(eventRow.raw or "", CHUNK_SIZE)
    local count = table.getn(chunks)
    if not wrSendPacket(master, "IB", { base[1], base[2], base[3], base[4], base[5], base[6], base[7], base[8], tostring(count) }) then
        return false
    end
    local i
    for i = 1, count do
        if not wrSendPacket(master, "IC", { base[1], tostring(i), chunks[i] }) then return false end
    end
    return true
end

local function wrSendEventRelay(session, eventRow)
    local master = wrMaster()
    if master == "" or wrSame(master, wrPlayer()) then return true end
    if not R.masterReady or not wrSame(R.masterReadyName, master) then
        wrQueueRelay({ kind = "EVENT", session = session, event = eventRow })
        return false
    end
    return wrSendPacket(master, "E", {
        session.session_id,
        session.customer_name,
        session.destination or "",
        tostring(eventRow.seq or 0),
        eventRow.kind or "EVENT",
        tostring(eventRow.ts or 0),
        tostring(eventRow.raw or eventRow.value or "")
    })
end

local function wrFlushRelayQueue()
    if not R.masterReady then return end
    local queued = R.relayQueue
    R.relayQueue = {}
    local i
    for i = 1, table.getn(queued) do
        local item = queued[i]
        if type(item) == "table" and item.session and item.event then
            if item.kind == "INBOUND" then
                wrSendInboundRelay(item.session, item.event)
            elseif item.kind == "EVENT" then
                wrSendEventRelay(item.session, item.event)
            end
        end
    end
end

local function wrInboundDuplicate(sender, raw)
    local key = wrLower(sender) .. "\031" .. tostring(raw or "")
    local t = wrNow()
    local prev = tonumber(R.inboundRecent[key]) or -100000
    R.inboundRecent[key] = t
    return (t - prev) <= DUPLICATE_WINDOW
end

local function wrCaptureCustomer(sender, raw)
    sender = wrTrim(sender)
    raw = tostring(raw or "")
    local me = wrPlayer()
    if not wrValidName(sender) or wrSame(sender, me) then return false end
    if wrInboundDuplicate(sender, raw) then return true end

    local destination = wrResolveDestination(raw)
    local session = wrFindOrCreateLocalSession(sender, destination)
    session.status = "ACTIVE"
    local intent = wrIntent(raw)
    local eventRow = wrAppend(session, "WHISPER_IN", {
        raw = raw,
        normalized = wrNormalize(raw),
        intent = intent,
        from = sender,
        to = me,
        destination = destination
    })
    wrSendInboundRelay(session, eventRow)
    return true
end

local function wrMirrorSession(sid, summoner, customer, destination)
    local D = wrEnsureDb()
    sid = wrTrim(sid)
    local session = sid ~= "" and D.sessions[sid] or nil
    if type(session) ~= "table" then
        session = wrCreateSession(summoner, customer, destination, sid)
    end
    if not wrSame(session.summoner_name, summoner) or not wrSame(session.customer_name, customer) then
        return nil
    end
    if wrTrim(destination) ~= "" then session.destination = wrLower(destination) end
    session.status = "ACTIVE"
    return session
end

local function wrMirrorInbound(sender, fields, rawOverride)
    if not wrTrustedSummoner(sender) then
        wrChat("blocked relay from untrusted summoner " .. tostring(sender))
        return true
    end
    local sid = fields[1] or ""
    local customer = fields[2] or ""
    local destination = fields[3] or ""
    local intent = fields[4] or "UNKNOWN"
    local payment = fields[5] or "UNPAID"
    local summonState = fields[6] or "NONE"
    local seq = tonumber(fields[7]) or 0
    local ts = tonumber(fields[8]) or wrWall()
    local raw = rawOverride
    if raw == nil then raw = fields[9] or "" end
    if sid == "" or not wrValidName(customer) then return true end

    wrRememberSummoner(sender, "", true)
    local session = wrMirrorSession(sid, sender, customer, destination)
    if not session then return true end
    session.payment_state = payment
    session.summon_state = summonState
    session.remoteSeen = session.remoteSeen or {}
    local dedupeKey = "I:" .. tostring(seq)
    if session.remoteSeen[dedupeKey] then return true end
    session.remoteSeen[dedupeKey] = true

    local eventRow = wrAppend(session, "WHISPER_IN", {
        ts = ts,
        raw = raw,
        normalized = wrNormalize(raw),
        intent = intent,
        from = customer,
        to = sender,
        destination = destination
    })
    eventRow.remote_seq = seq
    wrChat("[" .. tostring(sender) .. "] <" .. tostring(customer) .. ">: " .. tostring(raw))
    return true
end

local function wrMirrorEvent(sender, fields)
    if not wrTrustedSummoner(sender) then return true end
    local sid = fields[1] or ""
    local customer = fields[2] or ""
    local destination = fields[3] or ""
    local seq = tonumber(fields[4]) or 0
    local kind = fields[5] or "EVENT"
    local ts = tonumber(fields[6]) or wrWall()
    local value = fields[7] or ""
    local session = wrMirrorSession(sid, sender, customer, destination)
    if not session then return true end
    session.remoteSeen = session.remoteSeen or {}
    local dedupeKey = "E:" .. tostring(seq)
    if session.remoteSeen[dedupeKey] then return true end
    session.remoteSeen[dedupeKey] = true

    local eventRow = wrAppend(session, kind, {
        ts = ts,
        from = (kind == "WHISPER_OUT_AUTO" or kind == "WHISPER_OUT_MASTER") and sender or customer,
        to = (kind == "WHISPER_OUT_AUTO" or kind == "WHISPER_OUT_MASTER") and customer or sender,
        destination = destination,
        raw = ((kind == "WHISPER_OUT_AUTO" or kind == "WHISPER_OUT_MASTER") and value or nil),
        value = ((kind == "WHISPER_OUT_AUTO" or kind == "WHISPER_OUT_MASTER") and nil or value)
    })
    eventRow.remote_seq = seq
    if kind == "PAID" then
        local copper = tonumber(value) or 0
        session.payment_state = "PAID"
        session.paid_amount = (tonumber(session.paid_amount) or 0) + copper
    elseif kind == "SUMMON_START" then
        session.summon_state = "STARTED"
    elseif kind == "SUMMON_OK" then
        session.summon_state = "OK"
    elseif kind == "SUMMON_FAIL" then
        session.summon_state = "FAILED"
    elseif kind == "INVITE" then
        session.summon_state = "INVITED"
    elseif kind == "JOIN" then
        session.summon_state = "JOINED"
    end
    return true
end

local function wrChunkBegin(sender, fields)
    if not wrTrustedSummoner(sender) then return true end
    local sid = fields[1] or ""
    local count = tonumber(fields[9]) or 0
    if sid == "" or count < 1 or count > 20 then return true end
    R.pendingInboundChunks[sid] = {
        sender = sender,
        fields = fields,
        count = count,
        chunks = {},
        started = wrNow()
    }
    return true
end

local function wrChunkPart(sender, fields)
    local sid = fields[1] or ""
    local index = tonumber(fields[2]) or 0
    local chunk = fields[3] or ""
    local pending = R.pendingInboundChunks[sid]
    if type(pending) ~= "table" or not wrSame(pending.sender, sender) then return true end
    if index < 1 or index > pending.count then return true end
    pending.chunks[index] = chunk
    local i
    for i = 1, pending.count do
        if pending.chunks[i] == nil then return true end
    end
    local raw = ""
    for i = 1, pending.count do raw = raw .. pending.chunks[i] end
    R.pendingInboundChunks[sid] = nil
    return wrMirrorInbound(sender, pending.fields, raw)
end

local function wrFindExactOwnedSession(sid, customer, destination)
    local D = wrEnsureDb()
    local session = D.sessions[wrTrim(sid)]
    if type(session) ~= "table" then return nil, "unknown-session" end
    if not wrSame(session.summoner_name, wrPlayer()) then return nil, "wrong-summoner-owner" end
    if not wrSame(session.customer_name, customer) then return nil, "wrong-customer-owner" end
    if wrTrim(destination) ~= "" and wrTrim(session.destination) ~= "" and not wrSame(session.destination, destination) then
        return nil, "destination-mismatch"
    end
    if not wrSessionActive(session) then return nil, "session-not-active" end
    return session, nil
end

local function wrExecuteMasterReply(sender, fields)
    local master = wrMaster()
    if master == "" or not wrSame(sender, master) then
        wrChat("blocked unauthorised reply relay from " .. tostring(sender))
        return true
    end
    local sid = fields[1] or ""
    local customer = fields[2] or ""
    local destination = fields[3] or ""
    local nonce = fields[4] or ""
    local text = fields[5] or ""
    if nonce == "" or string.len(text) > MAX_CUSTOMER_REPLY then return true end
    R.seenReplyNonce = R.seenReplyNonce or {}
    if R.seenReplyNonce[nonce] then return true end

    local session, reason = wrFindExactOwnedSession(sid, customer, destination)
    if not session then
        wrChat("reply blocked: " .. tostring(reason))
        return true
    end
    if not wrValidName(customer) or wrSame(customer, wrPlayer()) or wrSame(customer, master) then
        wrChat("reply blocked: invalid/self target")
        return true
    end

    R.seenReplyNonce[nonce] = wrWall()
    local key = wrLower(customer) .. "\031" .. tostring(text)
    R.pendingMasterOut[key] = { sid = sid, at = wrNow(), nonce = nonce }
    if not wrSendRawWhisper(customer, text) then
        R.pendingMasterOut[key] = nil
        wrChat("reply send failed without retry: " .. tostring(customer))
        return true
    end
    return true
end

local function wrReplyChunkBegin(sender, fields)
    local master = wrMaster()
    if master == "" or not wrSame(sender, master) then return true end
    local nonce = fields[4] or ""
    local count = tonumber(fields[5]) or 0
    if nonce == "" or count < 1 or count > 20 then return true end
    R.pendingReplyChunks[nonce] = {
        sender = sender,
        sid = fields[1] or "",
        customer = fields[2] or "",
        destination = fields[3] or "",
        nonce = nonce,
        count = count,
        chunks = {},
        started = wrNow()
    }
    return true
end

local function wrReplyChunkPart(sender, fields)
    local nonce = fields[1] or ""
    local index = tonumber(fields[2]) or 0
    local pending = R.pendingReplyChunks[nonce]
    if type(pending) ~= "table" or not wrSame(sender, pending.sender) then return true end
    if index < 1 or index > pending.count then return true end
    pending.chunks[index] = fields[3] or ""
    local i
    for i = 1, pending.count do if pending.chunks[i] == nil then return true end end
    local text = ""
    for i = 1, pending.count do text = text .. pending.chunks[i] end
    R.pendingReplyChunks[nonce] = nil
    return wrExecuteMasterReply(sender, {
        pending.sid, pending.customer, pending.destination, pending.nonce, text
    })
end

local function wrHandleControl(sender, code, fields)
    local master = wrMaster()
    if code == "K" then
        if master ~= "" and wrSame(sender, master) then
            R.masterReady = true
            R.masterReadyName = sender
            wrFlushRelayQueue()
        end
        return true
    end

    if code == "H" then
        if not wrTrustedSummoner(sender) then
            return true
        end
        wrRememberSummoner(sender, fields[1] or "", true)
        wrSendPacket(sender, "K", { wrPlayer() })
        return true
    end

    if code == "I" then return wrMirrorInbound(sender, fields, nil) end
    if code == "IB" then return wrChunkBegin(sender, fields) end
    if code == "IC" then return wrChunkPart(sender, fields) end
    if code == "E" then return wrMirrorEvent(sender, fields) end
    if code == "R" then return wrExecuteMasterReply(sender, fields) end
    if code == "RB" then return wrReplyChunkBegin(sender, fields) end
    if code == "RC" then return wrReplyChunkPart(sender, fields) end
    return true
end

local function wrIsReservedControl(raw)
    return wrStarts(raw, PROTO) or wrStarts(raw, EXISTING_CONTROL_PREFIX) or wrStarts(raw, EXISTING_MASTER_PREFIX)
end

local function wrHandleWhisper(raw, sender)
    raw = tostring(raw or "")
    sender = wrTrim(sender)
    if wrStarts(raw, PROTO) then
        local code, fields = wrParsePacket(raw)
        if code then
            local master = wrMaster()
            local senderIsMaster = master ~= "" and wrSame(sender, master)
            local senderIsTrustedSummoner = wrTrustedSummoner(sender)
            if senderIsMaster or senderIsTrustedSummoner then
                return wrHandleControl(sender, code, fields)
            end
            -- Reserved-protocol-looking text from an ordinary customer is not executed.
            -- It remains an ordinary RAW customer whisper so capture is parser-independent.
            wrChat("blocked unauthorised control-like whisper from " .. tostring(sender))
            return wrCaptureCustomer(sender, raw)
        end
    end

    if wrStarts(raw, EXISTING_CONTROL_PREFIX) or wrStarts(raw, EXISTING_MASTER_PREFIX) then
        -- Canonical internal control/report traffic must never enter customer transcripts.
        return true
    end
    return wrCaptureCustomer(sender, raw)
end

local function wrHandleWhisperInform(raw, target)
    raw = tostring(raw or "")
    target = wrTrim(target)
    if wrIsReservedControl(raw) then return true end
    if not wrValidName(target) then return true end
    local matches = wrFindSessions(wrPlayer(), target, true)
    if table.getn(matches) ~= 1 then return true end
    local session = matches[1]
    local key = wrLower(target) .. "\031" .. raw
    local pending = R.pendingMasterOut[key]
    local kind = "WHISPER_OUT_AUTO"
    if type(pending) == "table" and pending.sid == session.session_id and (wrNow() - (tonumber(pending.at) or 0)) <= 4 then
        kind = "WHISPER_OUT_MASTER"
        R.pendingMasterOut[key] = nil
    end
    local eventRow = wrAppend(session, kind, {
        raw = raw,
        normalized = wrNormalize(raw),
        from = wrPlayer(),
        to = target,
        destination = session.destination
    })
    wrSendEventRelay(session, eventRow)
    return true
end

local function wrAppendLifecycle(customer, kind, destination, value)
    customer = wrTrim(customer)
    if not wrValidName(customer) then return nil end
    local matches = wrFindSessions(wrPlayer(), customer, true)
    local session = matches[1]
    if not session then session = wrFindOrCreateLocalSession(customer, destination or wrServiceDestination()) end
    if destination and destination ~= "" then session.destination = wrLower(destination) end
    if kind == "INVITE" then session.summon_state = "INVITED" end
    if kind == "JOIN" then session.summon_state = "JOINED" end
    if kind == "SUMMON_START" then session.summon_state = "STARTED" end
    if kind == "SUMMON_OK" then session.summon_state = "OK" end
    if kind == "SUMMON_FAIL" then session.summon_state = "FAILED" end
    if kind == "PAID" then
        session.payment_state = "PAID"
        session.paid_amount = (tonumber(session.paid_amount) or 0) + (tonumber(value) or 0)
    end
    local row = wrAppend(session, kind, {
        from = customer,
        to = wrPlayer(),
        destination = session.destination,
        value = value
    })
    wrSendEventRelay(session, row)
    return session
end

local function wrPaymentSeen(signature)
    local D = wrEnsureDb()
    if D.seenPayments[signature] then return true end
    D.seenPayments[signature] = true
    D.seenPaymentOrder[table.getn(D.seenPaymentOrder) + 1] = signature
    while table.getn(D.seenPaymentOrder) > PAYMENT_SEEN_LIMIT do
        local old = table.remove(D.seenPaymentOrder, 1)
        if old then D.seenPayments[old] = nil end
    end
    return false
end

local function wrSeedExistingPayments()
    local D = wrEnsureDb()
    if D.paymentSeeded then return end
    local log = SummonScoutDB and SummonScoutDB.paymentLog
    if type(log) == "table" then
        local i
        for i = 1, table.getn(log) do
            local item = log[i]
            if type(item) == "table" then
                local signature = tostring(item.ts or 0) .. "|" .. wrLower(item.player or "") .. "|" .. tostring(item.copper or 0)
                wrPaymentSeen(signature)
            end
        end
    end
    D.paymentSeeded = true
end

local function wrPollPayments()
    local log = SummonScoutDB and SummonScoutDB.paymentLog
    if type(log) ~= "table" then return end
    local i
    for i = 1, table.getn(log) do
        local item = log[i]
        if type(item) == "table" then
            local signature = tostring(item.ts or 0) .. "|" .. wrLower(item.player or "") .. "|" .. tostring(item.copper or 0)
            if not wrPaymentSeen(signature) then
                wrAppendLifecycle(item.player or "", "PAID", nil, tonumber(item.copper) or 0)
            end
        end
    end
end

local function wrPollInvite()
    local state = W112_SUMMONSCOUT_STATE
    if type(state) ~= "table" then return end
    local name = wrTrim(state.lastInvitedName or "")
    if name == "" then return end
    local at = tonumber(state.lastInvitedAt) or 0
    local destination = tostring(state.lastInvitedLocation or wrServiceDestination())
    local signature = wrLower(name) .. "|" .. tostring(at) .. "|" .. wrLower(destination)
    if signature ~= R.lastInviteSignature then
        R.lastInviteSignature = signature
        wrAppendLifecycle(name, "INVITE", destination, nil)
    end
end

local function wrInGroup(name)
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.isInGroup) ~= "function" then return false end
    if pcall then
        local ok, grouped = pcall(api.isInGroup, name)
        return ok and grouped and true or false
    end
    return api.isInGroup(name) and true or false
end

local function wrPollGroups()
    local D = wrEnsureDb()
    local i
    for i = table.getn(D.sessionOrder), 1, -1 do
        local session = D.sessions[D.sessionOrder[i]]
        if type(session) == "table" and wrSame(session.summoner_name, wrPlayer()) and wrSessionActive(session) then
            local key = session.session_id
            local grouped = wrInGroup(session.customer_name)
            if R.groupState[key] == nil then
                R.groupState[key] = grouped
            elseif grouped and not R.groupState[key] then
                R.groupState[key] = true
                wrAppendLifecycle(session.customer_name, "JOIN", session.destination, nil)
            elseif not grouped then
                R.groupState[key] = false
            end
        end
    end
end

local function wrRitualCustomer()
    local state = W112_SUMMONSCOUT_STATE
    if type(state) ~= "table" then return "" end
    return wrTrim(state.summonActiveName or "")
end

local function wrHandleSpellEvent(eventName, spellName)
    spellName = tostring(spellName or "")
    if eventName == "SPELLCAST_START" then
        if spellName ~= "" and string.find(wrLower(spellName), "ritual of summoning", 1, true) == nil then return end
        local customer = wrRitualCustomer()
        if customer == "" then return end
        local session = wrAppendLifecycle(customer, "SUMMON_START", nil, nil)
        R.activeRitualSessionId = session and session.session_id or nil
        return
    end
    if eventName == "SPELLCAST_STOP" then
        local sid = R.activeRitualSessionId
        R.activeRitualSessionId = nil
        if not sid then return end
        local D = wrEnsureDb()
        local session = D.sessions[sid]
        if type(session) == "table" then wrAppendLifecycle(session.customer_name, "SUMMON_OK", session.destination, nil) end
        return
    end
    if eventName == "SPELLCAST_FAILED" or eventName == "SPELLCAST_INTERRUPTED" then
        local sid = R.activeRitualSessionId
        R.activeRitualSessionId = nil
        if not sid then return end
        local D = wrEnsureDb()
        local session = D.sessions[sid]
        if type(session) == "table" then wrAppendLifecycle(session.customer_name, "SUMMON_FAIL", session.destination, spellName) end
    end
end

local function wrExpireSessions()
    local D = wrEnsureDb()
    local t = wrWall()
    local i
    for i = 1, table.getn(D.sessionOrder) do
        local session = D.sessions[D.sessionOrder[i]]
        if type(session) == "table" and session.status == "ACTIVE" then
            local age = t - (tonumber(session.last_activity_at) or 0)
            if age > ACTIVE_TTL then
                if session.payment_state == "PAID" or session.summon_state == "OK" then
                    session.status = "COMPLETED"
                else
                    session.status = "EXPIRED"
                end
            elseif age > COMPLETE_TTL and session.payment_state == "PAID" and session.summon_state == "OK" then
                session.status = "COMPLETED"
            end
        end
    end
end

local function wrCleanupRuntime()
    local t = wrNow()
    local key, at
    for key, at in pairs(R.inboundRecent) do
        if (t - (tonumber(at) or 0)) > 5 then R.inboundRecent[key] = nil end
    end
    local item
    for key, item in pairs(R.pendingMasterOut) do
        if type(item) ~= "table" or (t - (tonumber(item.at) or 0)) > 6 then R.pendingMasterOut[key] = nil end
    end
    for key, item in pairs(R.pendingInboundChunks) do
        if type(item) ~= "table" or (t - (tonumber(item.started) or 0)) > CHUNK_TTL then R.pendingInboundChunks[key] = nil end
    end
    for key, item in pairs(R.pendingReplyChunks) do
        if type(item) ~= "table" or (t - (tonumber(item.started) or 0)) > CHUNK_TTL then R.pendingReplyChunks[key] = nil end
    end
end

local function wrHello()
    local master = wrMaster()
    local me = wrPlayer()
    if master == "" or me == "" or wrSame(master, me) then return end
    local services = tostring(SummonScoutDB and SummonScoutDB.service or "")
    wrSendPacket(master, "H", { services })
end

local function wrKnownSummoner(name)
    local D = wrEnsureDb()
    return type(D.knownSummoners[wrLower(name)]) == "table" or D.trustedSummoners[wrLower(name)] ~= nil
end

local function wrKnownCustomer(name)
    return table.getn(wrFindSessions(nil, name, false)) > 0
end

local function wrActiveMasterSessions()
    local D = wrEnsureDb()
    local out = {}
    local i
    for i = table.getn(D.sessionOrder), 1, -1 do
        local session = D.sessions[D.sessionOrder[i]]
        if type(session) == "table" and wrSessionActive(session) then
            out[table.getn(out) + 1] = session
        end
    end
    return out
end

local function wrReplyNonce()
    R.replyNonceSeq = (tonumber(R.replyNonceSeq) or 0) + 1
    return wrLower(wrPlayer()) .. "-" .. tostring(wrWall()) .. "-" .. tostring(R.replyNonceSeq)
end

local function wrSendReplyControl(session, text)
    text = tostring(text or "")
    if type(session) ~= "table" then return false, "unknown-session" end
    if not wrSessionActive(session) then return false, "session-not-active" end
    if string.len(text) < 1 or string.len(text) > MAX_CUSTOMER_REPLY then return false, "reply-length" end
    if not wrValidName(session.summoner_name) or not wrValidName(session.customer_name) then return false, "invalid-owner" end
    if wrSame(session.summoner_name, wrPlayer()) then
        local nonce = wrReplyNonce()
        wrExecuteMasterReply(wrPlayer(), {
            session.session_id, session.customer_name, session.destination or "", nonce, text
        })
        return true, nil
    end
    if not wrTrustedSummoner(session.summoner_name) then return false, "summoner-not-trusted" end

    local nonce = wrReplyNonce()
    local fields = {
        session.session_id, session.customer_name, session.destination or "", nonce, text
    }
    local packet = wrPacket("R", fields)
    if string.len(packet) <= MAX_CONTROL then
        if not wrSendRawWhisper(session.summoner_name, packet) then return false, "control-send-failed" end
        return true, nil
    end

    local chunks = wrEncodedChunks(text, CHUNK_SIZE)
    local count = table.getn(chunks)
    if not wrSendPacket(session.summoner_name, "RB", {
        session.session_id, session.customer_name, session.destination or "", nonce, tostring(count)
    }) then return false, "control-begin-failed" end
    local i
    for i = 1, count do
        if not wrSendPacket(session.summoner_name, "RC", { nonce, tostring(i), chunks[i] }) then
            return false, "control-chunk-failed"
        end
    end
    return true, nil
end

local function wrPrintCandidates(sessions)
    local i
    for i = 1, table.getn(sessions) do
        local s = sessions[i]
        wrChat(tostring(s.session_id) .. " | " .. tostring(s.summoner_name) .. " -> "
            .. tostring(s.customer_name) .. " | " .. tostring(s.destination or "?") .. " | "
            .. tostring(s.payment_state or "UNPAID") .. " | " .. tostring(s.summon_state or "NONE"))
    end
end

local function wrShowSession(session)
    if type(session) ~= "table" then wrChat("session not found"); return end
    wrChat(tostring(session.session_id) .. " | " .. tostring(session.summoner_name) .. " / "
        .. tostring(session.customer_name) .. " / " .. tostring(session.destination or "?") .. " / "
        .. tostring(session.payment_state or "UNPAID") .. " " .. wrFormatMoney(session.paid_amount or 0))
    local events = session.events or {}
    local first = table.getn(events) - 19
    if first < 1 then first = 1 end
    local i
    for i = first, table.getn(events) do
        local e = events[i]
        local text = e.raw or e.value or ""
        wrChat(wrClock(e.ts) .. " " .. tostring(e.kind) .. " " .. tostring(text))
    end
end

local function wrSlash(message)
    message = wrTrim(message)
    if message == "" then
        local active = wrActiveMasterSessions()
        if table.getn(active) == 1 then
            wrChat("active: " .. tostring(active[1].summoner_name) .. " -> " .. tostring(active[1].customer_name))
        else
            wrChat("usage: /ssr <Summoner> <Customer> <reply> | /ssr <reply> | /ssr list | /ssr show <session_id>")
        end
        return
    end

    local _, _, cmd, rest = string.find(message, "^(%S+)%s*(.*)$")
    local lowerCmd = wrLower(cmd)
    if lowerCmd == "list" then
        local active = wrActiveMasterSessions()
        if table.getn(active) == 0 then wrChat("no active conversations") else wrPrintCandidates(active) end
        return
    end
    if lowerCmd == "show" then
        local D = wrEnsureDb()
        wrShowSession(D.sessions[wrTrim(rest)])
        return
    end
    if lowerCmd == "close" then
        local D = wrEnsureDb()
        local s = D.sessions[wrTrim(rest)]
        if type(s) ~= "table" then wrChat("session not found"); return end
        s.status = "CLOSED"
        s.last_activity_at = wrWall()
        wrChat("closed " .. tostring(s.session_id))
        return
    end
    if lowerCmd == "trust" then
        local name = wrTrim(rest)
        if not wrValidName(name) then wrChat("invalid summoner"); return end
        local D = wrEnsureDb()
        D.trustedSummoners[wrLower(name)] = name
        wrRememberSummoner(name, "manual", true)
        wrChat("trusted summoner " .. name)
        return
    end
    if lowerCmd == "untrust" then
        local name = wrTrim(rest)
        local D = wrEnsureDb()
        D.trustedSummoners[wrLower(name)] = nil
        wrChat("removed explicit trust for " .. name)
        return
    end

    local _, _, first, second, remainder = string.find(message, "^(%S+)%s+(%S+)%s+(.+)$")
    local explicit = false
    if first and second and remainder then
        if wrKnownSummoner(first) or wrKnownCustomer(second) then explicit = true end
    end

    if explicit then
        local matches = wrFindSessions(first, second, true)
        if table.getn(matches) ~= 1 then
            wrChat("explicit reply blocked: expected exactly one ACTIVE owned conversation; found " .. tostring(table.getn(matches)))
            local candidates = wrActiveMasterSessions()
            wrPrintCandidates(candidates)
            return
        end
        local ok, reason = wrSendReplyControl(matches[1], remainder)
        if ok then
            wrChat("reply routed as " .. tostring(matches[1].summoner_name) .. " -> " .. tostring(matches[1].customer_name))
        else
            wrChat("reply blocked: " .. tostring(reason))
        end
        return
    end

    local active = wrActiveMasterSessions()
    if table.getn(active) ~= 1 then
        wrChat("shorthand blocked: " .. tostring(table.getn(active)) .. " active conversations")
        wrPrintCandidates(active)
        return
    end
    local ok, reason = wrSendReplyControl(active[1], message)
    if ok then
        wrChat("reply routed as " .. tostring(active[1].summoner_name) .. " -> " .. tostring(active[1].customer_name))
    else
        wrChat("reply blocked: " .. tostring(reason))
    end
end

local M = {}

function M.Init()
    wrEnsureDb()
    wrSeedExistingPayments()
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_WHISPER")
    H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    H.RegisterEvent("SPELLCAST_START")
    H.RegisterEvent("SPELLCAST_STOP")
    H.RegisterEvent("SPELLCAST_FAILED")
    H.RegisterEvent("SPELLCAST_INTERRUPTED")
    H.RegisterEvent("PARTY_MEMBERS_CHANGED")
    H.RegisterEvent("RAID_ROSTER_UPDATE")

    SLASH_SUMMONSCOUTRELAY1 = "/ssr"
    SlashCmdList["SUMMONSCOUTRELAY"] = wrSlash

    R.masterReady = false
    R.masterReadyName = ""
    R.nextHelloAt = 0
    R.nextLifecyclePollAt = 0
    R.nextMaintenanceAt = 0
    W112_SUMMONSCOUT_WHISPER_RELAY_VERSION = VERSION
end

function M.OnEvent(ev, a1, a2, a3)
    if ev == "CHAT_MSG_WHISPER" then
        return wrHandleWhisper(a1 or "", a2 or "")
    end
    if ev == "CHAT_MSG_WHISPER_INFORM" then
        return wrHandleWhisperInform(a1 or "", a2 or "")
    end
    if ev == "SPELLCAST_START" or ev == "SPELLCAST_STOP" or ev == "SPELLCAST_FAILED" or ev == "SPELLCAST_INTERRUPTED" then
        wrHandleSpellEvent(ev, a1 or "")
        return
    end
    if ev == "PLAYER_LOGIN" then
        R.masterReady = false
        R.masterReadyName = ""
        R.nextHelloAt = 0
        R.nextLifecyclePollAt = 0
        return
    end
    if ev == "PARTY_MEMBERS_CHANGED" or ev == "RAID_ROSTER_UPDATE" then
        wrPollGroups()
    end
end

function M.OnUpdate()
    local t = wrNow()
    if t >= (tonumber(R.nextHelloAt) or 0) then
        R.nextHelloAt = t + HELLO_INTERVAL
        wrHello()
    end
    if t >= (tonumber(R.nextLifecyclePollAt) or 0) then
        R.nextLifecyclePollAt = t + 0.25
        wrPollInvite()
        wrPollGroups()
        wrPollPayments()
    end
    if t >= (tonumber(R.nextMaintenanceAt) or 0) then
        R.nextMaintenanceAt = t + 2.0
        wrExpireSessions()
        wrCleanupRuntime()
        wrFlushRelayQueue()
    end
end

function M.Shutdown()
    if SlashCmdList and SlashCmdList["SUMMONSCOUTRELAY"] == wrSlash then
        SlashCmdList["SUMMONSCOUTRELAY"] = nil
    end
end

H.Register("whisperrelay", M, VERSION)
