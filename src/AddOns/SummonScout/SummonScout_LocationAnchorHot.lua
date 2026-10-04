-- SummonScout tolerant location-anchor matcher for WoW 1.12.1 / Lua 5.0.
--
-- Exact aliases remain authoritative. This hot module augments every location
-- with a short, distinctive anchor derived from its dictionary aliases/ID and
-- makes root matching substring-based. Example: Winterspring -> "winter", so
-- "winterspri", "winterspf" and "xxxwinterspring" still classify correctly.
-- Generated anchors that collide between different locations are discarded.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-anchor-dict"
local S = H.GetState("locationanchor")
S.nextPatchAt = tonumber(S.nextPatchAt) or 0
S.lastFailure = S.lastFailure or ""
S.generatedCount = tonumber(S.generatedCount) or 0

local function laNow()
    if GetTime then return GetTime() end
    return 0
end

local function laNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function laGetUpvalue(fn, index)
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

local function laFindApi()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript then return nil end
    local handler = frame:GetScript("OnEvent")
    if type(handler) ~= "function" then return nil end

    local i
    for i = 1, 40 do
        local name, value = laGetUpvalue(handler, i)
        if not name then break end
        if type(value) == "table"
            and type(value.handleChannelMessage) == "function"
            and type(value.normalizeMessage) == "function" then
            return value
        end
    end
    return nil
end

local function laNamedFunctionUpvalue(fn, wanted)
    if type(fn) ~= "function" then return nil end
    local i
    for i = 1, 40 do
        local name, value = laGetUpvalue(fn, i)
        if not name then break end
        if name == wanted and type(value) == "function" then
            return value
        end
    end
    return nil
end

local function laResolveMatcher(api)
    if type(api) ~= "table" or type(api.handleChannelMessage) ~= "function" then
        return nil, nil
    end

    local findLocation = laNamedFunctionUpvalue(api.handleChannelMessage, "findLocation")
    if not findLocation then return nil, nil end

    local findLocations = laNamedFunctionUpvalue(findLocation, "findLocationsInMessage")
    if not findLocations then return nil, nil end

    local locations = nil
    local rootIndex = nil
    local i
    for i = 1, 40 do
        local name, value = laGetUpvalue(findLocations, i)
        if not name then break end
        if name == "LOCATIONS" and type(value) == "table" then
            locations = value
        elseif name == "tokenHasRoot" and type(value) == "function" then
            rootIndex = i
        end
    end
    return findLocations, locations, rootIndex
end

local function laCandidateKey(token)
    token = laNormalize(token)
    token = string.gsub(token, "%s+", "")
    local n = string.len(token)
    if n < 5 then return nil end
    if n >= 8 then return string.sub(token, 1, 6) end
    return string.sub(token, 1, 5)
end

local function laCollectCandidates(loc, out)
    local function add(value)
        local key = laCandidateKey(value)
        if key and key ~= "" then out[key] = true end
    end

    add(loc.id)

    local aliases = loc.aliases
    if type(aliases) ~= "table" then return end

    local i
    for i = 1, table.getn(aliases) do
        local alias = laNormalize(aliases[i])
        local token
        for token in string.gfind(alias, "%S+") do
            add(token)
        end
        add(alias)
    end
end

local function laInstallRoots(locations)
    if type(locations) ~= "table" then return 0 end

    local owners = {}
    local perLocation = {}
    local j
    for j = 1, table.getn(locations) do
        local candidates = {}
        perLocation[j] = candidates
        laCollectCandidates(locations[j], candidates)

        local key
        for key in pairs(candidates) do
            if owners[key] == nil then
                owners[key] = j
            elseif owners[key] ~= j then
                owners[key] = false
            end
        end
    end

    local added = 0
    for j = 1, table.getn(locations) do
        local loc = locations[j]
        if type(loc.roots) ~= "table" then loc.roots = {} end

        local existing = {}
        local i
        for i = 1, table.getn(loc.roots) do
            local root = laNormalize(loc.roots[i])
            if root ~= "" then existing[root] = true end
        end

        local key
        for key in pairs(perLocation[j]) do
            if owners[key] == j and not existing[key] then
                table.insert(loc.roots, key)
                existing[key] = true
                added = added + 1
            end
        end
    end
    return added
end

local function laAnchorHas(message, root)
    local s = laNormalize(message)
    local key = laNormalize(root)
    key = string.gsub(key, "%s+", "")
    if string.len(key) < 5 then return false end
    return string.find(s, key, 1, true) ~= nil
end

local function laReportFailure(reason)
    reason = tostring(reason or "unknown")
    if S.lastFailure == reason then return end
    S.lastFailure = reason
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout location anchor:|r " .. reason)
    end
end

local function laPatch()
    local api = laFindApi()
    if not api then
        laReportFailure("core API unavailable")
        return false
    end

    local matcher, locations, rootIndex = laResolveMatcher(api)
    if not matcher or not locations or not rootIndex then
        laReportFailure("location matcher unavailable")
        return false
    end

    if S.patchedMatcher == matcher and S.rootIndex == rootIndex then
        S.lastFailure = ""
        return true
    end

    if type(debug) ~= "table" or type(debug.setupvalue) ~= "function" then
        laReportFailure("debug.setupvalue unavailable")
        return false
    end

    S.generatedCount = laInstallRoots(locations)

    local ok, result
    if pcall then
        ok, result = pcall(debug.setupvalue, matcher, rootIndex, laAnchorHas)
    else
        result = debug.setupvalue(matcher, rootIndex, laAnchorHas)
        ok = true
    end

    if not ok or not result then
        laReportFailure("root matcher patch rejected")
        return false
    end

    S.patchedMatcher = matcher
    S.rootIndex = rootIndex
    S.lastFailure = ""
    W112_SUMMONSCOUT_LOCATION_ANCHOR_ROOTS = S.generatedCount
    return true
end

local M = {}

function M.Init()
    S.nextPatchAt = 0
    laPatch()
end

function M.OnUpdate()
    local t = laNow()
    if t < (S.nextPatchAt or 0) then return end
    S.nextPatchAt = t + 0.50
    laPatch()
end

H.Register("locationanchor", M, VERSION)
W112_SUMMONSCOUT_LOCATION_ANCHOR_VERSION = VERSION
