-- SummonScout combat-failure customer whisper hotfix for WoW 1.12.1 / Lua 5.0.
--
-- Purpose: make the customer-facing notification reliable when Ritual of Summoning
-- failed because the grouped target was in combat. The existing grouped-resume
-- module already handles explicit "in combat" spell errors, but native AutoSummon
-- can surface the same live failure only as target-failed. This module correlates
-- that native failure with the exact active summon transaction plus live target
-- combat telemetry, then sends one bounded whisper to that customer.
--
-- It does not cast, invite, finish, retry, or mutate payment/queue state. It only
-- adds the missing customer notification and shares groupedresume's ack timestamp
-- so both modules cannot double-whisper the same combat failure.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-native-target-failed-combat-whisper"
local S = H.GetState("combatfailurewhisper")
local G = H.GetState("groupedresume")
S.lastActiveName = S.lastActiveName or ""
S.lastActiveSeq = S.lastActiveSeq or ""
S.lastActiveSeenAt = tonumber(S.lastActiveSeenAt) or 0
S.nextPollAt = tonumber(S.nextPollAt) or 0
S.sent = S.sent or {}
G.lastCombatAckAt = G.lastCombatAckAt or {}

local function cfNow()
    if GetTime then return GetTime() end
    return 0
end

local function cfTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function cfLower(s)
    return string.lower(cfTrim(s))
end

local function cfNormalize(s)
    s = cfLower(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return cfTrim(s)
end

local function cfPhrase(s, phrase)
    s = " " .. cfNormalize(s) .. " "
    phrase = " " .. cfNormalize(phrase) .. " "
    return string.find(s, phrase, 1, true) ~= nil
end

local function cfSame(a, b)
    a = cfLower(a)
    b = cfLower(b)
    return a ~= "" and a == b
end

local function cfGroupUnit(name)
    local i
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if cfSame(UnitName("party" .. i), name) then return "party" .. i end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(i)
            if cfSame(raidName, name) then return "raid" .. i end
        end
    end
    return nil
end

local function cfTargetInCombat(name)
    local unit = cfGroupUnit(name)
    if not unit or not UnitAffectingCombat then return nil end
    return UnitAffectingCombat(unit) and true or false
end

local function cfState()
    if type(W112_SUMMONSCOUT_STATE) == "table" then return W112_SUMMONSCOUT_STATE end
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table" and type(api.state) == "table" then return api.state end
    return nil
end

local function cfRememberActive()
    local state = cfState()
    if type(state) ~= "table" then return nil end
    local name = cfTrim(state.summonActiveName or "")
    if name == "" then return state end
    S.lastActiveName = name
    S.lastActiveSeq = cfTrim(state.summonActiveRequestSeq or "")
    S.lastActiveSeenAt = cfNow()
    return state
end

local function cfCurrentOrRecentTarget()
    local state = cfRememberActive()
    if type(state) == "table" then
        local name = cfTrim(state.summonActiveName or "")
        if name ~= "" then
            return name, cfTrim(state.summonActiveRequestSeq or ""), state
        end
    end
    if cfTrim(S.lastActiveName) ~= "" and (cfNow() - (tonumber(S.lastActiveSeenAt) or 0)) <= 3.0 then
        return S.lastActiveName, S.lastActiveSeq, state
    end
    return nil, nil, state
end

local function cfExplicitCombatError(message)
    local n = cfNormalize(message)
    if n == "" then return false end
    return cfPhrase(n, "target is in combat")
        or cfPhrase(n, "target in combat")
        or cfPhrase(n, "in combat")
end

local function cfFailureKey(name, seq, state)
    seq = cfTrim(seq or "")
    if seq ~= "" then return cfLower(name) .. "|" .. seq end
    local stamp = type(state) == "table" and tonumber(state.lastSummonRequestAt) or nil
    if stamp then return cfLower(name) .. "|t" .. tostring(stamp) end
    return cfLower(name) .. "|recent"
end

local function cfSendOnce(name, seq, state)
    name = cfTrim(name or "")
    if name == "" or not SendChatMessage or not cfGroupUnit(name) then return false end

    local t = cfNow()
    local key = cfFailureKey(name, seq, state)
    if S.sent[key] then return false end

    local playerKey = cfLower(name)
    local sharedLast = tonumber(G.lastCombatAckAt[playerKey]) or -100000
    if (t - sharedLast) < 10 then
        S.sent[key] = t
        return false
    end

    S.sent[key] = t
    G.lastCombatAckAt[playerKey] = t
    SendChatMessage("Summon failed because you're in combat. Whisper r when you're out and I'll retry.", "WHISPER", nil, name)
    return true
end

local function cfNativeCombatFailure()
    local name, seq, state = cfCurrentOrRecentTarget()
    if not name or type(state) ~= "table" then return false end

    local lastRequest = tonumber(state.lastSummonRequestAt) or -100000
    if (cfNow() - lastRequest) > 6 then return false end
    if cfTargetInCombat(name) ~= true then return false end

    local lastError = cfLower(state.lastSummonError or "")
    local nativeStatus = cfLower(W112_AUTOSUMMON_NATIVE_STATUS or "")
    local requestSeq = cfTrim(state.summonActiveRequestSeq or seq or "")
    local ackSeq = cfTrim(W112_AUTOSUMMON_ACK_SEQ or "")

    if lastError == "target-failed" then
        return cfSendOnce(name, requestSeq, state)
    end
    if nativeStatus == "target-failed" and requestSeq ~= "" and ackSeq == requestSeq then
        return cfSendOnce(name, requestSeq, state)
    end
    return false
end

local function cfCleanup()
    local t = cfNow()
    local key, at
    for key, at in pairs(S.sent) do
        if t - (tonumber(at) or 0) > 180 then S.sent[key] = nil end
    end
end

local M = {}

function M.Init()
    H.RegisterEvent("UI_ERROR_MESSAGE")
    H.RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
    cfRememberActive()
    W112_SUMMONSCOUT_COMBAT_FAILURE_WHISPER_VERSION = VERSION
end

function M.OnEvent(ev, message)
    if ev ~= "UI_ERROR_MESSAGE" and ev ~= "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" then return end
    if not cfExplicitCombatError(message) then return end

    local name, seq, state = cfCurrentOrRecentTarget()
    if not name then return end
    cfSendOnce(name, seq, state)
end

function M.OnUpdate()
    local t = cfNow()
    if t < (tonumber(S.nextPollAt) or 0) then return end
    S.nextPollAt = t + 0.20
    cfRememberActive()
    cfNativeCombatFailure()
    cfCleanup()
end

function M.Shutdown()
end

H.Register("combatfailurewhisper", M, VERSION)
