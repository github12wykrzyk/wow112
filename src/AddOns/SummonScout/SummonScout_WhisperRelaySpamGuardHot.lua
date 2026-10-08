-- SummonScout Whisper Relay spam guard for WoW 1.12.1 / Lua 5.0.
--
-- Keeps the V1 relay transport and session model intact while fixing two live issues:
--   * relay H/K control whispers must not run as a permanent 5-second heartbeat,
--   * [SSWR1] transport packets must not pollute the player's visible whisper chat.
--
-- The guard is intentionally last in TOC. It wraps the already-registered relay
-- module, never replaces canonical summon/payment/routing primitives.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local relay = H.modules and H.modules["whisperrelay"] or nil
if type(relay) ~= "table" or type(relay.OnEvent) ~= "function"
    or type(relay.OnUpdate) ~= "function" then
    return
end

local VERSION = "1-bounded-handshake-hidden-control"
local PROTO = "[SSWR1]"
local HELLO_MAX_IDLE_ATTEMPTS = 3
local HELLO_RETRY_1 = 10
local HELLO_RETRY_2 = 30
local HELLO_QUEUE_RETRY = 60
local HELLO_PARK = 86400

local R = H.GetState("whisperrelay")
local G = H.GetState("whisperrelayspamguard")
G.helloAttempts = tonumber(G.helloAttempts) or 0
G.nextHelloAllowedAt = tonumber(G.nextHelloAllowedAt) or 0
G.lastMasterName = G.lastMasterName or ""

local OWN_RELAY_ON_EVENT = relay.OnEvent
local OWN_RELAY_ON_UPDATE = relay.OnUpdate
local OWN_CHAT_BASE = nil
local OWN_CHAT_WRAPPER = nil

local function sgNow()
    if GetTime then return GetTime() end
    return 0
end

local function sgTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function sgLower(s)
    return string.lower(sgTrim(s or ""))
end

local function sgSame(a, b)
    a = sgLower(a)
    b = sgLower(b)
    return a ~= "" and a == b
end

local function sgStarts(raw, prefix)
    raw = tostring(raw or "")
    return string.sub(raw, 1, string.len(prefix)) == prefix
end

local function sgPlayer()
    return sgTrim(UnitName and UnitName("player") or "")
end

local function sgMaster()
    return sgTrim(SummonScoutDB and SummonScoutDB.masterName or "")
end

local function sgResetHandshake(master)
    G.helloAttempts = 0
    G.nextHelloAllowedAt = 0
    G.lastMasterName = sgTrim(master or sgMaster())
end

local function sgRelayQueued()
    return type(R.relayQueue) == "table" and table.getn(R.relayQueue) > 0
end

local function sgNextRetryDelay(attempts)
    attempts = tonumber(attempts) or 0
    if attempts <= 1 then return HELLO_RETRY_1 end
    if attempts == 2 then return HELLO_RETRY_2 end
    return HELLO_QUEUE_RETRY
end

local function sgHandshakeNeeded()
    local master = sgMaster()
    local me = sgPlayer()
    if master == "" or me == "" or sgSame(master, me) then return false end
    if R.masterReady and sgSame(R.masterReadyName, master) then return false end
    if (tonumber(G.helloAttempts) or 0) < HELLO_MAX_IDLE_ATTEMPTS then return true end
    return sgRelayQueued()
end

local function sgWrappedOnUpdate()
    local t = sgNow()
    local master = sgMaster()

    if sgLower(master) ~= sgLower(G.lastMasterName) then
        R.masterReady = false
        R.masterReadyName = ""
        sgResetHandshake(master)
    end

    local ready = R.masterReady and sgSame(R.masterReadyName, master)
    local due = false

    if ready or master == "" or sgSame(master, sgPlayer()) then
        R.nextHelloAt = t + HELLO_PARK
    elseif sgHandshakeNeeded() then
        local allowed = tonumber(G.nextHelloAllowedAt) or 0
        if t >= allowed then
            R.nextHelloAt = 0
            due = true
        else
            R.nextHelloAt = allowed
        end
    else
        R.nextHelloAt = t + HELLO_PARK
    end

    local result = OWN_RELAY_ON_UPDATE()

    if R.masterReady and sgSame(R.masterReadyName, master) then
        G.helloAttempts = 0
        G.nextHelloAllowedAt = 0
        R.nextHelloAt = t + HELLO_PARK
    elseif due then
        G.helloAttempts = (tonumber(G.helloAttempts) or 0) + 1
        if G.helloAttempts >= HELLO_MAX_IDLE_ATTEMPTS and not sgRelayQueued() then
            G.nextHelloAllowedAt = t + HELLO_PARK
        else
            G.nextHelloAllowedAt = t + sgNextRetryDelay(G.helloAttempts)
        end
        R.nextHelloAt = G.nextHelloAllowedAt
    end

    return result
