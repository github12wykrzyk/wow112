-- SummonScout roster ownership + World destination guard for WoW 1.12.1 / Lua 5.0.
--
-- Roster side:
-- Core roster synchronization historically queued every newly observed party/raid
-- member for Ritual of Summoning. Gate that path on the pendingManualInvites
-- ownership marker written by this client's own eligible invite paths.
--
-- World side:
-- A destination-qualified summoner must never invite a World requester for another
-- known/unknown destination. Re-check the configured service at the final core
-- channel-dispatch boundary, independently of the core's earlier invite decision.
-- This also prunes stale queued World invites after a hot reload/service change.
--
-- Explicit grouped-resume requests continue to call the exported queue API directly
-- and are intentionally unaffected.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "2-own-invite-world-destination"
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
            and type(value.syncPartyRoster) == "function"
            and type(value.handleChannelMessage) == "function" then
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
        and type(S.coreState.queue) == "table"
        and S.coreQueue == api.queuePartySummon then
        return S.coreState
    end

    local i
    for i = 1, 40 do
        local name, value = rgGetUpvalue(api.queuePartySummon, i)
        if not name then break end
        if type(value) == "table"
            and type(value.pendingManualInvites) == "table"
            and type(value.summonPending) == "table"
            and type(value.queue) == "table" then
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
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout guard:|r " .. reason)
    end
end

local function rgServiceContains(locationId)
    local service = rgKey(SummonScoutDB and SummonScoutDB.service or "all")
    if service == "" or service == "all" then return true end
    if not locationId or locationId == "" then return false end

    local haystack = "," .. service .. ","
    local needle = "," .. rgKey(locationId) .. ","
    return string.find(haystack, needle, 1, true) ~= nil
end

local function rgFindNamedFunction(fn, wanted)
    if type(fn) ~= "function" then return nil end
    local i
    for i = 1, 40 do
        local name, value = rgGetUpvalue(fn, i)
        if not name then break end
        if name == wanted and type(value) == "function" then
            return value
        end
    end
    return nil
end

local function rgWorldDestinationBlocked(findLocation, message)
    local service = rgKey(SummonScoutDB and SummonScoutDB.service or "all")
    if service == "" or service == "all" then return false, nil end
    if type(findLocation) ~= "function" then return true, "classifier-unavailable" end

    local loc, ambiguous = findLocation(message or "")
    if ambiguous then return true, "ambiguous" end
    if not loc or not loc.id then return true, "unknown" end
    if not rgServiceContains(loc.id) then
        return true, tostring(loc.label or loc.id)
    end
    return false, tostring(loc.label or loc.id)
end

local function rgPruneWrongDestinationQueue(state)
    if type(state) ~= "table" or type(state.queue) ~= "table" then return end
    local service = rgKey(SummonScoutDB and SummonScoutDB.service or "all")
    if service == "" or service == "all" then return end

    local kept = {}
    local i
    for i = 1, table.getn(state.queue) do
        local item = state.queue[i]
        if type(item) == "table" and item.locationId and rgServiceContains(item.locationId) then
            kept[table.getn(kept) + 1] = item
        else
            if type(item) == "table" and type(state.queued) == "table" then
                state.queued[rgKey(item.name)] = nil
            end
            if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World guard:|r stale queued invite removed -> "
                    .. tostring(type(item) == "table" and item.name or "?"))
            end
        end
    end
    state.queue = kept
end

local function rgPatchWorldDestination(api, state)
    if S.patchedChannelApi == api
        and type(S.channelWrapper) == "function"
        and api.handleChannelMessage == S.channelWrapper then
        rgPruneWrongDestinationQueue(state)
        return true
    end

    local original = api.handleChannelMessage
    if type(original) ~= "function" then
        rgReportFailure("core channel handler unavailable")
        return false
    end

    local findLocation = rgFindNamedFunction(original, "findLocation")
    if type(findLocation) ~= "function" then
        rgReportFailure("findLocation upvalue unavailable")
        return false
    end

    local wrapper = function(message, sender, channelBaseName, channelFullName)
        local blocked, destination = rgWorldDestinationBlocked(findLocation, message)
        if not blocked then
            return original(message, sender, channelBaseName, channelFullName)
        end

        local previousAutoInvite = SummonScoutDB and SummonScoutDB.autoInvite
        if SummonScoutDB then SummonScoutDB.autoInvite = false end

        local ok, err = true, nil
        if pcall then
            ok, err = pcall(original, message, sender, channelBaseName, channelFullName)
        else
            original(message, sender, channelBaseName, channelFullName)
        end

        if SummonScoutDB then SummonScoutDB.autoInvite = previousAutoInvite end

        if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World guard:|r invite blocked -> "
                .. tostring(sender or "?") .. " [" .. tostring(destination or "?")
                .. "], serving=" .. tostring(SummonScoutDB.service or "all"))
        end

        if not ok then error(err) end
        return nil
    end

    api.handleChannelMessage = wrapper
    S.patchedChannelApi = api
    S.channelOriginal = original
    S.channelWrapper = wrapper
    S.channelFindLocation = findLocation
    rgPruneWrongDestinationQueue(state)
    return true
end

local function rgPatchRosterOwnership(api, state)
    if S.patchedSync == api.syncPartyRoster
        and S.patchedQueue == api.queuePartySummon
        and type(S.guardQueue) == "function" then
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
                return true
            end
            rgReportFailure("queue upvalue patch rejected")
            return false
        end
    end

    rgReportFailure("queuePartySummon upvalue not found")
    return false
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

    if not rgPatchWorldDestination(api, state) then return false end
    if not rgPatchRosterOwnership(api, state) then return false end

    S.lastFailure = ""
    return true
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
