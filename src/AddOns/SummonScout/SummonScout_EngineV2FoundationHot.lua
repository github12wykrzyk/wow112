-- SummonScout Engine V2 P0 foundation bridge for WoW 1.12.1 / Lua 5.0.
--
-- P0.3b receives EventAPI / SS directly from canonical SummonScout.lua.
-- Legacy debug introspection remains only for the still-private location / roster
-- compatibility hooks; API/state discovery itself is now core-native and fail closed.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "p0.3d-direct-location"
local S = H.GetState("enginev2foundation")
S.lastFailure = S.lastFailure or ""
S.api = nil
S.coreState = nil
S.compat = S.compat or {}

local function fTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function fKey(name)
    return string.lower(fTrim(name or ""))
end

local function fGetUpvalue(fn, index)
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

local function fSetUpvalue(fn, index, value)
    if type(debug) ~= "table" or type(debug.setupvalue) ~= "function" then
        return false, "debug.setupvalue unavailable"
    end
    if pcall then
        local ok, result = pcall(debug.setupvalue, fn, index, value)
        if not ok or not result then return false, "setupvalue rejected" end
        return true, result
    end
    local result = debug.setupvalue(fn, index, value)
    if not result then return false, "setupvalue rejected" end
    return true, result
end

local function fNamedFunction(fn, wanted)
    if type(fn) ~= "function" then return nil end
    local i
    for i = 1, 40 do
        local name, value = fGetUpvalue(fn, i)
        if not name then break end
        if name == wanted and type(value) == "function" then return value end
    end
    return nil
end

local function fNamedOrValueIndex(fn, wanted, expected)
    if type(fn) ~= "function" then return nil end
    local i
    for i = 1, 40 do
        local name, value = fGetUpvalue(fn, i)
        if not name then break end
        if name == wanted or (expected ~= nil and value == expected) then return i end
    end
    return nil
end

local function fResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table"
        and type(api.queuePartySummon) == "function"
        and type(api.notePendingManualInvite) == "function"
        and type(api.syncPartyRoster) == "function"
        and type(api.handleChannelMessage) == "function" then
        return api
    end
    return nil
end

local function fResolveState(api)
    local state = W112_SUMMONSCOUT_STATE
    if type(state) == "table"
        and type(state.pendingManualInvites) == "table"
        and type(state.summonPending) == "table"
        and type(state.queue) == "table" then
        return state
    end
    return nil
end

local function fResolveCompat(api)
    if type(api) ~= "table" then return nil end
    local C = S.compat
    if C.api == api and type(C.findLocation) == "function"
        and type(C.locationCatalog) == "table" and C.locationRootIndex then
        return C
    end

    C = {}
    C.api = api
    C.findLocation = fNamedFunction(api.whisperInviteDecision, "findLocation")
        or fNamedFunction(api.handleChannelMessage, "findLocation")
    if type(C.findLocation) == "function" then
        C.findLocations = fNamedFunction(C.findLocation, "findLocationsInMessage")
    end

    if type(C.findLocations) == "function" then
        local i
        for i = 1, 40 do
            local name, value = fGetUpvalue(C.findLocations, i)
            if not name then break end
            if name == "LOCATIONS" and type(value) == "table" then
                C.locationCatalog = value
            elseif name == "tokenHasRoot" and type(value) == "function" then
                C.locationRootIndex = i
                C.locationRootMatcher = value
            end
        end
    end

    C.rosterSync = api.syncPartyRoster
    C.rosterQueueIndex = fNamedOrValueIndex(api.syncPartyRoster, "queuePartySummon", api.queuePartySummon)
    S.compat = C
    return C
end

local function fJoinedName(line)
    line = fTrim(line or "")
    local _, _, name = string.find(line, "^(.+) has joined the raid group%.?$")
    if not name then _, _, name = string.find(line, "^(.+) has joined the party%.?$") end
    if not name then _, _, name = string.find(line, "^(.+) joins the party%.?$") end
    name = fTrim(name or "")
    if name == "" then return nil end
    return name
end

local function fHasInviteOwnership(state, name)
    if type(state) ~= "table" or type(state.pendingManualInvites) ~= "table" then
        return false
    end
    local key = fKey(name)
    return key ~= "" and type(state.pendingManualInvites[key]) == "table"
end

local function fInGroup(api, name)
    if type(api) ~= "table" or type(api.isInGroup) ~= "function" then return false end
    if pcall then
        local ok, grouped = pcall(api.isInGroup, name)
        return ok and grouped and true or false
    end
    return api.isInGroup(name) and true or false
end

local function fChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00Summon Engine P0:|r " .. tostring(text or ""))
    end
end

