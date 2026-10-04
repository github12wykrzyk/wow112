-- Companion ACK bridge for SummonScout_FallbackRouterHot.lua.
-- Handles the one special case where the routing hub itself originated the
-- customer request and therefore receives the target summoner's ACK directly.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "1-hub-origin-ack"
local F = H.GetState("fallbackrouter")
local PROTO = "[SSFR1]"

local function trim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function lower(s) return string.lower(trim(s or "")) end

local function same(a, b)
    a = lower(a)
    b = lower(b)
    return a ~= "" and a == b
end

local function split(s)
    local out = {}
    local startAt = 1
    while true do
        local at = string.find(s, ":", startAt, true)
        if not at then
            out[table.getn(out) + 1] = string.sub(s, startAt)
            break
        end
        out[table.getn(out) + 1] = string.sub(s, startAt, at - 1)
        startAt = at + 1
    end
    return out
end

local function unhex(s)
    s = tostring(s or "")
    if math.mod(string.len(s), 2) ~= 0 or string.find(s, "[^0-9a-fA-F]") then return nil end
    local out = ""
    local i
    for i = 1, string.len(s), 2 do
        local b = tonumber(string.sub(s, i, i + 1), 16)
        if not b then return nil end
        out = out .. string.char(b)
    end
    return out
end

local function parseAck(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local rest = trim(string.sub(raw, string.len(PROTO) + 1))
    local parts = split(rest)
    if parts[1] ~= "A" or table.getn(parts) ~= 5 then return nil end
    local customer = unhex(parts[2])
    local destination = unhex(parts[3])
    local origin = unhex(parts[4])
    local status = unhex(parts[5])
    if not customer or not destination or not origin or not status then return nil end
    return customer, destination, origin, status
end

local function sendCustomer(name, text)
    name = trim(name)
    if name == "" or not SendChatMessage then return end
    if pcall then
        pcall(SendChatMessage, text, "WHISPER", nil, name)
    else
        SendChatMessage(text, "WHISPER", nil, name)
    end
end

local function label(destination)
    destination = lower(destination)
    if destination == "hyjal" then return "Hyjal" end
    if destination == "hydraxian" then return "Hydraxis" end
    if destination == "winterspring" then return "Winterspring" end
    return destination
end

local M = {}

function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION = VERSION
end

function M.OnEvent(ev, a1, a2)
    if ev ~= "CHAT_MSG_WHISPER" then return end
    local customer, destination, origin, status = parseAck(a1 or "")
    if not customer then return end

    local me = trim(UnitName and UnitName("player") or "")
    if not same(origin, me) then return end

    local key = lower(customer) .. "@" .. lower(destination)
    local pending = F.pendingRoute and F.pendingRoute[key]
    if not pending then return end

    -- Only a currently registered provider for this destination may complete
    -- a hub-originated route. This prevents arbitrary whispers from closing it.
    local providers = F.providers and F.providers[lower(destination)]
    local provider = providers and providers[lower(a2 or "")] or nil
    if not provider then return end

    F.pendingRoute[key] = nil
    if tostring(status or "") == "1" then
        sendCustomer(customer, "Got it - the " .. label(destination) .. " summoner is inviting you now.")
    else
        sendCustomer(customer, label(destination) .. " is currently unavailable. Please try again shortly.")
    end
end

function M.OnUpdate() end

H.Register("fallbackrouter_hub_ack", M, VERSION)
W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION = VERSION
