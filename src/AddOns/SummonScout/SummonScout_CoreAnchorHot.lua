-- SummonScout canonical core dispatcher anchor + legacy wrapper unwinder.
-- WoW 1.12.1 embeds Lua 5.0. This module is loaded immediately after the
-- persistent HotHost and is also injected as the first HOT fanout prelude.
-- Its job is to make SummonScoutFrame's true core OnEvent identity explicit,
-- peel known historical wrapper closures from live sessions, and reset the
-- frame before any new fanout generation installs wrappers.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-canonical-anchor-unwind"
local A = H.GetState("coreanchor")
local MAX_UPVALUES = 32
local MAX_DEPTH = 64

local BASE_UPVALUE_NAMES = {
    OWN_BASE = true,
    OWN_CORE_BASE = true,
    coreBase = true,
    current = true,
    originalOnEvent = true,
    base = true,
    eventBase = true,
    wrappedBase = true,
}

local function caNow()
    if GetTime then return GetTime() end
    return 0
end

local function caGetUpvalue(fn, index)
    if not debug or type(debug.getupvalue) ~= "function" then return nil, nil end
    if type(fn) ~= "function" then return nil, nil end
    return debug.getupvalue(fn, index)
end

local function caFindWrappedBase(fn)
    local i
    for i = 1, MAX_UPVALUES do
        local name, value = caGetUpvalue(fn, i)
        if not name then break end
        if BASE_UPVALUE_NAMES[name] and type(value) == "function" then
            return value, name
        end
    end
    return nil, nil
end

local function caUnwind(fn)
    if type(fn) ~= "function" then return nil, 0, "not-function", "" end

    local current = fn
    local seen = {}
    local path = {}
    local depth = 0

    while type(current) == "function" and depth < MAX_DEPTH do
        if seen[current] then
            return current, depth, "cycle", table.concat(path, ">")
        end
        seen[current] = true

        local nextFn, upName = caFindWrappedBase(current)
        if type(nextFn) ~= "function" or nextFn == current then
            return current, depth, "base", table.concat(path, ">")
        end

        path[table.getn(path) + 1] = tostring(upName or "?")
        current = nextFn
        depth = depth + 1
    end

    if depth >= MAX_DEPTH then
        return current, depth, "depth-limit", table.concat(path, ">")
    end
    return current, depth, "base", table.concat(path, ">")
end

local function caInstall()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then
        A.lastStatus = "frame-unavailable"
        return false
    end

    local candidate = nil
    if type(W112_SUMMONSCOUT_CORE_BASE_ON_EVENT) == "function" then
        candidate = W112_SUMMONSCOUT_CORE_BASE_ON_EVENT
    else
        candidate = frame:GetScript("OnEvent")
    end

    local base, depth, status, path = caUnwind(candidate)
    if type(base) ~= "function" then
        A.lastStatus = "base-unavailable"
        return false
    end

    -- If an older global anchor was itself captured from an already wrapped
    -- session, caUnwind peels it too. The repaired function becomes the only
    -- authoritative core dispatcher identity from this point onward.
    W112_SUMMONSCOUT_CORE_BASE_ON_EVENT = base
    H.coreBaseOnEvent = base
    frame:SetScript("OnEvent", base)

    A.version = VERSION
    A.lastDepth = depth
    A.lastStatus = status
    A.lastPath = path
    A.lastRepairAt = caNow()
    A.repairs = (tonumber(A.repairs) or 0) + 1
    if depth > 0 then
        A.legacyRepairs = (tonumber(A.legacyRepairs) or 0) + 1
    end

    W112_SUMMONSCOUT_CORE_ANCHOR_DEPTH = depth
    W112_SUMMONSCOUT_CORE_ANCHOR_PATH = path
    return true
end

local M = {}

function M.Init()
    caInstall()
end

-- Deliberately do not restore the pre-anchor wrapper chain. PrepareFanoutReload
-- wants all other modules to shut down, then the canonical core anchor to remain
-- installed as the clean base for the next generation.
function M.Shutdown()
end

H.Register("coreanchor", M, VERSION)
W112_SUMMONSCOUT_CORE_ANCHOR_VERSION = VERSION
