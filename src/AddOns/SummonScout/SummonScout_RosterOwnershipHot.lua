-- SummonScout roster ownership guard for WoW 1.12.1 / Lua 5.0.
--
-- Core roster synchronization historically queued every newly observed party/raid
-- member for Ritual of Summoning. That bypasses the destination-qualified invite
-- path: a player invited by somebody else (for example a Silithus buyer seen by a
-- Hyjal-only summoner) could become summon-pending on this client.
--
-- Keep the existing queue machinery, but gate the roster-driven call on the
-- pendingManualInvites ownership marker already written by SummonScout's own
-- eligible World/whisper invite paths. Explicit grouped-resume requests continue
-- to call the exported queue API directly and are intentionally unaffected.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-own-invite-only"
local S = H.GetState("rosterguard")
S.nextPatchAt = tonumber(S.nextPatchAt) or 0
S.lastFailure = S.lastFailure or ""

local function rgNow()
    if GetTime then return GetTime() end
    return 0
end

local function rgTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function rgKey(name)
    return string.lower(rgTrim(name or ""))
end

local function rgGetUpvalue(fn, index)
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

local function rgFindApiInFunction(fn, depth, seen)
    if type(fn) ~= "function" or depth > 5 then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true

    local i
    for i = 1, 40 do
        local name, value = rgGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "table"
            and type(value.queuePartySummon) == "function"
            and type(value.notePendingManualInvite) == "function"
            and type(value.syncPartyRoster) == "function" then
            return value
        end
    end

    for i = 1, 40 do
        local name, value = rgGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "function" then
            local found = rgFindApiInFunction(value, depth + 1, seen)
            if found then return found end
        end
    end
    return nil
end

local function rgResolveApi()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript then return nil end
    local handler = frame:GetScript("OnEvent")
    return rgFindApiInFunction(handler, 0, {})
end

local function rgResolveState(api)
    if type(api) ~= "table" or type(api.queuePartySummon) ~= "function" then return nil end
    if type(S.coreState) == "table"
        and type(S.coreState.pendingManualInvites) == "table"
        and type(S.coreState.summonPending) == "table"
        and S.coreQueue == api.queuePartySummon then
        return S.coreState
    end

    local i
    for i = 1, 40 do
        local name, value = rgGetUpvalue(api.queuePartySummon, i)
        if not name then break end
        if type(value) == "table"
            and type(value.pendingManualInvites) == "table"
            and type(value.summonPending) == "table" then
            S.coreState = value
            S.coreQueue = api.queuePartySummon
            return value
        end
    end
    return nil
end

local function rgReportFailure(reason)
    reason = tostring(reason or "unknown")
    if S.lastFailure == reason then return end
    S.lastFailure = reason
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout roster guard:|r " .. reason)
    end
end

local function rgPatch()
    local api = rgResolveApi()
    if not api then
        rgReportFailure("core API unavailable")
        return false
    end

    local state = rgResolveState(api)
    if not state then
        rgReportFailure("core state unavailable")
        return false
    end

    if S.patchedSync == api.syncPartyRoster
        and S.patchedQueue == api.queuePartySummon
        and type(S.guardQueue) == "function" then
        S.lastFailure = ""
        return true
    end

    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function"
        or type(debug.setupvalue) ~= "function" then
        rgReportFailure("debug.setupvalue unavailable")
        return false
    end

    local original = api.queuePartySummon
    local guard = function(name)
        local current = rgResolveState(api)
        local key = rgKey(name)
        local tracked = current and key ~= ""
            and type(current.pendingManualInvites[key]) == "table"

        if tracked then
            return original(name)
        end

        if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout roster guard:|r unowned join ignored -> "
                .. tostring(name or "?"))
        end
        return nil
    end

    local i
    for i = 1, 40 do
        local name, value = rgGetUpvalue(api.syncPartyRoster, i)
        if not name then break end
        if name == "queuePartySummon" or value == original or value == S.guardQueue then
            local ok, result
            if pcall then
                ok, result = pcall(debug.setupvalue, api.syncPartyRoster, i, guard)
            else
                result = debug.setupvalue(api.syncPartyRoster, i, guard)
                ok = true
            end
            if ok and result then
                S.patchedSync = api.syncPartyRoster
                S.patchedQueue = api.queuePartySummon
                S.guardQueue = guard
                S.coreState = state
                S.coreQueue = api.queuePartySummon
                S.lastFailure = ""
                return true
            end
            rgReportFailure("queue upvalue patch rejected")
            return false
        end
    end

    rgReportFailure("queuePartySummon upvalue not found")
    return false
end

local M = {}

function M.Init()
    S.nextPatchAt = 0
    rgPatch()
end

function M.OnUpdate()
    local t = rgNow()
    if t < (S.nextPatchAt or 0) then return end
    S.nextPatchAt = t + 0.50
    rgPatch()
end

H.Register("rosterguard", M, VERSION)
W112_SUMMONSCOUT_ROSTER_GUARD_VERSION = VERSION
