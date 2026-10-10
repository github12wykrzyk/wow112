-- Tanaris fleet/routing integration for SummonScout / WoW 1.12.1 Lua 5.0.
-- Core location parsing already contains Tanaris; this module only ensures the
-- Teletanaris profile advertises that service and extends fleet-counter allowlists.
-- It must never force Tanaris into the live router directory or keep providers sticky.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "3-live-only-tanaris"
local S = H.GetState("tanarisfullservice")
local TANARIS = "tanaris"

local function lower(v)
    return string.lower(tostring(v or ""))
end

local function me()
    return lower(UnitName and UnitName("player") or "")
end

local function ensureProfile()
    SummonScoutDB = SummonScoutDB or {}
    if me() == "teletanaris" then
        local service = lower(SummonScoutDB.service or "")
        if service == "" or service == "all" then SummonScoutDB.service = TANARIS end
    end
end

local function hasExpected(list, id)
    local i
    if type(list) ~= "table" then return false end
    for i = 1, table.getn(list) do
        if lower(list[i]) == id then return true end
    end
    return false
end

local function patchFleet()
    local C = W112_SUMMONSCOUT_FLEET_COUNTER_V1
    if type(C) ~= "table" then return end

    C.EXPECTED = C.EXPECTED or {}
    if not hasExpected(C.EXPECTED, TANARIS) then
        C.EXPECTED[table.getn(C.EXPECTED) + 1] = TANARIS
    end

    C.LABEL = C.LABEL or {}
    C.LABEL.tanaris = "TANARIS"
    C.ALLOWED = C.ALLOWED or {}
    C.ALLOWED.tanaris = true

    -- Keep the coordinator's normal live-service rollout semantics. Do not
    -- replace C.rollout with a fixed 5/5 requirement: offline routes are valid.
    S.fleetPatched = true
end

local M = {}

function M.Init()
    ensureProfile()
    patchFleet()
    W112_SUMMONSCOUT_TANARIS_FULL_SERVICE_VERSION = VERSION
end

function M.OnUpdate()
    ensureProfile()
    patchFleet()
end

function M.Shutdown() end

H.Register("tanarisfullservice", M, VERSION)
W112_SUMMONSCOUT_TANARIS_FULL_SERVICE_VERSION = VERSION
