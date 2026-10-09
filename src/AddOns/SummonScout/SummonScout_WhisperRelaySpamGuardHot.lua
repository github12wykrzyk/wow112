-- SummonScout Whisper Relay spam guard for WoW 1.12.1 / Lua 5.0.
--
-- Keeps the V1 relay transport and session model intact while fixing live spam:
--   * zero SSWR1 H/K traffic while there is no real relay queue,
--   * bounded handshake retries only while customer/lifecycle data is queued,
--   * transport-only SSWR1/SSFR1 whispers stay on WHISPER but are filtered
--     by WIM's own filter path,
--   * user-visible [SSI ...] master lifecycle reports are never hidden,
--   * no ChatFrame_OnEvent replacement, so repeated hot/reload cycles cannot leave
--     a dangling wrapper calling a nil base function.
--
-- The guard wraps only the relay module. WIM integration is data-only via
-- WIM_Filters and therefore does not replace WIM or Blizzard chat handlers.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local relay = H.modules and H.modules["whisperrelay"] or nil
if type(relay) ~= "table" or type(relay.OnEvent) ~= "function"
    or type(relay.OnUpdate) ~= "function" then
    return
end

local VERSION = "5-demand-only-wim-transport-filter"
local PROTO = "[SSWR1]"
-- WIM_FilterResult uses Lua pattern matching, so [ and ] must be escaped.
-- Keep the transport families blocked, but repair the persisted v4 filter that
-- accidentally hid the human-readable [SSI ...] lifecycle feed from the Master.
local WIM_FILTER_PATTERN = "%[SSWR1%]"
local WIM_FALLBACK_FILTER_PATTERN = "%[SSFR1%]"
local LEGACY_WIM_MASTER_FILTER_PATTERN = "%[SSI "
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
G.wimFilterInstalled = G.wimFilterInstalled and true or false

local OWN_RELAY_ON_EVENT = relay.OnEvent
local OWN_RELAY_ON_UPDATE = relay.OnUpdate

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

local function sgInstallWimSuppression()
    -- WIM 1.3.x exposes WIM_Filters as a SavedVariable and applies it to both
    -- its messenger windows and its chat-frame suppressor. "Block" hides the
    -- packet instead of merely ignoring it in the WIM window.
    if type(WIM_Filters) ~= "table" then
        G.wimFilterInstalled = false
        return false
    end
    if WIM_Filters[WIM_FILTER_PATTERN] ~= "Block" then
        WIM_Filters[WIM_FILTER_PATTERN] = "Block"
    end
    if WIM_Filters[WIM_FALLBACK_FILTER_PATTERN] ~= "Block" then
        WIM_Filters[WIM_FALLBACK_FILTER_PATTERN] = "Block"
    end
    -- v4 accidentally persisted this filter in WIM's SavedVariables. Removing
    -- the code alone would not restore reports on upgraded clients, so actively
    -- delete only the exact Block value that SummonScout previously installed.
    if WIM_Filters[LEGACY_WIM_MASTER_FILTER_PATTERN] == "Block" then
        WIM_Filters[LEGACY_WIM_MASTER_FILTER_PATTERN] = nil
    end
    G.wimFilterInstalled = true
    return true
end

local function sgHandshakeNeeded()
    local master = sgMaster()
    local me = sgPlayer()
    if master == "" or me == "" or sgSame(master, me) then return false end
    if R.masterReady and sgSame(R.masterReadyName, master) then return false end
    -- Critical rule: no startup/login/master-change heartbeat at all.
    -- H exists only to release actual queued relay traffic.
    if not sgRelayQueued() then return false end
    return (tonumber(G.helloAttempts) or 0) < HELLO_MAX_IDLE_ATTEMPTS
end

local function sgWrappedOnUpdate()
    local t = sgNow()
    local master = sgMaster()

    -- Cheap idempotent repair in case WIM was loaded after us or the user reset
    -- WIM filters during the session. This also clears the persisted v4 [SSI]
    -- suppression for clients that upgrade without deleting SavedVariables.
    sgInstallWimSuppression()

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
        if G.helloAttempts >= HELLO_MAX_IDLE_ATTEMPTS then
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
        sgInstallWimSuppression()
        sgResetHandshake(sgMaster())
        R.nextHelloAt = sgNow() + HELLO_PARK
    elseif ev == "CHAT_MSG_WHISPER" and R.masterReady and sgSame(R.masterReadyName, sgMaster()) then
        -- A valid relay ACK was just consumed by the wrapped relay.
        G.helloAttempts = 0
        G.nextHelloAllowedAt = 0
        R.nextHelloAt = sgNow() + HELLO_PARK
    elseif ev == "CHAT_MSG_WHISPER" and not R.masterReady and sgRelayQueued() then
        -- Real queued customer traffic may arm an immediate bounded handshake.
        -- Idle state never arms H.
        if (tonumber(G.helloAttempts) or 0) >= HELLO_MAX_IDLE_ATTEMPTS then
            G.helloAttempts = 0
        end
        G.nextHelloAllowedAt = 0
        R.nextHelloAt = 0
    end

    return result
end

local M = {}

function M.Init()
    relay.OnEvent = sgWrappedOnEvent
    relay.OnUpdate = sgWrappedOnUpdate
    sgResetHandshake(sgMaster())
    R.nextHelloAt = sgNow() + HELLO_PARK
    sgInstallWimSuppression()
    W112_SUMMONSCOUT_WHISPER_RELAY_SPAM_GUARD_VERSION = VERSION
end

function M.Shutdown()
    if relay and relay.OnEvent == sgWrappedOnEvent then
        relay.OnEvent = OWN_RELAY_ON_EVENT
    end
    if relay and relay.OnUpdate == sgWrappedOnUpdate then
        relay.OnUpdate = OWN_RELAY_ON_UPDATE
    end
    -- Intentionally do not remove the reserved transport WIM filters during hot
    -- swap. Keeping them avoids a visible SSWR1/SSFR1 leak between Shutdown and
    -- Init. Human-readable [SSI ...] master reports remain visible.
end

H.Register("whisperrelayspamguard", M, VERSION)
