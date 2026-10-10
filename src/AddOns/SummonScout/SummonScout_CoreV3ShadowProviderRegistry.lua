-- SummonScout Core V3 shadow provider registry.
-- Stage 3 of the controlled-core-replacement plan.
-- Single writer for the Core V3 provider projection; reads legacy/public state only.
-- No fleet traffic, invite, route, party or summon mutations are allowed here.
-- WoW 1.12.1 / Lua 5.0 compatible.

SummonScoutDB = SummonScoutDB or {}

local VERSION = "p1-shadow-provider-registry"
local TTL = 38.0
local SWEEP = 0.50
local MAX_HISTORY = 256

local R = W112_SUMMON_CORE_V3_PROVIDER_REGISTRY_SHADOW
if type(R) ~= "table" then
    R = {}
    W112_SUMMON_CORE_V3_PROVIDER_REGISTRY_SHADOW = R
end

R.version = VERSION
R.providers = type(R.providers) == "table" and R.providers or {}
R.history = type(R.history) == "table" and R.history or {}
R.transportCursor = tonumber(R.transportCursor) or 0
R.nextSweepAt = tonumber(R.nextSweepAt) or 0
R.parity = type(R.parity) == "table" and R.parity or { matches = 0, mismatches = 0, unknown = 0 }

local ALLOWED = {
    hydraxian = true,
    hyjal = true,
    winterspring = true,
    silithus = true,
    tanaris = true
}

local function now()
    if GetTime then return tonumber(GetTime()) or 0 end
    return 0
end

local function wall()
    if time then return tonumber(time()) or 0 end
    return 0
end