end

local function sgWrappedOnEvent(ev, a1, a2, a3)
    if ev == "CHAT_MSG_WHISPER" and sgTrim(a1 or "") == "" then
        -- Empty/whitespace-only traffic is never a customer conversation.
        return true
    end

    local result = OWN_RELAY_ON_EVENT(ev, a1, a2, a3)

    if ev == "PLAYER_LOGIN" then
        sgResetHandshake(sgMaster())
    elseif ev == "CHAT_MSG_WHISPER" and R.masterReady and sgSame(R.masterReadyName, sgMaster()) then
        -- A valid relay ACK was just consumed by the wrapped relay.
        G.helloAttempts = 0
        G.nextHelloAllowedAt = 0
        R.nextHelloAt = sgNow() + HELLO_PARK
    elseif ev == "CHAT_MSG_WHISPER" and not R.masterReady and sgRelayQueued() then
        -- A real customer message after idle exhaustion rearms one immediate
        -- handshake attempt; subsequent retries are still bounded/backed off.
        G.nextHelloAllowedAt = 0
        R.nextHelloAt = 0
    end

    return result
end

local function sgChatEventName(a, b)
    if b == "CHAT_MSG_WHISPER" or b == "CHAT_MSG_WHISPER_INFORM" then return b end
    if a == "CHAT_MSG_WHISPER" or a == "CHAT_MSG_WHISPER_INFORM" then return a end
    if event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_WHISPER_INFORM" then return event end
    return nil
end

local function sgChatMessage(a, b, c)
    if b == "CHAT_MSG_WHISPER" or b == "CHAT_MSG_WHISPER_INFORM" then
        return tostring(c or "")
    end
    return tostring(arg1 or "")
end

local function sgInstallChatSuppression()
    if OWN_CHAT_WRAPPER then return end
    if type(ChatFrame_OnEvent) ~= "function" then return end

    OWN_CHAT_BASE = ChatFrame_OnEvent
    OWN_CHAT_WRAPPER = function(a, b, c, d, e, f, g, h, i)
        local ev = sgChatEventName(a, b)
        if ev then
            local message = sgChatMessage(a, b, c)
            if sgStarts(message, PROTO) then
                return
            end
        end
        return OWN_CHAT_BASE(a, b, c, d, e, f, g, h, i)
    end
    ChatFrame_OnEvent = OWN_CHAT_WRAPPER
end

local M = {}

function M.Init()
    relay.OnEvent = sgWrappedOnEvent
    relay.OnUpdate = sgWrappedOnUpdate
    sgResetHandshake(sgMaster())
    sgInstallChatSuppression()
    W112_SUMMONSCOUT_WHISPER_RELAY_SPAM_GUARD_VERSION = VERSION
end

function M.Shutdown()
    if relay and relay.OnEvent == sgWrappedOnEvent then
        relay.OnEvent = OWN_RELAY_ON_EVENT
    end
    if relay and relay.OnUpdate == sgWrappedOnUpdate then
        relay.OnUpdate = OWN_RELAY_ON_UPDATE
    end
    if OWN_CHAT_WRAPPER and ChatFrame_OnEvent == OWN_CHAT_WRAPPER and OWN_CHAT_BASE then
        ChatFrame_OnEvent = OWN_CHAT_BASE
    end
    OWN_CHAT_WRAPPER = nil
    OWN_CHAT_BASE = nil
end

H.Register("whisperrelayspamguard", M, VERSION)
