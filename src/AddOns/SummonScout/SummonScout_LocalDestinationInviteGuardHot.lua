-- Hard local-destination invite guard for SummonScout / WoW 1.12.1 / Lua 5.0.
--
-- Problem fixed here:
--   * core routing correctly rejects an explicit request for another destination;
--   * legacy hot modules (PostPaymentOffer direct-prefix invite and
--     WhisperConfirmSpam confirmation invite) can still call InviteByName()
--     directly and bypass that ownership decision;
--   * a short follow-up such as "inv" can also hit core tryWhisperInvite after
--     an explicit foreign-destination request unless route ownership is remembered.
--
-- This module is intentionally narrow. It does not change parsing, routing,
-- payment, Ritual or roster semantics. It only prevents a destination-qualified
-- summoner from issuing a local invite for an explicitly foreign destination.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-local-destination-hard-guard"
local G = H.GetState("localdestinationinviteguard")
local TOKEN = {}

G.blockedUntil = G.blockedUntil or {}
G.blockedDestination = G.blockedDestination or {}
G.nextEnsureAt = tonumber(G.nextEnsureAt) or 0

local ROUTE_MEMORY_TTL = 45.0
local ENSURE_INTERVAL = 0.50

local function gdNow()
    if GetTime then return GetTime() end
    return 0
end

local function gdTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function gdLower(s)
    return string.lower(gdTrim(s or ""))
end

local function gdKey(name)
    return gdLower(name or "")
end

local function gdReserved(raw)
    raw = tostring(raw or "")
    return string.sub(raw, 1, 7) == "[SSFR1]"
        or string.sub(raw, 1, 7) == "[SSWR1]"
        or string.sub(raw, 1, 5) == "[SSI "
end

local function gdServiceContains(locationId)
    local service = gdLower(SummonScoutDB and SummonScoutDB.service or "all")
    local id = gdLower(locationId or "")
    if service == "" or service == "all" then return true end
    if id == "" then return false end
    return string.find("," .. service .. ",", "," .. id .. ",", 1, true) ~= nil
end

local function gdClearBlocked(name)
    local key = gdKey(name)
    if key == "" then return end
    G.blockedUntil[key] = nil
    G.blockedDestination[key] = nil
end

local function gdMarkBlocked(name, destination)
    local key = gdKey(name)
    if key == "" then return end
    G.blockedUntil[key] = gdNow() + ROUTE_MEMORY_TTL
    G.blockedDestination[key] = gdTrim(destination or "other destination")
end

local function gdBlocked(name)
    local key = gdKey(name)
    if key == "" then return false end
    local untilAt = tonumber(G.blockedUntil[key]) or 0
    if untilAt <= gdNow() then
        G.blockedUntil[key] = nil
        G.blockedDestination[key] = nil
        return false
    end
    return true
end

local function gdResolveExplicitDestination(raw)
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.FindLocation) ~= "function" then
        return nil, false
    end

    local loc, ambiguous
    if pcall then
        local ok, a, b = pcall(api.FindLocation, raw or "")
        if not ok then return nil, true end
        loc, ambiguous = a, b
    else
        loc, ambiguous = api.FindLocation(raw or "")
    end

    if ambiguous then return nil, true end
    if type(loc) == "table" and loc.id then return loc, false end
    return nil, false
end

local function gdShouldBlockWhisper(raw, sender)
    if gdReserved(raw) then return true, "control" end

    local service = gdLower(SummonScoutDB and SummonScoutDB.service or "all")
    if service == "" or service == "all" then return false, nil end

    local loc, ambiguous = gdResolveExplicitDestination(raw)
    if ambiguous then
        gdMarkBlocked(sender, "ambiguous")
        return true, "ambiguous"
    end

    if loc and loc.id then
        if gdServiceContains(loc.id) then
            gdClearBlocked(sender)
            return false, tostring(loc.label or loc.id)
        end
        local label = tostring(loc.label or loc.id)
        gdMarkBlocked(sender, label)
        return true, label
    end

    if gdBlocked(sender) then
        return true, G.blockedDestination[gdKey(sender)] or "route-active"
    end
    return false, nil
end

local function gdDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555SummonScout destination guard:|r " .. tostring(text or ""))
    end
end

local function gdPruneBlocked()
    local t = gdNow()
    local key, untilAt
    for key, untilAt in pairs(G.blockedUntil) do
        if t >= (tonumber(untilAt) or 0) then
            G.blockedUntil[key] = nil
            G.blockedDestination[key] = nil
        end
    end
end

local function gdPruneTransientInvites()
    local post = H.GetState("postpay")
    if type(post) == "table" and type(post.directInvitePending) == "table" then
        local key, item
        for key, item in pairs(post.directInvitePending) do
            local name = type(item) == "table" and item.sender or key
            if gdBlocked(name) then post.directInvitePending[key] = nil end
        end
    end

    local confirm = H.GetState("whisperconfirm")
    if type(confirm) == "table" then
        local maps = { confirm.candidates, confirm.pending, confirm.confirmations }
        local i, map, key, item, name
        for i = 1, table.getn(maps) do
            map = maps[i]
            if type(map) == "table" then
                for key, item in pairs(map) do
                    name = type(item) == "table" and item.sender or key
                    if gdBlocked(name) then map[key] = nil end
                end
            end
        end
    end
end

