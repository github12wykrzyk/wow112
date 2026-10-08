-- Companion ACK bridge + total-pool hotfix for SummonScout_FallbackRouterHot.lua.
--
-- The original bridge handles the special case where the routing hub itself
-- originated a customer request and receives the target summoner's ACK directly.
--
-- HOTFIX V2 also makes the operator's canonical summon offering independent of
-- the short live-directory TTL. The customer-facing/routing pool is always:
--   Silithus, Winterspring, Azshara/Hydraxis, Hyjal.
--
-- Route ownership is learned from the existing SSFR1 provider HELLO packets and
-- persisted in SummonScoutDB. A previously learned owner is re-seeded into the
-- router provider table, so a missed/stale heartbeat does not make a configured
-- destination instantly become "unavailable". The existing route ACK/timeout
-- remains authoritative: an actually offline owner still fails safely.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "2-total-pool-hotfix"
local F = H.GetState("fallbackrouter")
local PROTO = "[SSFR1]"
local TOTAL_POOL = { "silithus", "winterspring", "hydraxian", "hyjal" }
local TOTAL_POOL_SET = {
    silithus = true,
    winterspring = true,
    hydraxian = true,
    hyjal = true
}

local function now()
    if GetTime then return GetTime() end
    return 0
end

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

local function validPlayerName(name)
    name = trim(name)
    if name == "" or string.len(name) > 32 then return false end
    if string.find(name, "[%c%s:;,=|]") then return false end
    return true
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

local function parseHello(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local rest = trim(string.sub(raw, string.len(PROTO) + 1))
    local parts = split(rest)
    if parts[1] ~= "H" or table.getn(parts) ~= 2 then return nil end
    return unhex(parts[2])
end

local function ownerDb()
    if not SummonScoutDB then SummonScoutDB = {} end
    if type(SummonScoutDB.totalPoolOwners) ~= "table" then
        SummonScoutDB.totalPoolOwners = {}
    end
    return SummonScoutDB.totalPoolOwners
end

local function rememberServices(name, services)
    name = trim(name)
    if not validPlayerName(name) then return false end

    local key = lower(name)
    local db = ownerDb()
    local i, id, owners

    -- A HELLO is authoritative for this provider's current service set. Remove
    -- its previous total-pool ownership first, then install the new set.
    for i = 1, table.getn(TOTAL_POOL) do
        id = TOTAL_POOL[i]
        owners = db[id]
        if type(owners) == "table" then owners[key] = nil end
    end

    local learned = false
    local token
    for token in string.gfind(tostring(services or ""), "[^,]+") do
        id = lower(token)
        if TOTAL_POOL_SET[id] then
            if type(db[id]) ~= "table" then db[id] = {} end
            db[id][key] = {
                name = name,
                lastSeen = time and time() or 0
            }
            learned = true
        end
    end
    return learned
end

local function rememberLocalService()
    local me = trim(UnitName and UnitName("player") or "")
    local services = lower(SummonScoutDB and SummonScoutDB.service or "")
    if services == "" or services == "all" or not validPlayerName(me) then return end
    if services == (F.totalPoolLastLocalServices or "")
        and same(me, F.totalPoolLastLocalName or "") then
        return
    end
    rememberServices(me, services)
    F.totalPoolLastLocalServices = services
    F.totalPoolLastLocalName = me
end

local function seedTotalPool()
    F.directory = F.directory or {}
    F.providers = F.providers or {}
    F.totalPool = F.totalPool or {}

    local db = ownerDb()
    local t = now()
    local i, id, owners, ownerKey, owner, name, providers, existing

    for i = 1, table.getn(TOTAL_POOL) do
        id = TOTAL_POOL[i]
        F.totalPool[id] = true
        F.directory[id] = true

        owners = db[id]
        if type(owners) == "table" then
            for ownerKey, owner in pairs(owners) do
                name = type(owner) == "table" and trim(owner.name or "") or trim(owner or "")
                if validPlayerName(name) then
                    if type(F.providers[id]) ~= "table" then F.providers[id] = {} end
                    providers = F.providers[id]
                    existing = providers[lower(ownerKey)]
                    providers[lower(ownerKey)] = {
                        name = name,
                        seen = t,
                        lastAssigned = existing and (tonumber(existing.lastAssigned) or 0) or 0,
                        totalPoolSticky = true
                    }
                end
            end
        end
    end

    W112_SUMMONSCOUT_TOTAL_POOL_CSV = "silithus,winterspring,hydraxian,hyjal"
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
    if destination == "silithus" then return "Silithus" end
    return destination
end

local M = {}

function M.Init()
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_WHISPER")
    F.totalPoolNextSeedAt = 0
    F.totalPoolNextLocalCheckAt = 0
    F.totalPoolLastLocalServices = ""
    F.totalPoolLastLocalName = ""
    rememberLocalService()
    seedTotalPool()
    W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION = VERSION
    W112_SUMMONSCOUT_TOTAL_POOL_VERSION = VERSION
end

function M.OnEvent(ev, a1, a2)
    if ev == "PLAYER_LOGIN" then
        F.totalPoolLastLocalServices = ""
        F.totalPoolLastLocalName = ""
        rememberLocalService()
        seedTotalPool()
        return
    end

    if ev ~= "CHAT_MSG_WHISPER" then return end

    -- Learn destination ownership from the router's existing provider HELLO.
    local services = parseHello(a1 or "")
    if services then
        rememberServices(a2 or "", services)
        seedTotalPool()
        return
    end

    local customer, destination, origin, status = parseAck(a1 or "")
    if not customer then return end

    local me = trim(UnitName and UnitName("player") or "")
    if not same(origin, me) then return end

    local key = lower(customer) .. "@" .. lower(destination)
    local pending = F.pendingRoute and F.pendingRoute[key]
    if not pending then return end

    -- A configured/learned provider for this destination may complete a
    -- hub-originated route. seedTotalPool() keeps last-known fleet ownership
    -- present even when the short live HELLO TTL was missed.
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

function M.OnUpdate()
    local t = now()
    if t >= (tonumber(F.totalPoolNextSeedAt) or 0) then
        F.totalPoolNextSeedAt = t + 0.20
        seedTotalPool()
    end
    if t >= (tonumber(F.totalPoolNextLocalCheckAt) or 0) then
        F.totalPoolNextLocalCheckAt = t + 3.0
        rememberLocalService()
    end
end

H.Register("fallbackrouter_hub_ack", M, VERSION)
W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION = VERSION
W112_SUMMONSCOUT_TOTAL_POOL_VERSION = VERSION
