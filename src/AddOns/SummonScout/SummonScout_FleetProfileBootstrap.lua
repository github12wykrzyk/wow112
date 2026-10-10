-- One-time fleet profile bootstrap for SummonScout / WoW 1.12.1 / Lua 5.0.
-- Applies the canonical five-summoner topology once per character, then leaves
-- later manual user edits alone.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = 1
local MASTER = "Feltaxi"
local PROFILES = {
    feltaxi     = { service="hydraxian", reporting=false },
    kalisum     = { service="silithus", reporting=true },
    bolthyjal   = { service="hyjal", reporting=true },
    taxiwinter  = { service="winterspring", reporting=true },
    teletanaris = { service="tanaris", reporting=true },
}

local S = H.GetState("fleetprofilebootstrap")
S.nextAt = tonumber(S.nextAt) or 0

local function now()
    return GetTime and GetTime() or 0
end

local function trim(v)
    local s = tostring(v or "")
    s = string.gsub(s, "^%s+", "")
    return string.gsub(s, "%s+$", "")
end

local function key(v)
    return string.lower(trim(v))
end

local function player()
    return trim(UnitName and UnitName("player") or "")
end

local function refreshGui()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table" and type(api.guiRefreshSafe) == "function" then
        if pcall then pcall(api.guiRefreshSafe) else api.guiRefreshSafe() end
    end
end

local function announce(name, p)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r fleet profile configured -> "
            .. tostring(name) .. " | service " .. tostring(p.service)
            .. " | master " .. MASTER)
    end
end

local function applyOnce()
    SummonScoutDB = SummonScoutDB or {}

    local name = player()
    local k = key(name)
    local p = PROFILES[k]
    if not p then return true end

    if type(SummonScoutDB.fleetProfileBootstrapByCharacter) ~= "table" then
        SummonScoutDB.fleetProfileBootstrapByCharacter = {}
    end
    if tonumber(SummonScoutDB.fleetProfileBootstrapByCharacter[k]) == VERSION then
        return true
    end

    -- Canonical topology.
    SummonScoutDB.masterName = MASTER
    SummonScoutDB.service = p.service

    -- Normal summon operation expected for all five providers.
    SummonScoutDB.enabled = true
    SummonScoutDB.autoInvite = true
    SummonScoutDB.whisperAutoInvite = true
    SummonScoutDB.partyAutoSummon = true
    SummonScoutDB.summonWhisperEnabled = true
    SummonScoutDB.loggingEnabled = true

    -- The old per-client World scheduler must stay off; fleet advertising owns it.
    SummonScoutDB.spamEnabled = false
    SummonScoutDB.fleetAdvertEnabled = true
    SummonScoutDB.fleetCounterEnabled = true

    -- Keep shard safety consistent across all summoners.
    SummonScoutDB.shardGuardEnabled = true
    SummonScoutDB.shardGuardMin = 5

    -- Four providers report lifecycle/payment/invite events to Feltaxi.
    -- Feltaxi is the coordinator and must not report to itself.
    SummonScoutDB.masterReportingEnabled = p.reporting and true or false
    SummonScoutDB.masterReportInvites = true
    SummonScoutDB.masterReportPayments = true
    SummonScoutDB.masterReportLifecycle = true

    SummonScoutDB.fleetProfileBootstrapByCharacter[k] = VERSION
    S.lastConfigured = name
    S.lastConfiguredAt = now()
    refreshGui()
    announce(name, p)
    return true
end

local M = {}

function M.Init()
    S.nextAt = 0
    applyOnce()
    W112_SUMMONSCOUT_FLEET_PROFILE_BOOTSTRAP_VERSION = tostring(VERSION)
end

function M.OnUpdate()
    local t = now()
    if t < (S.nextAt or 0) then return end
    S.nextAt = t + 2
    applyOnce()
end

function M.Shutdown() end

H.Register("fleetprofilebootstrap", M, tostring(VERSION))
W112_SUMMONSCOUT_FLEET_PROFILE_BOOTSTRAP_VERSION = tostring(VERSION)