local function fInstall()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then
        S.lastFailure = "core frame unavailable"
        return false
    end

    local api = fResolveApi()
    if type(api) ~= "table" then
        S.lastFailure = "core API unavailable"
        return false
    end

    local state = fResolveState(api)
    if type(state) ~= "table" then
        S.lastFailure = "core state unavailable"
        return false
    end

    local rawQueue = nil
    if S.api == api and type(S.publicQueuePartySummon) == "function"
        and api.queuePartySummon == S.publicQueuePartySummon then
        rawQueue = S.rawQueuePartySummon
    else
        rawQueue = api.queuePartySummon
    end
    if type(rawQueue) ~= "function" then
        S.lastFailure = "raw summon queue unavailable"
        return false
    end

    S.api = api
    S.coreState = state
    S.compat = {}
    W112_SUMMONSCOUT_API_V1 = api
    W112_SUMMONSCOUT_STATE = state
    W112_SUMMONSCOUT_API_VERSION = 1
    W112_SUMMONSCOUT_COMPAT_VERSION = 5
    W112_SUMMON_ENGINE_V2_FOUNDATION = VERSION

    api.state = state
    api.apiVersion = 1
    api.compatVersion = 5
    api.GetState = function()
        return state
    end
    api.HasInviteOwnership = function(name)
        return fHasInviteOwnership(state, name)
    end

    local explicitQueue = function(name, source)
        source = tostring(source or "")
        if source ~= "grouped-resume" and source ~= "combat-resume" and source ~= "manual-explicit" then
            return false, "source-rejected"
        end

        if source == "grouped-resume" or source == "combat-resume" then
            if not fInGroup(api, name) then return false, "not-grouped" end
        elseif not fHasInviteOwnership(state, name) and not fInGroup(api, name) then
            return false, "ownership-required"
        end

        rawQueue(name)
        return true, source
    end

    local publicQueue = function(name, source)
        source = tostring(source or "")
        if source ~= "" then return explicitQueue(name, source) end
        if not fHasInviteOwnership(state, name) then
            return false, "ownership-required"
        end
        rawQueue(name)
        return true, "owned-join"
    end

    S.rawQueuePartySummon = rawQueue
    S.publicQueuePartySummon = publicQueue
    S.explicitQueuePartySummon = explicitQueue
    api.queuePartySummon = publicQueue
    api.QueuePartySummonExplicit = explicitQueue

    -- Do not depend on Lua upvalue layout for destination lookup. The canonical
    -- whisper classifier already resolves destinations before evaluating intent,
    -- so reuse its returned location as the stable runtime surface. Exact
    -- destination strings such as "hyjal" yield loc even when intent is weak.
    api.FindLocation = function(message)
        if type(api.whisperInviteDecision) == "function" then
            local _accept, loc, reason = api.whisperInviteDecision(message or "")
            if type(loc) == "table" then return loc, nil end
            if reason == "ambiguous-location" then return nil, true end
        end
        local C = fResolveCompat(api)
        if C and type(C.findLocation) == "function" then
            return C.findLocation(message or "")
        end
        return nil, nil
    end
    api.GetLocationCatalog = function()
        local C = fResolveCompat(api)
        if not C or type(C.locationCatalog) ~= "table" then return nil end
        return C.locationCatalog
    end
    api.InstallLocationRootMatcher = function(fn)
        if type(fn) ~= "function" then return false, "invalid matcher" end
        local C = fResolveCompat(api)
        if not C or type(C.findLocations) ~= "function" or not C.locationRootIndex then
            return false, "location internals unavailable"
        end
        local ok, reason = fSetUpvalue(C.findLocations, C.locationRootIndex, fn)
        if ok then C.locationRootMatcher = fn end
        return ok, reason
    end
    api.InstallRosterQueueGuard = function(fn)
        if type(fn) ~= "function" then return false, "invalid guard" end
        local C = fResolveCompat(api)
        if not C or C.rosterSync ~= api.syncPartyRoster or not C.rosterQueueIndex then
            S.compat = {}
            C = fResolveCompat(api)
        end
        if not C or type(api.syncPartyRoster) ~= "function" or not C.rosterQueueIndex then
            return false, "roster queue internals unavailable"
        end
        local ok, reason = fSetUpvalue(api.syncPartyRoster, C.rosterQueueIndex, fn)
        if ok then C.rosterQueueGuard = fn end
        return ok, reason
    end

    fResolveCompat(api)

    local current = frame:GetScript("OnEvent")
    if type(current) ~= "function" then
        S.lastFailure = "core event handler unavailable"
        return false
    end

    if S.wrapper and S.base and current == S.wrapper then
        current = S.base
        frame:SetScript("OnEvent", current)
    end

    local wrapper = function()
        local restoreAutoSummon = nil
        local joined = nil

        if event == "CHAT_MSG_SYSTEM" and SummonScoutDB and SummonScoutDB.partyAutoSummon then
            joined = fJoinedName(arg1 or "")
            if joined and not fHasInviteOwnership(state, joined) then
                restoreAutoSummon = SummonScoutDB.partyAutoSummon
                SummonScoutDB.partyAutoSummon = false
                if SummonScoutDB.debug then
                    fChat("unowned system join blocked -> " .. joined)
                end
            end
        end

        local ok, err = true, nil
        if pcall then
            ok, err = pcall(current)
        else
            current()
        end

        if restoreAutoSummon ~= nil and SummonScoutDB then
            SummonScoutDB.partyAutoSummon = restoreAutoSummon
        end
        if not ok then error(err) end
    end

    S.base = current
    S.wrapper = wrapper
    frame:SetScript("OnEvent", wrapper)
    S.lastFailure = ""
    return true
end

local M = {}

function M.Init()
    if not fInstall() and SummonScoutDB and SummonScoutDB.debug then
        fChat("foundation inactive: " .. tostring(S.lastFailure or "unknown"))
    end
end

H.Register("enginev2foundation", M, VERSION)
