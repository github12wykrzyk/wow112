-- Hub-origin ACK bridge for live-only fleet routing.
-- WoW 1.12.1 / Lua 5.0 compatible.
--
-- Historical versions of this hotfix also maintained a fixed five-location pool,
-- force-seeded F.directory and refreshed provider timestamps every frame. That
-- defeated the canonical TTL and made offline routes appear permanently live.
-- This version intentionally does one job only: bridge provider ACKs back to a
-- customer when the master itself originated the routed request.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "5-live-only-ack"
local F = H.GetState("fallbackrouter")
local PROTO = "[SSFR1]"
local PROVIDER_TTL = 38

local function now()
    return GetTime and GetTime() or 0
end

local function trim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    return string.gsub(s, "%s+$", "")
end

local function lower(s)
    return string.lower(trim(s))
end

local function same(a, b)
    a = lower(a)
    b = lower(b)
    return a ~= "" and a == b
end

local function split(s)
    local out, p = {}, 1
    while true do
        local at = string.find(s, ":", p, true)
        if not at then
            out[table.getn(out) + 1] = string.sub(s, p)
            break
        end
        out[table.getn(out) + 1] = string.sub(s, p, at - 1)
        p = at + 1
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

local function control(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local parts = split(trim(string.sub(raw, string.len(PROTO) + 1)))
    local code = parts[1]
    if not code or code == "" then return nil end
    local fields = {}
    local i
    for i = 2, table.getn(parts) do
        local value = unhex(parts[i])
        if value == nil then return nil end
        fields[table.getn(fields) + 1] = value
    end
    return code, fields
end

local function send(name, text)
    name = trim(name)
    if name == "" or not SendChatMessage then return false end
    if pcall then return pcall(SendChatMessage, text, "WHISPER", nil, name) end
    SendChatMessage(text, "WHISPER", nil, name)
    return true
end

local function label(id)
    id = lower(id)
    if id == "hyjal" then return "Hyjal" end
    if id == "hydraxian" or id == "hydraxis" then return "Hydraxis" end
    if id == "winterspring" then return "Winterspring" end
    if id == "silithus" then return "Silithus" end
    if id == "tanaris" then return "Tanaris" end
    if id == "azshara" then return "Azshara" end
    if id == "" then return "summon" end
    return string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2)
end

local function freshProvider(destination, sender)
    local providers = F.providers and F.providers[lower(destination)]
    local item = providers and providers[lower(sender)] or nil
    if type(item) ~= "table" then return false end
    return (now() - (tonumber(item.seen) or -100000)) <= PROVIDER_TTL
end

local function clearLegacyStickyState()
    F.totalPoolOwners = nil
    local destination, providers, key, item
    if type(F.providers) ~= "table" then return end
    for destination, providers in pairs(F.providers) do
        if type(providers) == "table" then
            for key, item in pairs(providers) do
                if type(item) == "table" then item.totalPoolSticky = nil end
            end
        end
    end
end

local M = {}

function M.Init()
    clearLegacyStickyState()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION = VERSION
    W112_SUMMONSCOUT_TOTAL_POOL_VERSION = nil
    W112_SUMMONSCOUT_TOTAL_POOL_CSV = nil
end

function M.OnEvent(ev, a1, a2)
    if ev ~= "CHAT_MSG_WHISPER" then return end

    local code, fields = control(a1 or "")
    if code ~= "A" or table.getn(fields) ~= 4 then return end

    local customer = fields[1]
    local destination = fields[2]
    local origin = fields[3]
    local status = fields[4]
    local me = UnitName and UnitName("player") or ""
    if not same(origin, me) then return end

    local key = lower(customer) .. "@" .. lower(destination)
    if not (F.pendingRoute and F.pendingRoute[key]) then return end
    if not freshProvider(destination, a2 or "") then return end

    F.pendingRoute[key] = nil
    if tostring(status) == "1" then
        send(customer, "Got it - the " .. label(destination) .. " summoner is inviting you now.")
    else
        send(customer, label(destination) .. " is currently unavailable. Please try again shortly.")
    end
end

function M.OnUpdate() end
function M.Shutdown() end

H.Register("fallbackrouter_hub_ack", M, VERSION)
W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION = VERSION
