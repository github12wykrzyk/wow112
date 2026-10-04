-- SummonScout Engine V2 P0 foundation bridge for WoW 1.12.1 / Lua 5.0.
--
-- P0.2 keeps all legacy-core introspection in this one compatibility layer.
-- Hot modules consume W112_SUMMONSCOUT_API_V1 / W112_SUMMONSCOUT_STATE and no
-- longer walk the core dispatcher closure on their own.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "p0.2-explicit-api"
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

local function fFindApi(fn, depth, seen)
    if type(fn) ~= "function" or depth > 6 then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true

    local i
    for i = 1, 40 do
        local name, value = fGetUpvalue(fn, i)
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
        local name, value = fGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "function" then
            local found = fFindApi(value, depth + 1, seen)
            if found then return found end
        end
    end
    return nil
end

local function fFindState(fn, depth, seen)
    if type(fn) ~= "function" or depth > 4 then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true

    local i
    for i = 1, 40 do
        local name, value = fGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "table"
            and type(value.pendingManualInvites) == "table"
            and type(value.summonPending) == "table"
            and type(value.queue) == "table" then
            return value
        end
    end

    for i = 1, 40 do
        local name, value = fGetUpvalue(fn, i)
        if not name then break end
        if type(value) == "function" then
            local found = fFindState(value, depth + 1, seen)
            if found then return found end
        end
    end
    return nil
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
        and type(api.handleChannelMessage) == "function" then
        return api
    end

    local frame = SummonScoutFrame
    if not frame or not frame.GetScript then return nil end
    return fFindApi(frame:GetScript("OnEvent"), 0, {})
end

local function fResolveState(api)
    if type(W112_SUMMONSCOUT_STATE) == "table"
        and type(W112_SUMMONSCOUT_STATE.pendingManualInvites) == "table" then
        return W112_SUMMONSCOUT_STATE
    end
    if type(S.coreState) == "table"
        and type(S.coreState.pendingManualInvites) == "table" then
        return S.coreState
    end
    if type(api) ~= "table" then return nil end

    local candidates = {
        api.queuePartySummon,
        api.notePendingManualInvite,
        api.syncPartyRoster
    }
    local i
    for i = 1, table.getn(candidates) do
        local state = fFindState(candidates[i], 0, {})
        if state then return state end
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
    C.findLocation = fNamedFunction(api.handleChannelMessage, "findLocation")
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

    S.api = api
    S.coreState = state
    S.compat = {}
    W112_SUMMONSCOUT_API_V1 = api
    W112_SUMMONSCOUT_STATE = state
    W112_SUMMONSCOUT_API_VERSION = 1
    W112_SUMMONSCOUT_COMPAT_VERSION = 2
    W112_SUMMON_ENGINE_V2_FOUNDATION = VERSION

    api.state = state
    api.apiVersion = 1
    api.compatVersion = 2
    api.GetState = function()
        return state
    end
    api.HasInviteOwnership = function(name)
        return fHasInviteOwnership(state, name)
    end
    api.QueuePartySummonExplicit = function(name, source)
        source = tostring(source or "")
        if source ~= "grouped-resume" and source ~= "combat-resume" and source ~= "manual-explicit" then
            return false, "source-rejected"
        end
        api.queuePartySummon(name)
        return true, source
    end
    api.FindLocation = function(message)
        local C = fResolveCompat(api)
        if not C or type(C.findLocation) ~= "function" then return nil, true end
        return C.findLocation(message or "")
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

    -- Resolve once here so all hot modules share the same legacy-core map.
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
