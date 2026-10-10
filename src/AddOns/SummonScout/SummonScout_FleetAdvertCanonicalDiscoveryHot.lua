-- Fleet Advert canonical discovery + directory hygiene for SummonScout / WoW 1.12.1 Lua 5.0.
-- One live source of truth: the FallbackRouter provider directory.
-- This bridge also removes obsolete FAH discovery chatter, normalizes destination labels,
-- and prevents hub/non-hub directory state from leaking across roles.

local A = W112_SUMMONSCOUT_FLEET_ADVERT
if type(A) ~= "table" then return end

local DIRECTORY_TTL = 55
local LABELS = {
    hyjal = "Hyjal",
    hydraxian = "Hydraxis",
    hydraxis = "Hydraxis",
    winterspring = "Winterspring",
    silithus = "Silithus",
    tanaris = "Tanaris",
    azshara = "Azshara"
}

local lastDirectoryAt = 0
local nextSweepAt = 0

local function fallbackState()
    local h = W112_SUMMONSCOUT_HOT
    if not h or type(h.GetState) ~= "function" then return nil end
    if pcall then
        local ok, s = pcall(h.GetState, "fallbackrouter")
        if ok and type(s) == "table" then return s end
        return nil
    end
    local s = h.GetState("fallbackrouter")
    if type(s) == "table" then return s end
    return nil
end

local function fresh(item)
    if type(item) ~= "table" then return false end
    local seen = tonumber(item.seen) or -100000
    return (A.now() - seen) <= (tonumber(A.PEER_TTL) or 38)
end

local function normalizeCatalogLabels()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.GetLocationCatalog) ~= "function" then return end
    if api.__fleetCanonicalLabelsV3 then return end

    local original = api.GetLocationCatalog
    api.GetLocationCatalog = function()
        local list = original()
        local i, loc, id
        if type(list) == "table" then
            for i = 1, table.getn(list) do
                loc = list[i]
                if type(loc) == "table" and loc.id then
                    id = A.lower(loc.id)
                    if LABELS[id] then loc.label = LABELS[id] end
                end
            end
        end
        return list
    end
    api.__fleetCanonicalLabelsV3 = true
end

-- Fleet ads use the same canonical labels as the router/UI.
function A.label(id)
    id = A.lower(id)
    if LABELS[id] then return LABELS[id] end
    if id == "" then return "" end
    return string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2)
end

local function addLocalProvider(out, seen)
    local me = A.me()
    local svc = A.serviceCsv()
    if svc ~= "" and A.validName(me) then
        local key = A.lower(me)
        if not seen[key] then
            seen[key] = true
            out[table.getn(out) + 1] = me
        end
    end
end

function A.providers()
    local out = {}
    local seen = {}
    local f = fallbackState()
    local destination, providers, key, item
    if f and type(f.providers) == "table" then
        for destination, providers in pairs(f.providers) do
            if type(providers) == "table" then
                for key, item in pairs(providers) do
                    if fresh(item) and A.validName(item.name) then
                        local nk = A.lower(item.name)
                        if not seen[nk] then
                            seen[nk] = true
                            out[table.getn(out) + 1] = item.name
                        end
                    end
                end
            end
        end
    end
    addLocalProvider(out, seen)
    table.sort(out)
    return out
end

function A.destinations()
    local out = {}
    local seen = {}
    local f = fallbackState()
    local destination, providers, key, item
    if f and type(f.providers) == "table" then
        for destination, providers in pairs(f.providers) do
            if type(providers) == "table" then
                local hasFresh = false
                for key, item in pairs(providers) do
                    if fresh(item) then hasFresh = true; break end
                end
                destination = A.lower(destination)
                if hasFresh and destination ~= "" and not seen[destination] then
                    seen[destination] = true
                    out[table.getn(out) + 1] = destination
                end
            end
        end
    end

    local localCsv = A.serviceCsv()
    local x
    for x in string.gfind(localCsv, "[^,]+") do
        x = A.lower(x)
        if x ~= "" and not seen[x] then
            seen[x] = true
            out[table.getn(out) + 1] = x
        end
    end
    table.sort(out)
    return out
end

function A.destinationCsv()
    return table.concat(A.destinations(), ",")
end

-- FallbackRouter H/D is authoritative. Stop the redundant FAH heartbeat plane.
A.peers = {}
A.heartbeat = function() return end
A.onHeartbeat = function() return end

local function pruneCanonicalProviders(f)
    if not f or type(f.providers) ~= "table" then return end
    local destination, providers, key, item
    for destination, providers in pairs(f.providers) do
        if type(providers) ~= "table" then
            f.providers[destination] = nil
        else
            for key, item in pairs(providers) do
                if not fresh(item) then providers[key] = nil end
            end
            if next(providers) == nil then f.providers[destination] = nil end
        end
    end
end

local function hygieneTick()
    local f = fallbackState()
    if not f then return end

    pruneCanonicalProviders(f)

    if type(A.isMaster) == "function" and A.isMaster() then
        -- F.directory is a client-side copy received from a hub. A hub must never
        -- merge that stale copy back into its own live provider view.
        if type(f.directory) == "table" and next(f.directory) ~= nil then
            f.directory = {}
        end
        lastDirectoryAt = 0
        return
    end

    -- A non-hub directory is refreshed by D packets from the configured master.
    -- If the master disappears, do not advertise stale destinations indefinitely.
    if lastDirectoryAt > 0 and (A.now() - lastDirectoryAt) > DIRECTORY_TTL then
        f.directory = {}
        lastDirectoryAt = 0
    end
end

normalizeCatalogLabels()

local frame = CreateFrame and CreateFrame("Frame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("CHAT_MSG_WHISPER")
    frame:SetScript("OnEvent", function()
        local ev = event
        if ev == "PLAYER_LOGIN" then
            lastDirectoryAt = 0
            normalizeCatalogLabels()
            hygieneTick()
            return
        end
        if ev == "CHAT_MSG_WHISPER" then
            local raw = tostring(arg1 or "")
            local sender = tostring(arg2 or "")
            if string.sub(raw, 1, 9) == "[SSFR1] D"
                and type(A.master) == "function"
                and A.same(sender, A.master()) then
                lastDirectoryAt = A.now()
            end
        end
    end)
    frame:SetScript("OnUpdate", function()
        local t = A.now()
        if t < nextSweepAt then return end
        nextSweepAt = t + 0.50
        normalizeCatalogLabels()
        hygieneTick()
    end)
end

A.fallbackState = fallbackState
A.directoryTtl = DIRECTORY_TTL
W112_SUMMONSCOUT_FLEET_ADVERT_CANONICAL_DISCOVERY_VERSION = "3"
