-- SummonScout grouped-customer resume hotfix for WoW 1.12.1 / Lua 5.0.
--
-- Core SummonScout intentionally ignores CHAT_MSG_WHISPER from players already
-- in party/raid because its normal path is an invite path. This module rearms the
-- existing party summon state machine for grouped customers and adds a combat
-- wait state so target-combat failures do not burn the core retry budget.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "2-combat-wait-resume"
local S = H.GetState("groupedresume")
S.deferred = S.deferred or {}
S.lastHoldAckAt = S.lastHoldAckAt or {}
S.combatWait = S.combatWait or {}
S.lastCombatAckAt = S.lastCombatAckAt or {}
S.nextCombatPollAt = tonumber(S.nextCombatPollAt) or 0
S.api = nil
S.coreState = nil
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

local function grGroupUnit(name)
    local i
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if grSamePlayer(UnitName("party" .. i), name) then
            return "party" .. i
        end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(i)
            if grSamePlayer(raidName, name) then
                return "raid" .. i
            end
        end
    end
    return nil
end

local function grInGroup(name)
    return grGroupUnit(name) ~= nil
end

local function grTargetInCombat(name)
    local unit = grGroupUnit(name)
    if not unit or not UnitAffectingCombat then return nil end
    return UnitAffectingCombat(unit) and true or false
end

local function grPhraseHas(s, phrase)
    local p = grNormalize(phrase)
    if p == "" then return false end
    return string.find(" " .. s .. " ", " " .. p .. " ", 1, true) ~= nil
end

local function grStartsWithToken(s, token)
    token = grNormalize(token)
    if token == "" then return false end
    return s == token or string.sub(s, 1, string.len(token) + 1) == token .. " "
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

