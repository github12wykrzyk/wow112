-- SummonScout Engine V2 P0 foundation bridge for WoW 1.12.1 / Lua 5.0.
--
-- This is deliberately a compatibility layer, not a gameplay rewrite.
-- It gives the existing SummonScout runtime one explicit public API/state surface
-- and closes the remaining unowned CHAT_MSG_SYSTEM join path before the core can
-- enqueue an unrelated party/raid member for Ritual of Summoning.
--
-- P0.2 can migrate the older hot modules onto W112_SUMMONSCOUT_API_V1 and then
-- remove the fallback upvalue discovery kept here only for the legacy core.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "p0.1-api-ownership"
local S = H.GetState("enginev2foundation")
S.lastFailure = S.lastFailure or ""
S.api = nil
S.coreState = nil

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
    W112_SUMMONSCOUT_API_V1 = api
    W112_SUMMONSCOUT_STATE = state
    W112_SUMMONSCOUT_API_VERSION = 1
    W112_SUMMON_ENGINE_V2_FOUNDATION = VERSION

    api.state = state
    api.apiVersion = 1
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

    local current = frame:GetScript("OnEvent")
    if type(current) ~= "function" then
        S.lastFailure = "core event handler unavailable"
        return false
    end

    -- Avoid stacking our own wrapper if this file is executed twice in one UI generation.
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
                -- Core historically queued CHAT_MSG_SYSTEM joins directly, bypassing
                -- the roster ownership hot guard. Disable only that one dispatch;
                -- explicit grouped/combat resume continues through its existing path.
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
