-- Direct-whisper BUY hotfix for WoW 1.12.1 / Lua 5.0.
-- Exact "buy" inherits this summoner's configured service; "buy <destination>"
-- is routed through the canonical classifier so wrong-destination requests stay blocked.
local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "1-buy-direct-canonical"
local S = H.GetState("whisperbuy")

local function wbTrim(v)
    v = tostring(v or "")
    v = string.gsub(v, "^%s+", "")
    return string.gsub(v, "%s+$", "")
end

local function wbNormalize(v)
    v = string.lower(tostring(v or ""))
    v = string.gsub(v, "|c%x%x%x%x%x%x%x%x", " ")
    v = string.gsub(v, "|r", " ")
    v = string.gsub(v, "|H.-|h(.-)|h", "%1")
    v = string.gsub(v, "[%p%c]", " ")
    v = string.gsub(v, "%s+", " ")
    return wbTrim(v)
end

local function wbTrigger(raw)
    local n = wbNormalize(raw)
    if n == "buy" then return true, true end
    if string.sub(n, 1, 4) == "buy " then return true, false end
    return false, false
end

local function wbResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table"
        or type(api.whisperInviteDecision) ~= "function"
        or type(api.tryWhisperInvite) ~= "function" then
        return nil
    end
    return api
end

local function wbDecision(api, raw, exactBuy)
    local probe = exactBuy and "invite me" or tostring(raw or "")
    if pcall then
        local ok, accept, loc, reason = pcall(api.whisperInviteDecision, probe)
        if not ok then return false, nil, "classifier-error" end
        return accept and true or false, loc, reason
    end
    local accept, loc, reason = api.whisperInviteDecision(probe)
    return accept and true or false, loc, reason
end

local function wbInvite(api, sender, loc)
    if pcall then
        local ok, invited, reason = pcall(api.tryWhisperInvite, sender, loc)
        if not ok then return false, "invite-error" end
        return invited and true or false, reason
    end
    return api.tryWhisperInvite(sender, loc)
end

local function wbDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout buy:|r " .. tostring(text or ""))
    end
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
end

function M.OnEvent(ev, a1, a2)
    if ev ~= "CHAT_MSG_WHISPER" then return end
    local matched, exactBuy = wbTrigger(a1 or "")
    if not matched then return end

    local sender = wbTrim(a2 or "")
    if sender == "" then return end

    local api = wbResolveApi()
    if not api then
        S.lastResult = "api-unavailable"
        return
    end

    local accept, loc, reason = wbDecision(api, a1 or "", exactBuy)
    if not accept then
        S.lastSender = sender
        S.lastRaw = tostring(a1 or "")
        S.lastResult = tostring(reason or "classifier-blocked")
        wbDebug("blocked -> " .. sender .. " [" .. S.lastResult .. "]")
        return
    end

    local invited, inviteReason = wbInvite(api, sender, loc)
    S.lastSender = sender
    S.lastRaw = tostring(a1 or "")
    S.lastResult = tostring(inviteReason or (invited and "invited" or "blocked"))
    if invited then wbDebug("invite -> " .. sender .. " [" .. S.lastRaw .. "]") end
end

function M.Shutdown() end

H.Register("whisperbuy", M, VERSION)
W112_SUMMONSCOUT_WHISPER_BUY_VERSION = VERSION
