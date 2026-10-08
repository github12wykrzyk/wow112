-- SummonScout Whisper Relay V1 intent guard for WoW 1.12.1 / Lua 5.0.
--
-- The relay deliberately captures RAW text independently of parser success.  This
-- tiny guard makes the optional intent tag equally conservative for long,
-- conversational wait/noise messages: a sentence can contain words such as
-- "wait" or "relogging" without becoming a machine-actionable WAIT intent.
--
-- It wraps only the relay module's CHAT_MSG_WHISPER entry point.  For a message
-- that must remain UNKNOWN it temporarily holds remote relay delivery, lets the
-- canonical relay create its normal persistent event, corrects that event's
-- intent in-place, and then restores delivery readiness.  The queued relay item
-- references the same event table, so Master receives RAW 1:1 with UNKNOWN.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.GetState) ~= "function" or type(H.Register) ~= "function" then
    return
end

local relay = H.modules and H.modules["whisperrelay"] or nil
if type(relay) ~= "table" or type(relay.OnEvent) ~= "function" then
    return
end

local VERSION = "1-conservative-freeform-intent"
local R = H.GetState("whisperrelay")
local oldOnEvent = relay.OnEvent

local function igTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function igNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return igTrim(s)
end

local function igPhrase(n, phrase)
    local hay = " " .. igNormalize(n) .. " "
    local needle = " " .. igNormalize(phrase) .. " "
    return string.find(hay, needle, 1, true) ~= nil
end

local function igWordCount(n)
    local count = 0
    local token
    for token in string.gfind(n, "%S+") do
        count = count + 1
    end
    return count
end

local function igHasDestination(raw)
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.FindLocation) ~= "function" then return false end
    if pcall then
        local ok, loc = pcall(api.FindLocation, raw or "")
        return ok and type(loc) == "table"
    end
    return type(api.FindLocation(raw or "")) == "table"
end

local function igHasRequestCue(n)
    return igPhrase(n, "summon")
        or igPhrase(n, "summ")
        or igPhrase(n, "invite")
        or igPhrase(n, "inv")
        or igPhrase(n, "need one")
        or igPhrase(n, "can i get one")
        or igPhrase(n, "could i get one")
        or igPhrase(n, "123")
end

local function igHasConversationalWaitCue(n)
    return igPhrase(n, "wait")
        or igPhrase(n, "one sec")
        or igPhrase(n, "sec")
        or igPhrase(n, "brb")
        or igPhrase(n, "relog")
        or igPhrase(n, "relogging")
end

local function igMustRemainUnknown(raw)
    local n = igNormalize(raw)
    if n == "" then return false end
    -- Short explicit wait messages remain useful WAIT intents.  Long free-form
    -- sentences are intentionally conservative unless they contain an explicit
    -- summon/invite cue or a canonical destination.
    if igWordCount(n) <= 4 then return false end
    if not igHasConversationalWaitCue(n) then return false end
    if igHasRequestCue(n) then return false end
    if igHasDestination(raw) then return false end
    return true
end

local function igSame(a, b)
    a = string.lower(igTrim(a))
    b = string.lower(igTrim(b))
    return a ~= "" and a == b
end

local function igPlayer()
    return igTrim(UnitName and UnitName("player") or "")
end

local function igPatchLatestInbound(sender, raw)
    local D = SummonScoutDB and SummonScoutDB.whisperRelayV1
    if type(D) ~= "table" or type(D.sessions) ~= "table" or type(D.sessionOrder) ~= "table" then
        return false
    end

    local me = igPlayer()
    local i
    for i = table.getn(D.sessionOrder), 1, -1 do
        local session = D.sessions[D.sessionOrder[i]]
        if type(session) == "table"
            and igSame(session.summoner_name, me)
            and igSame(session.customer_name, sender)
            and type(session.events) == "table" then
            local j
            for j = table.getn(session.events), 1, -1 do
                local eventRow = session.events[j]
                if type(eventRow) == "table"
                    and eventRow.kind == "WHISPER_IN"
                    and tostring(eventRow.raw or "") == tostring(raw or "") then
                    eventRow.intent = "UNKNOWN"
                    return true
                end
                if j < table.getn(session.events) - 3 then break end
            end
        end
    end
    return false
end

local function igWrappedOnEvent(ev, a1, a2, a3)
    if ev ~= "CHAT_MSG_WHISPER" or not igMustRemainUnknown(a1 or "") then
        return oldOnEvent(ev, a1, a2, a3)
    end

    -- Prevent the original relay from sending the event before its optional
    -- intent tag is corrected.  No customer mutation is performed here.
    local wasReady = R.masterReady and true or false
    local wasReadyName = R.masterReadyName
    R.masterReady = false

    local ok, result
    if pcall then
        ok, result = pcall(oldOnEvent, ev, a1, a2, a3)
    else
        oldOnEvent(ev, a1, a2, a3)
        ok = true
    end

    if ok then
        igPatchLatestInbound(a2 or "", a1 or "")
    end

    R.masterReady = wasReady
    R.masterReadyName = wasReadyName

    if not ok then
        error(result)
    end
    return result
end

relay.OnEvent = igWrappedOnEvent

local M = {}

function M.Shutdown()
    if relay and relay.OnEvent == igWrappedOnEvent then
        relay.OnEvent = oldOnEvent
    end
end

H.Register("whisperrelayintentguard", M, VERSION)
