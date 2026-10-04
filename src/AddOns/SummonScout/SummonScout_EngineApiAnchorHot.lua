-- SummonScout Engine V2 HOT API anchor for WoW 1.12.1 / Lua 5.0.
--
-- EngineV2FoundationHot historically reset its persisted S.api marker on every
-- fanout execution. That made a previous publicQueue wrapper look like the new
-- raw queue and allowed queue wrappers to accumulate across HOT generations.
-- This module canonicalizes that API boundary after every fanout: it unwinds
-- known queue-wrapper closures to the deepest raw core queue and publishes one
-- managed ownership wrapper. Shutdown restores the raw queue before the next
-- generation starts, so wrapper depth cannot grow with repeated HOT updates.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-engine-api-anchor"
local S = H.GetState("engineapianchor")
S.unwindDepth = tonumber(S.unwindDepth) or 0
S.maxUnwindDepth = tonumber(S.maxUnwindDepth) or 0
S.lastFailure = S.lastFailure or ""
S.nextVerifyAt = tonumber(S.nextVerifyAt) or 0

local MAX_UPVALUES = 48
local MAX_UNWIND = 64
local OWN_API = nil
local OWN_RAW_QUEUE = nil
local OWN_PUBLIC_QUEUE = nil
local OWN_EXPLICIT_QUEUE = nil
local OWN_PREVIOUS_EXPLICIT = nil

local function eaNow()
    if GetTime then return GetTime() end
    return 0
end

local function eaTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function eaKey(name)
    return string.lower(eaTrim(name or ""))
end

local function eaGetUpvalue(fn, index)
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
        return nil, nil
    end
    if pcall then
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if ok then return name, value end
        return nil, nil
    end
    return debug.getupvalue(fn, index)
end

local function eaOwned(state, name)
    if type(state) ~= "table" or type(state.pendingManualInvites) ~= "table" then
        return false
    end
    local key = eaKey(name)
    return key ~= "" and type(state.pendingManualInvites[key]) == "table"
end

local function eaInGroup(api, name)
    if type(api) ~= "table" or type(api.isInGroup) ~= "function" then return false end
    if pcall then
        local ok, grouped = pcall(api.isInGroup, name)
        return ok and grouped and true or false
    end
    return api.isInGroup(name) and true or false
end

local function eaNestedRaw(fn)
    if type(fn) ~= "function" then return nil end
    local i
    for i = 1, MAX_UPVALUES do
        local name, value = eaGetUpvalue(fn, i)
        if not name then break end
        if (name == "rawQueue" or name == "ANCHOR_RAW_QUEUE" or name == "OWN_RAW_QUEUE")
            and type(value) == "function" and value ~= fn then
            return value
        end
    end
    return nil
end

local function eaUnwindQueue(fn)
    if type(fn) ~= "function" then return nil, 0, "queue-not-function" end
    local current = fn
    local seen = {}
    local depth = 0

    while type(current) == "function" and depth < MAX_UNWIND do
        if seen[current] then return nil, depth, "queue-wrapper-cycle" end
        seen[current] = true

        if S.publicQueuePartySummon and current == S.publicQueuePartySummon
            and type(S.rawQueuePartySummon) == "function" then
            current = S.rawQueuePartySummon
            depth = depth + 1
        else
            local nested = eaNestedRaw(current)
            if type(nested) ~= "function" then break end
            current = nested
            depth = depth + 1
        end
    end

    if depth >= MAX_UNWIND then return nil, depth, "queue-unwind-limit" end
    return current, depth, nil
end

local function eaResolve()
    local api = W112_SUMMONSCOUT_API_V1
    local state = W112_SUMMONSCOUT_STATE
    if type(api) ~= "table" or type(api.queuePartySummon) ~= "function" then
        return nil, nil, "core-api-unavailable"
    end
    if type(state) ~= "table" or type(state.pendingManualInvites) ~= "table" then
        return nil, nil, "core-state-unavailable"
    end
    return api, state, nil
end

local function eaDetachOwn()
    if OWN_API and OWN_API.queuePartySummon == OWN_PUBLIC_QUEUE and type(OWN_RAW_QUEUE) == "function" then
        OWN_API.queuePartySummon = OWN_RAW_QUEUE
    end
    if OWN_API and OWN_API.QueuePartySummonExplicit == OWN_EXPLICIT_QUEUE then
        OWN_API.QueuePartySummonExplicit = OWN_PREVIOUS_EXPLICIT
    end
end

local function eaInstall()
    eaDetachOwn()

    local api, state, reason = eaResolve()
    if not api then
        S.lastFailure = tostring(reason or "resolve-failed")
        return false
    end

    local rawQueue, depth, unwindError = eaUnwindQueue(api.queuePartySummon)
    if type(rawQueue) ~= "function" then
        S.lastFailure = tostring(unwindError or "raw-queue-unavailable")
        return false
    end

    local previousExplicit = api.QueuePartySummonExplicit
    local ANCHOR_RAW_QUEUE = rawQueue

    local explicitQueue = function(name, source)
        source = tostring(source or "")
        if source ~= "grouped-resume" and source ~= "combat-resume" and source ~= "manual-explicit" then
            return false, "source-rejected"
        end

        if source == "grouped-resume" or source == "combat-resume" then
            if not eaInGroup(api, name) then return false, "not-grouped" end
        elseif not eaOwned(state, name) and not eaInGroup(api, name) then
            return false, "ownership-required"
        end

        ANCHOR_RAW_QUEUE(name)
        return true, source
    end

    local publicQueue = function(name, source)
        source = tostring(source or "")
        if source ~= "" then return explicitQueue(name, source) end
        if not eaOwned(state, name) then return false, "ownership-required" end
        ANCHOR_RAW_QUEUE(name)
        return true, "owned-join"
    end

    OWN_API = api
    OWN_RAW_QUEUE = rawQueue
    OWN_PUBLIC_QUEUE = publicQueue
    OWN_EXPLICIT_QUEUE = explicitQueue
    OWN_PREVIOUS_EXPLICIT = previousExplicit

    S.api = api
    S.rawQueuePartySummon = rawQueue
    S.publicQueuePartySummon = publicQueue
    S.explicitQueuePartySummon = explicitQueue
    S.unwindDepth = depth
    if depth > (tonumber(S.maxUnwindDepth) or 0) then S.maxUnwindDepth = depth end
    S.lastFailure = ""
    S.installedAt = eaNow()

    api.queuePartySummon = publicQueue
    api.QueuePartySummonExplicit = explicitQueue
    W112_SUMMONSCOUT_ENGINE_API_ANCHOR_VERSION = VERSION
    W112_SUMMONSCOUT_ENGINE_API_ANCHOR_UNWIND_DEPTH = depth
    return true
end

local M = {}

function M.Init()
    S.nextVerifyAt = 0
    eaInstall()
end

function M.OnUpdate()
    local t = eaNow()
    if t < (tonumber(S.nextVerifyAt) or 0) then return end
    S.nextVerifyAt = t + 1.0

    local api = W112_SUMMONSCOUT_API_V1
    if api ~= OWN_API or type(api) ~= "table" or api.queuePartySummon ~= OWN_PUBLIC_QUEUE then
        eaInstall()
    end
end

function M.Shutdown()
    eaDetachOwn()
    OWN_API = nil
    OWN_RAW_QUEUE = nil
    OWN_PUBLIC_QUEUE = nil
    OWN_EXPLICIT_QUEUE = nil
    OWN_PREVIOUS_EXPLICIT = nil
end

H.Register("engineapianchor", M, VERSION)