local function trim(value)
    local s = tostring(value or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function lower(value)
    return string.lower(trim(value))
end

local function same(a, b)
    a = lower(a)
    b = lower(b)
    return a ~= "" and a == b
end

local function playerName()
    return trim(UnitName and UnitName("player") or "")
end

local function appendBounded(list, item, maxCount)
    list[table.getn(list) + 1] = item
    while table.getn(list) > maxCount do table.remove(list, 1) end
end

local function history(kind, provider, detail)
    appendBounded(R.history, {
        ts = wall(),
        mono = now(),
        kind = tostring(kind or "OBS"),
        provider = provider and provider.name or "",
        state = provider and provider.effectiveState or "",
        detail = tostring(detail or "")
    }, MAX_HISTORY)
end

local function servicesSet(csv)
    local set = {}
    local token
    for token in string.gfind(lower(csv), "[^,]+") do
        token = lower(token)
        if ALLOWED[token] then set[token] = true end
    end
    return set
end

local function servicesCsv(set)
    local order = { "hydraxian", "hyjal", "winterspring", "silithus", "tanaris" }
    local out = {}
    local i, id
    for i = 1, table.getn(order) do
        id = order[i]
        if type(set) == "table" and set[id] then out[table.getn(out) + 1] = id end
    end
    return table.concat(out, ",")
end

local function fixedSummoner(name)
    local wanted = lower(name)
    if wanted == "" then return false end
    if same(name, playerName()) then return true end
    local map = W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE
    if type(map) ~= "table" then return false end
    local _, master
    for _, master in pairs(map) do
        if lower(master) == wanted then return true end
    end
    return false
end

local function ensureProvider(name)
    local key = lower(name)
    if key == "" then return nil end
    local p = R.providers[key]
    if type(p) ~= "table" then
        p = {
            name = trim(name),
            key = key,
            services = {},
            presence = "OFFLINE",
            readiness = "UNKNOWN",
            effectiveState = "OFFLINE",
            lastSeen = -100000,
            source = ""
        }
        R.providers[key] = p
    end
    if trim(name) ~= "" then p.name = trim(name) end
    return p
end

local function recompute(p)
    if type(p) ~= "table" then return end
    local fresh = (now() - (tonumber(p.lastSeen) or -100000)) <= TTL
    if not fresh then
        p.presence = "OFFLINE"
        p.effectiveState = "OFFLINE"
        return
    end
    p.presence = "ONLINE"
    if p.readiness == "READY" then
        p.effectiveState = "READY"
    elseif p.readiness == "BLOCKED" then
        p.effectiveState = "BLOCKED"
    else
        p.effectiveState = "ONLINE_UNKNOWN"
    end
end

local function observeLocal()
    local me = playerName()
    if me == "" then return end
    local serviceSet = servicesSet(SummonScoutDB and SummonScoutDB.service or "")
    local serviceCsv = servicesCsv(serviceSet)
    local p = ensureProvider(me)
    if not p then return end
    local before = p.effectiveState

    p.services = serviceSet
    p.servicesCsv = serviceCsv
    p.lastSeen = now()
    p.source = "local-config"
    p.readinessReason = ""

    if serviceCsv == "" then
        p.readiness = "BLOCKED"
        p.readinessReason = "no-service"
    elseif not SummonScoutDB or SummonScoutDB.enabled ~= true then
        p.readiness = "BLOCKED"
        p.readinessReason = "addon-disabled"
    elseif W112_SUMMONSCOUT_SLAVE_SAFETY_READY == false then
        p.readiness = "BLOCKED"
        p.readinessReason = "slave-safety"
    else
        p.readiness = "READY"
    end
    recompute(p)
    if before ~= p.effectiveState then history("STATE", p, "local") end
end

local function observeHeartbeat(envelope)
    if type(envelope) ~= "table" or envelope.direction ~= "IN" then return end
    if not fixedSummoner(envelope.peer or "") then return end
    local fields = envelope.fields
    if type(fields) ~= "table" then return end

    local code = tostring(envelope.code or "")
    if code ~= "FCV" and code ~= "H" then return end

    local p = ensureProvider(envelope.peer)
    if not p then return end
    local before = p.effectiveState
    local csv = ""
    local readiness = nil
    local reason = ""

    if code == "FCV" then
        if table.getn(fields) < 2 or tostring(fields[1] or "") ~= "1" then return end
        csv = tostring(fields[2] or "")
        -- Forward-compatible with the V2 heartbeat prototype where readiness
        -- is carried in field 4 while preserving current 1.84 FCV behavior.
        if table.getn(fields) >= 6 then
            local candidate = string.upper(trim(fields[4] or ""))
            if candidate == "READY" or candidate == "BLOCKED" then readiness = candidate end
            reason = lower(fields[5] or "")
        end
    else
        if table.getn(fields) < 1 then return end
        csv = tostring(fields[1] or "")
    end

    local parsed = servicesSet(csv)
    local normalized = servicesCsv(parsed)
    if normalized ~= "" then
        p.services = parsed
        p.servicesCsv = normalized
        if readiness then
            p.readiness = readiness
        elseif code == "FCV" then
            -- In 1.84 RouteReadinessPresence, a non-empty FCV service set is
            -- only emitted while the sender is route-ready. This is strong READY evidence.
            p.readiness = "READY"
        else
            -- Legacy fallback HELLO proves liveness/services but not readiness.
            p.readiness = "UNKNOWN"
        end
    elseif code == "FCV" and p.servicesCsv and p.servicesCsv ~= "" then
        -- 1.84 RouteReadinessPresence sends an empty service set while blocked.
        p.readiness = "BLOCKED"
        reason = reason ~= "" and reason or "legacy-empty-services"
    else
        return
    end

    p.readinessReason = reason
    p.lastSeen = tonumber(envelope.mono) or now()
    p.source = code
    recompute(p)
    if before ~= p.effectiveState then history("STATE", p, code) end
end

local function consumeTransport()
    local api = W112_SUMMON_CORE_V3_TRANSPORT_SHADOW_API
    if type(api) ~= "table" or type(api.GetSince) ~= "function" then return end
    local messages = api.GetSince(R.transportCursor)
    local i, envelope
    for i = 1, table.getn(messages) do
        envelope = messages[i]
        observeHeartbeat(envelope)
        if type(envelope) == "table" and (tonumber(envelope.seq) or 0) > R.transportCursor then
            R.transportCursor = tonumber(envelope.seq) or R.transportCursor
        end
    end
end

local function legacyFallback()
    local h = W112_SUMMONSCOUT_HOT
    if type(h) ~= "table" or type(h.GetState) ~= "function" then return nil end
    local ok, state
    if pcall then
        ok, state = pcall(h.GetState, "fallbackrouter")
        if not ok then return nil end
    else
        state = h.GetState("fallbackrouter")
    end
    if type(state) ~= "table" then return nil end
    return state
end

local function legacyReady(name, service)
    local f = legacyFallback()
    if not f or type(f.providers) ~= "table" then return nil end
    local providers = f.providers[lower(service)]
    if type(providers) ~= "table" then return false end
    local item = providers[lower(name)]
    if type(item) ~= "table" then return false end
    return (now() - (tonumber(item.seen) or -100000)) <= TTL
end

local function updateParity()
    local matches, mismatches, unknown = 0, 0, 0
    local _, p, service
    for _, p in pairs(R.providers) do
        if type(p) == "table" and p.effectiveState ~= "OFFLINE" then
            for service in pairs(p.services or {}) do
                local legacy = legacyReady(p.name, service)
                if legacy == nil or p.effectiveState == "ONLINE_UNKNOWN" then
                    unknown = unknown + 1
                else
                    local v3Ready = p.effectiveState == "READY"
                    if v3Ready == legacy then matches = matches + 1 else mismatches = mismatches + 1 end
                end
            end
        end
    end
    R.parity.matches = matches
    R.parity.mismatches = mismatches
    R.parity.unknown = unknown
    R.parity.updatedAt = now()
end

local function sweep()
    observeLocal()
    consumeTransport()
    local _, p
    for _, p in pairs(R.providers) do recompute(p) end
    updateParity()
end

local function getProvider(name)
    return R.providers[lower(name)]
end

local function readyProviders(service)
    service = lower(service)
    local out = {}
    local _, p
    for _, p in pairs(R.providers) do
        if type(p) == "table" and p.effectiveState == "READY"
            and type(p.services) == "table" and p.services[service] then
            out[table.getn(out) + 1] = p.name
        end
    end
    table.sort(out)
    return out
end

local frame = CreateFrame and CreateFrame("Frame", "SummonScoutCoreV3ShadowProviderRegistryFrame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", function()
        if event == "PLAYER_LOGIN" then
            R.nextSweepAt = 0
            history("SESSION", nil, VERSION)
        end
    end)
    frame:SetScript("OnUpdate", function()
        local t = now()
        if t < (R.nextSweepAt or 0) then return end
        R.nextSweepAt = t + SWEEP
        sweep()
    end)
end

W112_SUMMON_CORE_V3_PROVIDER_REGISTRY_SHADOW_API = {
    version = VERSION,
    ttl = TTL,
    GetState = function() return R end,
    GetProvider = getProvider,
    ReadyProviders = readyProviders
}
