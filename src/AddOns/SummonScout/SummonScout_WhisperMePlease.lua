-- Narrow direct-whisper hotfix for polite destination-less summon requests.
-- WoW 1.12.1 / Lua 5.0. Cold-loaded intentionally: this is stable policy,
-- not part of the HOT fanout payload budget.
local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "1-me-please-direct"
local S = H.GetState("whispermeplease")

local function mpTrim(v)
    v = tostring(v or "")
    v = string.gsub(v, "^%s+", "")
    return string.gsub(v, "%s+$", "")
end

local function mpNormalize(v)
    v = string.lower(tostring(v or ""))
    v = string.gsub(v, "|c%x%x%x%x%x%x%x%x", " ")
    v = string.gsub(v, "|r", " ")
    v = string.gsub(v, "|H.-|h(.-)|h", "%1")
    v = string.gsub(v, "[%p%c]", " ")
    v = string.gsub(v, "%s+", " ")
    return mpTrim(v)
end

local function mpTrigger(raw)
    local n = mpNormalize(raw)
    return n == "me pls" or n == "me plz" or n == "me please"
end

local function mpResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table"
        or type(api.whisperInviteDecision) ~= "function"
        or type(api.tryWhisperInvite) ~= "function" then
        return nil
    end
    return api
end

local function mpDecision(api)
    -- Reuse the canonical classifier with an equivalent explicit direct request.
    -- It preserves service inheritance and destination ownership semantics.
    if pcall then
        local ok, accept, loc, reason = pcall(api.whisperInviteDecision, "invite me")
        if not ok then return false, nil, "classifier-error" end
        return accept and true or false, loc, reason
    end
    local accept, loc, reason = api.whisperInviteDecision("invite me")
    return accept and true or false, loc, reason
end

local function mpInvite(api, sender, loc)
    if pcall then
        local ok, invited, reason = pcall(api.tryWhisperInvite, sender, loc)
        if not ok then return false, "invite-error" end
        return invited and true or false, reason
    end
    return api.tryWhisperInvite(sender, loc)
end

local function mpDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout me-pls:|r " .. tostring(text or ""))
    end
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
end

function M.OnEvent(ev, a1, a2)
    if ev ~= "CHAT_MSG_WHISPER" or not mpTrigger(a1 or "") then return end

    local sender = mpTrim(a2 or "")
    if sender == "" then return end

    local api = mpResolveApi()
    if not api then
        S.lastResult = "api-unavailable"
        mpDebug("blocked -> " .. sender .. " [api-unavailable]")
        return
    end

    local accept, loc, reason = mpDecision(api)
    if not accept then
        S.lastResult = tostring(reason or "classifier-blocked")
        mpDebug("blocked -> " .. sender .. " [" .. S.lastResult .. "]")
        return
    end

    local invited, inviteReason = mpInvite(api, sender, loc)
    S.lastSender = sender
    S.lastRaw = tostring(a1 or "")
    S.lastResult = tostring(inviteReason or (invited and "invited" or "blocked"))
    if invited then
        mpDebug("invite -> " .. sender .. " [" .. S.lastRaw .. "]")
    end
end

function M.Shutdown() end

H.Register("whispermeplease", M, VERSION)
W112_SUMMONSCOUT_WHISPER_ME_PLEASE_VERSION = VERSION