local function gdDetachStored()
    local api = G.apiOwner
    if type(api) == "table" and type(G.apiWrapper) == "function"
        and api.tryWhisperInvite == G.apiWrapper then
        api.tryWhisperInvite = G.apiBase
    end

    local module = G.postModule
    if type(module) == "table" and type(G.postWrapper) == "function"
        and module.OnEvent == G.postWrapper then
        module.OnEvent = G.postBase
    end

    module = G.confirmModule
    if type(module) == "table" and type(G.confirmWrapper) == "function"
        and module.OnEvent == G.confirmWrapper then
        module.OnEvent = G.confirmBase
    end

    G.apiOwner = nil
    G.apiBase = nil
    G.apiWrapper = nil
    G.postModule = nil
    G.postBase = nil
    G.postWrapper = nil
    G.confirmModule = nil
    G.confirmBase = nil
    G.confirmWrapper = nil
end

local function gdInstallApiGuard()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.tryWhisperInvite) ~= "function" then return false end

    if G.apiOwner == api and type(G.apiWrapper) == "function"
        and api.tryWhisperInvite == G.apiWrapper then
        return true
    end

    if type(G.apiOwner) == "table" and type(G.apiWrapper) == "function"
        and G.apiOwner.tryWhisperInvite == G.apiWrapper then
        G.apiOwner.tryWhisperInvite = G.apiBase
    end

    local base = api.tryWhisperInvite
    local wrapper = function(name, loc)
        if type(loc) == "table" and loc.id then
            if not gdServiceContains(loc.id) then
                gdMarkBlocked(name, tostring(loc.label or loc.id))
                gdDebug("core invite blocked -> " .. tostring(name or "?")
                    .. " [" .. tostring(loc.label or loc.id) .. "] serving="
                    .. tostring(SummonScoutDB and SummonScoutDB.service or "all"))
                return false, "wrong-service-hard-guard"
            end
            gdClearBlocked(name)
        elseif gdBlocked(name) then
            gdDebug("destination-less follow-up blocked -> " .. tostring(name or "?"))
            return false, "foreign-route-active"
        end
        return base(name, loc)
    end

    api.tryWhisperInvite = wrapper
    G.apiOwner = api
    G.apiBase = base
    G.apiWrapper = wrapper
    return true
end

local function gdInstallModuleGuard(moduleName, statePrefix)
    local module = H.modules and H.modules[moduleName] or nil
    if type(module) ~= "table" or type(module.OnEvent) ~= "function" then return false end

    local moduleField = statePrefix .. "Module"
    local baseField = statePrefix .. "Base"
    local wrapperField = statePrefix .. "Wrapper"

    if G[moduleField] == module and type(G[wrapperField]) == "function"
        and module.OnEvent == G[wrapperField] then
        return true
    end

    local previousModule = G[moduleField]
    local previousWrapper = G[wrapperField]
    if type(previousModule) == "table" and type(previousWrapper) == "function"
        and previousModule.OnEvent == previousWrapper then
        previousModule.OnEvent = G[baseField]
    end

    local base = module.OnEvent
    local wrapper = function(ev, a1, a2, a3)
        if ev == "CHAT_MSG_WHISPER" then
            local blocked, reason = gdShouldBlockWhisper(a1 or "", a2 or "")
            if blocked then
                local key = gdKey(a2 or "")
                if statePrefix == "post" then
                    local post = H.GetState("postpay")
                    if type(post) == "table" and type(post.directInvitePending) == "table" then
                        post.directInvitePending[key] = nil
                    end
                elseif statePrefix == "confirm" then
                    local confirm = H.GetState("whisperconfirm")
                    if type(confirm) == "table" then
                        if type(confirm.candidates) == "table" then confirm.candidates[key] = nil end
                        if type(confirm.pending) == "table" then confirm.pending[key] = nil end
                        if type(confirm.confirmations) == "table" then confirm.confirmations[key] = nil end
                    end
                end
                if reason ~= "control" then
                    gdDebug(moduleName .. " invite path blocked -> " .. tostring(a2 or "?")
                        .. " [" .. tostring(reason or "other destination") .. "]")
                end
                return nil
            end
        end
        return base(ev, a1, a2, a3)
    end

    module.OnEvent = wrapper
    G[moduleField] = module
    G[baseField] = base
    G[wrapperField] = wrapper
    return true
end

local function gdEnsure()
    gdInstallApiGuard()
    gdInstallModuleGuard("postpay", "post")
    gdInstallModuleGuard("whisperconfirm", "confirm")
    gdPruneBlocked()
    gdPruneTransientInvites()
end

local M = {}

function M.Init()
    -- Peel a previous generation before installing this one. The owner token
    -- keeps the previous module's later Shutdown() from removing our wrappers.
    gdDetachStored()
    G.ownerToken = TOKEN
    G.blockedUntil = {}
    G.blockedDestination = {}
    G.nextEnsureAt = 0
    gdEnsure()
    W112_SUMMONSCOUT_LOCAL_DESTINATION_INVITE_GUARD_VERSION = VERSION
end

function M.OnUpdate()
    local t = gdNow()
    if t < (tonumber(G.nextEnsureAt) or 0) then return end
    G.nextEnsureAt = t + ENSURE_INTERVAL
    gdEnsure()
end

function M.Shutdown()
    if G.ownerToken ~= TOKEN then return end
    gdDetachStored()
    G.ownerToken = nil
end

H.Register("localdestinationinviteguard", M, VERSION)
W112_SUMMONSCOUT_LOCAL_DESTINATION_INVITE_GUARD_VERSION = VERSION
