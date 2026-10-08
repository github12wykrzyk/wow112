-- SummonScout roster ownership + World destination guard for WoW 1.12.1 / Lua 5.0.
--
-- Roster side: only members carrying this client's pendingManualInvites ownership
-- marker may enter the automatic Ritual path through roster synchronization.
-- World side: a destination-qualified summoner never invites a World requester
-- for another known/unknown destination.
-- Buyer side: destination-qualified buyer shorthand is normalized into the
-- canonical core request path even when the player omits the word "summon".
-- Multi-destination buyer requests fail closed instead of picking the first
-- catalog match.
--
-- P0.2 consumes the explicit Engine V2 API/state. Legacy core upvalue discovery
-- and setupvalue are centralized in SummonScout_EngineV2FoundationHot.lua.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "6-world-intent-multidest-guard"
local S = H.GetState("rosterguard")
S.nextPatchAt = tonumber(S.nextPatchAt) or 0
S.lastFailure = S.lastFailure or ""
S.nextLeaderHandoffAt = tonumber(S.nextLeaderHandoffAt) or 0
S.lastLeaderHandoffTarget = S.lastLeaderHandoffTarget or ""

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

local function rgTokenHasRoot(s, root)
    s = rgNormalize(s)
    root = rgNormalize(root)
    if string.len(root) < 5 then return false end
    local token
    for token in string.gfind(s, "%S+") do
        if string.len(token) >= string.len(root)
            and string.sub(token, 1, string.len(root)) == root then
            return true
        end
    end
    return false
end

local function rgHasCue(s, cues)
    local i
    for i = 1, table.getn(cues) do
        if rgPhraseHas(s, cues[i]) then return true end
    end
    return false
end

local WORLD_BUYER_CUES = {
    "wtb", "need", "lf", "looking for", "want", "pls", "plz", "please",
    "can i", "could i", "anyone", "anybody", "who can", "inv", "invite",
    "port", "taxi"
}

local WORLD_DIRECT_REQUEST_CUES = {
    "summon me", "sum me", "can someone summon", "can somebody summon",
    "can you summon", "could you summon", "anyone can summon", "anybody can summon",
    "who can summon", "who can summ"
}

local WORLD_SELLER_CUES = {
    "wts", "selling", "sell", "service", "available", "offering",
    "summons available", "summon service", "summoning service",
    "selling summon", "sell summon", "summoning to", "summoning portals",
    "portal service", "pst", "whisper me", "dm me", "travel service"
}

local function rgHasSummonToken(s)
    s = rgNormalize(s)
    return rgPhraseHas(s, "summon")
        or rgPhraseHas(s, "summons")
        or rgPhraseHas(s, "summoning")
        or rgPhraseHas(s, "summ")
        or rgPhraseHas(s, "summs")
        or rgPhraseHas(s, "sum")
        or rgPhraseHas(s, "sumon")
end

local function rgResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table"
        or type(api.queuePartySummon) ~= "function"
        or type(api.syncPartyRoster) ~= "function"
        or type(api.handleChannelMessage) ~= "function"
        or type(api.FindLocation) ~= "function"
        or type(api.GetLocationCatalog) ~= "function"
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

local function rgFindLocations(api, message)
    local result = {}
    local seen = {}
    local catalog = api and api.GetLocationCatalog and api.GetLocationCatalog() or nil
    local normalized = rgNormalize(message)
    local i, j

    if type(catalog) == "table" then
        for i = 1, table.getn(catalog) do
            local loc = catalog[i]
            local matched = false
            if type(loc) == "table" and loc.id then
                if type(loc.aliases) == "table" then
                    for j = 1, table.getn(loc.aliases) do
                        if rgPhraseHas(normalized, loc.aliases[j]) then
                            matched = true
                            break
                        end
                    end
                end
                if not matched and type(loc.roots) == "table" then
                    for j = 1, table.getn(loc.roots) do
                        if rgTokenHasRoot(normalized, loc.roots[j]) then
                            matched = true
                            break
                        end
                    end
                end
                if matched and not seen[rgKey(loc.id)] then
                    seen[rgKey(loc.id)] = true
                    result[table.getn(result) + 1] = loc
                end
            end
        end
    end

    if table.getn(result) == 0 and api and type(api.FindLocation) == "function" then
        local loc, ambiguous = api.FindLocation(message or "")
        if loc and not ambiguous then result[1] = loc end
    end
    return result
