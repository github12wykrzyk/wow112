-- SummonScout grouped-customer resume hotfix for WoW 1.12.1 / Lua 5.0.
--
-- Core SummonScout intentionally ignores CHAT_MSG_WHISPER from players already
-- in party/raid because its normal path is an invite path. That means a customer
-- who ignored/missed the first portal cannot say "123" / "k summon" to request
-- another Ritual after joining. This hot module keeps the invite path unchanged
-- and only rearms the existing party summon state machine for grouped customers.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-grouped-resume"
local S = H.GetState("groupedresume")
S.deferred = S.deferred or {}
S.lastHoldAckAt = S.lastHoldAckAt or {}
S.api = nil
S.apiProbeAt = tonumber(S.apiProbeAt) or 0
S.apiProbeFailedReported = S.apiProbeFailedReported and true or false

local function grNow()
    if GetTime then return GetTime() end
    return 0
end

local function grTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function grLower(s)
    return string.lower(s or "")
end

local function grNormalize(s)
    s = grLower(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return grTrim(s)
end

local function grKey(name)
    return grLower(grTrim(name or ""))
end

local function grSamePlayer(a, b)
    local ka = grKey(a)
    return ka ~= "" and ka == grKey(b)
end

local function grInGroup(name)
    local i
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if grSamePlayer(UnitName("party" .. i), name) then return true end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(i)
            if grSamePlayer(raidName, name) then return true end
        end
    end
    return false
end

local function grPhraseHas(s, phrase)
    local p = grNormalize(phrase)
    if p == "" then return false end
    return string.find(" " .. s .. " ", " " .. p .. " ", 1, true) ~= nil
end

local HOLD_PHRASES = {
    "wait", "wait a sec", "wait sec", "one sec", "hold on", "brb",
    "not yet", "one quest", "finish quest", "let me turn", "let me finish",
    "give me a min", "give me a minute", "1 min", "2 min", "3 min",
    "one minute", "a minute", "later"
}

local RESUME_EXACT = {
    ["123"] = true,
    ["summon"] = true,
    ["k summon"] = true,
    ["ok summon"] = true,
    ["okay summon"] = true,
    ["summon me"] = true,
    ["sum me"] = true,
    ["go"] = true,
    ["go ahead"] = true,
    ["ready"] = true,
    ["rdy"] = true,
    ["ready now"] = true,
    ["ready to summon"] = true,
    ["ready for summon"] = true,
    ["now"] = true,
    ["here"] = true,
    ["sure"] = true
}

local NEGATIVE_RESUME = {
    "dont summon", "do not summon", "no summon", "not ready", "not now",
    "dont yet", "do not yet", "later"
}

local function grIsHold(message)
    local s = grNormalize(message)
    if s == "" then return false end
    local i
    for i = 1, table.getn(HOLD_PHRASES) do
        if grPhraseHas(s, HOLD_PHRASES[i]) then return true end
    end
    return false
end

local function grHasNegativeResume(s)
    local i
    for i = 1, table.getn(NEGATIVE_RESUME) do
        if grPhraseHas(s, NEGATIVE_RESUME[i]) then return true end
    end
    return false
end

local function grDebugGetUpvalue(fn, index)
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
        return nil, nil
    end
    if pcall then
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if ok then return name, value end
        return nil, nil
    end
    return debug.getupvalue(fn, index)
end

local function grFindApiInFunction(fn, depth, seen)
    if type(fn) ~= "function" or depth > 5 then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true

    local i
    for i = 1, 40 do
        local name, value = grDebugGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "table"
            and type(value.queuePartySummon) == "function"
            and type(value.isInGroup) == "function"
            and type(value.whisperInviteDecision) == "function" then
            return value
        end
    end

    for i = 1, 40 do
        local name, value = grDebugGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "function" then
            local found = grFindApiInFunction(value, depth + 1, seen)
            if found then return found end
        end
    end
    return nil
end

local function grResolveCoreApi(force)
    if not force and type(S.api) == "table" and type(S.api.queuePartySummon) == "function" then
        return S.api
    end

    local t = grNow()
    if not force and t < (S.apiProbeAt or 0) then return nil end
    S.apiProbeAt = t + 2.0

    local frame = SummonScoutFrame
    if not frame or not frame.GetScript then return nil end
    local handler = frame:GetScript("OnEvent")
    local api = grFindApiInFunction(handler, 0, {})
    if api then
        S.api = api
        S.apiProbeFailedReported = false
        return api
    end
    return nil
end

local function grCoreAcceptsResume(api, message)
    if type(api) ~= "table" or type(api.whisperInviteDecision) ~= "function" then
        return false
    end
    if pcall then
        local ok, accepted = pcall(api.whisperInviteDecision, message or "")
        return ok and accepted and true or false
    end
    local accepted = api.whisperInviteDecision(message or "")
    return accepted and true or false
end

local function grIsResume(api, message)
    local s = grNormalize(message)
    if s == "" or grHasNegativeResume(s) or grIsHold(message) then return false end
    if RESUME_EXACT[s] then return true end
    if grPhraseHas(s, "please summon") or grPhraseHas(s, "pls summon")
        or grPhraseHas(s, "summon pls") or grPhraseHas(s, "summon please")
        or grPhraseHas(s, "can you summon") or grPhraseHas(s, "could you summon")
        or grPhraseHas(s, "ready when you are") or grPhraseHas(s, "ready whenever you are") then
        return true
    end
    return grCoreAcceptsResume(api, message)
end

local function grSendHoldAck(sender)
    if not SendChatMessage then return end
    local key = grKey(sender)
    local t = grNow()
    local last = tonumber(S.lastHoldAckAt[key]) or -100000
    if (t - last) < 15 then return end
    S.lastHoldAckAt[key] = t
    SendChatMessage("Sure - whisper 123 when you're ready.", "WHISPER", nil, sender)
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    grResolveCoreApi(true)
end

function M.OnEvent(ev, message, sender)
    if ev ~= "CHAT_MSG_WHISPER" then return end
    if not SummonScoutDB or not SummonScoutDB.enabled
        or not SummonScoutDB.whisperAutoInvite
        or not SummonScoutDB.partyAutoSummon then
        return
    end

    sender = grTrim(sender or "")
    if sender == "" or grSamePlayer(sender, UnitName("player")) or not grInGroup(sender) then
        return
    end

    local key = grKey(sender)
    if grIsHold(message) then
        if not S.deferred[key] then
            S.deferred[key] = true
            grSendHoldAck(sender)
        end
        return
    end

    local api = grResolveCoreApi(false)
    if not api then
        if SummonScoutDB.debug and not S.apiProbeFailedReported then
            S.apiProbeFailedReported = true
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout grouped resume:|r core API unavailable")
            end
        end
        return
    end

    if not grIsResume(api, message) then return end

    S.deferred[key] = nil
    api.queuePartySummon(sender)
    if SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout grouped resume:|r " .. sender .. " -> " .. grNormalize(message))
    end
end

function M.Shutdown()
    S.api = nil
end

H.Register("groupedresume", M, VERSION)
W112_SUMMONSCOUT_GROUPED_RESUME_VERSION = VERSION
