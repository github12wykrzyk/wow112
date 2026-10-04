-- SummonScout roster ownership + World destination guard for WoW 1.12.1 / Lua 5.0.
--
-- Roster side: only members carrying this client's pendingManualInvites ownership
-- marker may enter the automatic Ritual path through roster synchronization.
-- World side: a destination-qualified summoner never invites a World requester
-- for another known/unknown destination.
-- Buyer side: WTB + taxi + a recognized destination is treated as a summon request
-- even when the player omits the word "summon" (e.g. "WTB Hydraxian taxi").
--
-- P0.2 consumes the explicit Engine V2 API/state. Legacy core upvalue discovery
-- and setupvalue are centralized in SummonScout_EngineV2FoundationHot.lua.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "4-explicit-api-world-buyer-taxi"
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

local function rgNormalize(message)
    local s = string.lower(tostring(message or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return rgTrim(s)
end

local function rgPhraseHas(s, phrase)
    s = rgNormalize(s)
    phrase = rgNormalize(phrase)
    if s == "" or phrase == "" then return false end
    return string.find(" " .. s .. " ", " " .. phrase .. " ", 1, true) ~= nil
end

local function rgResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table"
        or type(api.queuePartySummon) ~= "function"
        or type(api.syncPartyRoster) ~= "function"
        or type(api.handleChannelMessage) ~= "function"
        or type(api.FindLocation) ~= "function"
        or type(api.InstallRosterQueueGuard) ~= "function" then
        return nil
    end
    return api
end

local function rgResolveState(api)
    local state = W112_SUMMONSCOUT_STATE
    if type(state) ~= "table" and type(api) == "table" then state = api.state end
    if type(state) == "table"
        and type(state.pendingManualInvites) == "table"
        and type(state.summonPending) == "table"
        and type(state.queue) == "table" then
        return state
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

local function rgBuyerTaxiMessage(api, message)
    local normalized = rgNormalize(message)
    if not rgPhraseHas(normalized, "wtb") then return message, false, nil end
    if not (rgPhraseHas(normalized, "taxi") or rgPhraseHas(normalized, "t a x i")) then
        return message, false, nil
    end

    local loc, ambiguous = api.FindLocation(message or "")
    if ambiguous or not loc or not loc.id then
        return message, false, nil
    end

    -- The core World parser requires a summon token. Inject one only for this
    -- narrow buyer pattern and keep all destination / blacklist / dedupe gates
    -- in the existing core path.
    if rgPhraseHas(normalized, "summon")
        or rgPhraseHas(normalized, "summons")
        or rgPhraseHas(normalized, "summoning")
        or rgPhraseHas(normalized, "summ")
        or rgPhraseHas(normalized, "sum") then
        return message, false, loc
    end

    return tostring(message or "") .. " summon", true, loc
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
    if S.channelVersion == VERSION and S.patchedChannelApi == api
        and type(S.channelWrapper) == "function"
        and api.handleChannelMessage == S.channelWrapper then
        rgPruneWrongDestinationQueue(state)
        return true
    end

    -- Hot-upgrade cleanly from the previous managed wrapper before installing
    -- the explicit-API generation. No unrelated wrapper is unwrapped.
    if type(S.channelWrapper) == "function" and type(S.channelOriginal) == "function"
        and api.handleChannelMessage == S.channelWrapper then
        api.handleChannelMessage = S.channelOriginal
    end

    local original = api.handleChannelMessage
    if type(original) ~= "function" then
        rgReportFailure("core channel handler unavailable")
        return false
    end

    local wrapper = function(message, sender, channelBaseName, channelFullName)
        local routedMessage, buyerTaxi, buyerLoc = rgBuyerTaxiMessage(api, message)
        local blocked, destination = rgWorldDestinationBlocked(api.FindLocation, routedMessage)
        if not blocked then
            if buyerTaxi and SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World buyer:|r WTB taxi -> summon request: "
                    .. tostring(sender or "?") .. " [" .. tostring(buyerLoc and (buyerLoc.label or buyerLoc.id) or "?") .. "]")
            end
            return original(routedMessage, sender, channelBaseName, channelFullName)
        end

        local previousAutoInvite = SummonScoutDB and SummonScoutDB.autoInvite
        if SummonScoutDB then SummonScoutDB.autoInvite = false end

        local ok, err = true, nil
        if pcall then
            ok, err = pcall(original, routedMessage, sender, channelBaseName, channelFullName)
        else
            original(routedMessage, sender, channelBaseName, channelFullName)
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
    S.channelVersion = VERSION
    rgPruneWrongDestinationQueue(state)
    return true
end

local function rgPatchRosterOwnership(api, state)
    if S.guardVersion == VERSION
        and S.patchedSync == api.syncPartyRoster
        and S.patchedQueue == api.queuePartySummon
        and type(S.guardQueue) == "function" then
        return true
    end

    local original = api.queuePartySummon
    local guard = function(name)
        local current = rgResolveState(api)
        local key = rgKey(name)
        local tracked = current and key ~= ""
            and type(current.pendingManualInvites[key]) == "table"

        if tracked then return original(name) end

        if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout roster guard:|r unowned join ignored -> "
                .. tostring(name or "?"))
        end
        return nil
    end

    local ok, reason = api.InstallRosterQueueGuard(guard)
    if not ok then
        rgReportFailure(reason or "queue guard install rejected")
        return false
    end

    S.patchedSync = api.syncPartyRoster
    S.patchedQueue = api.queuePartySummon
    S.guardQueue = guard
    S.guardVersion = VERSION
    S.coreState = state
    return true
end

local function rgPatch()
    local api = rgResolveApi()
    if not api then
        rgReportFailure("explicit core API unavailable")
        return false
    end

    local state = rgResolveState(api)
    if not state then
        rgReportFailure("explicit core state unavailable")
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

function M.Shutdown()
    S.coreState = nil
end

H.Register("rosterguard", M, VERSION)
W112_SUMMONSCOUT_ROSTER_GUARD_VERSION = VERSION
