-- SummonScout canonical total service pool for WoW 1.12.1 / Lua 5.0.
--
-- The fallback router keeps F.directory as a short-lived live directory. That is
-- useful for transport health, but it is too strict for customer intent: a route
-- can disappear from one summoner's local directory for a few seconds even though
-- it is part of the operator's configured summon fleet.
--
-- This module overlays the operator's total service catalog onto F.directory so
-- destination selection is accepted and forwarded to the master for a real route
-- attempt. The provider/ACK path remains authoritative: if no live provider can
-- actually take the request, the existing router still returns "unavailable".

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "1-canonical-total-pool"
local F = H.GetState("fallbackrouter")
local S = H.GetState("totalpool")

-- Canonical internal location IDs. "hydraxian" is the existing SummonScout ID
-- for the Azshara / Hydraxian Waterlords service.
local TOTAL_POOL = {
    "silithus",
    "winterspring",
    "hydraxian",
    "hyjal"
}

local function seedTotalPool()
    F.directory = F.directory or {}
    F.totalPool = F.totalPool or {}

    local i, id
    for i = 1, table.getn(TOTAL_POOL) do
        id = TOTAL_POOL[i]
        F.totalPool[id] = true
        F.directory[id] = true
    end

    S.lastSeedAt = GetTime and GetTime() or 0
end

local M = {}

function M.Init()
    seedTotalPool()
    S.nextSeedAt = 0
    W112_SUMMONSCOUT_TOTAL_POOL_VERSION = VERSION
    W112_SUMMONSCOUT_TOTAL_POOL_CSV = "silithus,winterspring,hydraxian,hyjal"
end

function M.OnEvent()
    -- No event ownership. Routing remains in FallbackRouterHot.
end

function M.OnUpdate()
    local now = GetTime and GetTime() or 0
    if now < (tonumber(S.nextSeedAt) or 0) then return end
    S.nextSeedAt = now + 0.20
    seedTotalPool()
end

H.Register("totalpool", M, VERSION)
W112_SUMMONSCOUT_TOTAL_POOL_VERSION = VERSION