local RESUME_LEAD = {
    "123", "summon", "go", "ready", "rdy", "now", "here", "sure"
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

local function grFindStateInFunction(fn, depth, seen)
    if type(fn) ~= "function" or depth > 4 then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true

    local i
    for i = 1, 40 do
        local name, value = grDebugGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "table"
            and type(value.summonPending) == "table"
            and value.summonActiveAttempts ~= nil
            and value.summonActiveNextAt ~= nil then
            return value
        end
    end

    for i = 1, 40 do
        local name, value = grDebugGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "function" then
            local found = grFindStateInFunction(value, depth + 1, seen)
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
        S.coreState = nil
        S.apiProbeFailedReported = false
        return api
    end
    return nil
end

local function grResolveCoreState(api)
    if type(S.coreState) == "table" and type(S.coreState.summonPending) == "table" then
        return S.coreState
    end
    if type(api) ~= "table" then return nil end

    local candidates = {
        api.retryActiveSummon,
        api.finishActiveSummon,
        api.queuePartySummon
    }
    local i
    for i = 1, table.getn(candidates) do
        local state = grFindStateInFunction(candidates[i], 0, {})
        if state then
            S.coreState = state
            return state
        end
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

    local i
    for i = 1, table.getn(RESUME_LEAD) do
        if grStartsWithToken(s, RESUME_LEAD[i]) then return true end
    end

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

local function grSendCombatAck(sender, still)
    if not SendChatMessage then return end
    local key = grKey(sender)
    local t = grNow()
    local last = tonumber(S.lastCombatAckAt[key]) or -100000
    if (t - last) < 10 then return end
    S.lastCombatAckAt[key] = t
    if still then
        SendChatMessage("Still in combat - I'll retry when you're out.", "WHISPER", nil, sender)
    else
        SendChatMessage("You're in combat - I'll retry when you're out.", "WHISPER", nil, sender)
    end
end

local function grIsCombatError(message)
    local s = grNormalize(message)
    if s == "" then return false end
    return grPhraseHas(s, "target is in combat")
        or grPhraseHas(s, "target in combat")
        or grPhraseHas(s, "in combat")
end

local function grActiveSummonName(api)
    local state = grResolveCoreState(api)
    if not state then return nil, nil end
    local name = grTrim(state.summonActiveName or "")
    if name == "" then return nil, state end
    return name, state
end

local function grBeginCombatWait(api, name)
    name = grTrim(name or "")
    if name == "" or not grInGroup(name) then return false end
    if grTargetInCombat(name) ~= true then return false end

    local key = grKey(name)
    local t = grNow()
    local item = S.combatWait[key]
    if type(item) ~= "table" then
        item = {
            name = name,
            since = t,
            outSince = 0
        }
        S.combatWait[key] = item
        grSendCombatAck(name, false)
    else
        item.name = name
        item.outSince = 0
    end

    S.deferred[key] = nil

    if type(api) == "table" and type(api.finishActiveSummon) == "function" then
        api.finishActiveSummon(name)
    end

    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout combat wait:|r " .. name)
    end
    return true
end

local function grCaptureCombatFailure(api, message)
    if message and not grIsCombatError(message) then return false end

    local name, state = grActiveSummonName(api)
    if not name or not state then return false end

    if not message then
        if not grIsCombatError(state.lastSummonError or "") then return false end
        local lastRequest = tonumber(state.lastSummonRequestAt) or -100000
        if (grNow() - lastRequest) > 6 then return false end
    end

    return grBeginCombatWait(api, name)
end

local function grResumeCombatWait(api, sender)
    local key = grKey(sender)
    local item = S.combatWait[key]
    if type(item) ~= "table" then return false end

    if not grInGroup(sender) then
        S.combatWait[key] = nil
        S.deferred[key] = nil
        return true
    end

    local combat = grTargetInCombat(sender)
    if combat == true then
        S.deferred[key] = nil
        item.outSince = 0
        grSendCombatAck(sender, true)
        return true
    end

    S.combatWait[key] = nil
    S.deferred[key] = nil
    api.queuePartySummon(sender)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout combat resume:|r " .. sender)
    end
    return true
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    H.RegisterEvent("UI_ERROR_MESSAGE")
    H.RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
    grResolveCoreApi(true)
end

function M.OnEvent(ev, message, sender)
    if ev == "UI_ERROR_MESSAGE" or ev == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" then
        local api = grResolveCoreApi(false)
        if api then
            grCaptureCombatFailure(api, message)
        end
        return
    end

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
        S.deferred[key] = true
        grSendHoldAck(sender)
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

    if grResumeCombatWait(api, sender) then return end

    S.deferred[key] = nil
    api.queuePartySummon(sender)
    if SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout grouped resume:|r " .. sender .. " -> " .. grNormalize(message))
    end
end

function M.OnUpdate()
    local t = grNow()
    if t < (S.nextCombatPollAt or 0) then return end
    S.nextCombatPollAt = t + 0.25

    local api = grResolveCoreApi(false)
    if not api then return end

    grCaptureCombatFailure(api, nil)

    local key, item
    for key, item in pairs(S.combatWait) do
        local name = grTrim(item.name or "")
        if name == "" or not grInGroup(name) or (t - (tonumber(item.since) or t)) > 120 then
            S.combatWait[key] = nil
            S.deferred[key] = nil
        elseif not S.deferred[key] then
            local combat = grTargetInCombat(name)
            if combat == false then
                local outSince = tonumber(item.outSince) or 0
                if outSince <= 0 then
                    item.outSince = t
                elseif (t - outSince) >= 1.0 then
                    S.combatWait[key] = nil
                    S.deferred[key] = nil
                    api.queuePartySummon(name)
                    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout combat auto-resume:|r " .. name)
                    end
                end
            else
                item.outSince = 0
            end
        end
    end
end

function M.Shutdown()
    S.api = nil
    S.coreState = nil
end

H.Register("groupedresume", M, VERSION)
W112_SUMMONSCOUT_GROUPED_RESUME_VERSION = VERSION
