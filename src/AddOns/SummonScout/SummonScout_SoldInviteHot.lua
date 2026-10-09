-- SummonScout exact customer-acceptance whisper invite hotfix for WoW 1.12.1 / Lua 5.0.
--
-- Live customer shorthand uses very short replies such as `sold` and `pls` as
-- explicit acceptance of the summon service. Treat only normalized exact
-- whitelisted replies as invite requests. Longer conversational text containing
-- these words is intentionally ignored.
-- All actual mutation/blacklist/dedupe/service guards remain in the canonical
-- core tryWhisperInvite path.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "2-exact-sold-pls-invite"
local S = H.GetState("soldinvite")

local EXACT_INVITE_REPLIES = {
    ["sold"] = true,
    ["pls"] = true,
}

local function siTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function siNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return siTrim(s)
end

local function siSamePlayer(a, b)
    a = string.lower(siTrim(a or ""))
    b = string.lower(siTrim(b or ""))
    return a ~= "" and a == b
end

local function siTryInvite(sender)
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.whisperAutoInvite then
        return false, "disabled"
    end

    local state = W112_SUMMONSCOUT_STATE
    if type(state) == "table" and state.shardGuardPaused then
        return false, "shard-guard"
    end

    sender = siTrim(sender or "")
    if sender == "" or siSamePlayer(sender, UnitName and UnitName("player") or "") then
        return false, "invalid-sender"
    end

    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.tryWhisperInvite) ~= "function" then
        return false, "api-unavailable"
    end

    local invited, reason
    if pcall then
        local ok
        ok, invited, reason = pcall(api.tryWhisperInvite, sender, nil)
        if not ok then return false, "api-error" end
    else
        invited, reason = api.tryWhisperInvite(sender, nil)
    end
    return invited and true or false, reason
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    W112_SUMMONSCOUT_SOLD_INVITE_VERSION = VERSION
end

function M.OnEvent(evt, message, sender)
    if evt ~= "CHAT_MSG_WHISPER" then return end

    local normalized = siNormalize(message)
    if not EXACT_INVITE_REPLIES[normalized] then return end

    local invited, reason = siTryInvite(sender)
    S.lastSender = tostring(sender or "")
    S.lastMessage = tostring(message or "")
    S.lastNormalized = normalized
    S.lastReason = tostring(reason or "")
    S.lastInvited = invited and true or false

    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout shorthand invite:|r "
            .. tostring(sender or "?") .. " [" .. tostring(normalized or "?") .. "] -> "
            .. (invited and "invited" or tostring(reason or "suppressed")))
    end
end

H.Register("soldinvite", M, VERSION)
W112_SUMMONSCOUT_SOLD_INVITE_VERSION = VERSION
