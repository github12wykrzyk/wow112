-- Fleet Advert canonical discovery bridge for SummonScout / WoW 1.12.1 Lua 5.0.
-- Reuses the already-authoritative FallbackRouter provider directory instead of
-- maintaining a second independent provider-discovery truth for World adverts.

local A = W112_SUMMONSCOUT_FLEET_ADVERT
if type(A) ~= "table" then return end

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

A.fallbackState = fallbackState
W112_SUMMONSCOUT_FLEET_ADVERT_CANONICAL_DISCOVERY_VERSION = "2"