end

local function rgLocationsLabel(locations)
    local labels = {}
    local i
    for i = 1, table.getn(locations or {}) do
        local loc = locations[i]
        labels[table.getn(labels) + 1] = tostring(loc.label or loc.id or "?")
    end
    if table.getn(labels) == 0 then return "UNKNOWN" end
    return table.concat(labels, " + ")
end

local function rgBuyerLike(message)
    local s = rgNormalize(message)
    if rgHasCue(s, WORLD_BUYER_CUES) then return true end
    if rgHasCue(s, WORLD_DIRECT_REQUEST_CUES) then return true end
    return false
end

local function rgSellerLike(message, locations)
    local s = rgNormalize(message)
    if rgHasCue(s, WORLD_SELLER_CUES) then return true end

    -- Paid multi-route menus are competitor advertisements, not ambiguous buyers.
    if table.getn(locations or {}) >= 2 and string.find(s, "%d+%s*g") then
        return true
    end
    return false
end

local function rgPrepareWorldBuyer(api, message)
    local normalized = rgNormalize(message)
    local locations = rgFindLocations(api, message)
    local buyerLike = rgBuyerLike(message)
    local sellerLike = rgSellerLike(message, locations)

    if table.getn(locations) > 1 and buyerLike and not sellerLike then
        return message, false, locations, "multiple-destinations"
    end

    if table.getn(locations) ~= 1 or not buyerLike or sellerLike or rgHasSummonToken(normalized) then
        return message, false, locations, nil
    end

    -- Keep blacklist, ownership, dedupe, logging and queue semantics in the
    -- canonical core. We only provide the missing lexical summon token.
    return tostring(message or "") .. " summon", true, locations, nil
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
        local routedMessage, injected, locations, parserBlock = rgPrepareWorldBuyer(api, message)
        local blocked, destination = false, nil

        if parserBlock == "multiple-destinations" then
            blocked = true
            destination = rgLocationsLabel(locations)
        else
            blocked, destination = rgWorldDestinationBlocked(api.FindLocation, routedMessage)
        end

        if not blocked then
            if injected and SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World buyer:|r shorthand -> summon request: "
                    .. tostring(sender or "?") .. " [" .. rgLocationsLabel(locations) .. "]")
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
            local reason = parserBlock == "multiple-destinations" and "multiple destinations" or "destination ownership"
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World guard:|r invite blocked -> "
                .. tostring(sender or "?") .. " [" .. tostring(destination or "?")
                .. "] reason=" .. reason .. ", serving=" .. tostring(SummonScoutDB.service or "all"))
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

local LEADER_HANDOFF_PRIORITY = {
    "teletanaris",
    "bolthyjal",
    "feltaxi",
}

local function rgTryLevelOneLeaderHandoff()
    if type(UnitLevel) ~= "function" or type(UnitIsPartyLeader) ~= "function"
        or type(UnitName) ~= "function" or type(GetNumPartyMembers) ~= "function"
        or type(PromoteByName) ~= "function" then
        return
    end

    if UnitLevel("player") ~= 1 or not UnitIsPartyLeader("player") then
        S.lastLeaderHandoffTarget = ""
        return
    end

    local count = GetNumPartyMembers() or 0
    if count <= 0 then return end

    local wanted, i, j, name
    for i = 1, table.getn(LEADER_HANDOFF_PRIORITY) do
        wanted = LEADER_HANDOFF_PRIORITY[i]
        for j = 1, count do
            name = UnitName("party" .. j)
            if name and rgKey(name) == wanted then
                PromoteByName(name)
                S.lastLeaderHandoffTarget = wanted
                if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout roster:|r lvl 1 leader -> " .. tostring(name))
                end
                return
            end
        end
    end
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
    S.nextLeaderHandoffAt = 0
    rgPatch()
    rgTryLevelOneLeaderHandoff()
end

function M.OnUpdate()
    local t = rgNow()
    if t < (S.nextPatchAt or 0) then return end
    S.nextPatchAt = t + 0.50
    rgPatch()
    if t >= (S.nextLeaderHandoffAt or 0) then
        S.nextLeaderHandoffAt = t + 2.00
        rgTryLevelOneLeaderHandoff()
    end
end

function M.Shutdown()
    S.coreState = nil
end

H.Register("rosterguard", M, VERSION)
W112_SUMMONSCOUT_ROSTER_GUARD_VERSION = VERSION
