-- Order-independent World buyer summon relation canonicalizer for WoW 1.12.1 / Lua 5.0.
--
-- A live miss exposed a lexical-order gap: messages such as
--   LF hydraxian summon
-- contain a valid buyer cue, a valid catalog destination and a summon token,
-- but some downstream hot classifiers only recognize adjacent forms such as
-- "lf summon".  This module is deliberately destination-agnostic: it uses the
-- canonical location catalog, fail-closes on multi-destination / seller /
-- recruitment traffic, and only adds an internal canonical buyer marker.
-- The player's original chat line is never rewritten or re-sent.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-catalog-order-independent"
local S = H.GetState("worldbuyerrelation")

local function brTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function brNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return brTrim(s)
end

local function brPhrase(s, p)
    s = brNormalize(s)
    p = brNormalize(p)
    if s == "" or p == "" then return false end
    return string.find(" " .. s .. " ", " " .. p .. " ", 1, true) ~= nil
end

local function brTokenRoot(s, root)
    s = brNormalize(s)
    root = brNormalize(root)
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

local function brAny(s, cues)
    local i
    for i = 1, table.getn(cues) do
        if brPhrase(s, cues[i]) then return true end
    end
    return false
end

local BUYER_LEADS = {
    "lf", "need", "wtb", "buy", "want", "looking for",
    "pls", "plz", "please", "can i", "could i", "anyone", "anybody",
    "who can", "inv", "invite"
}

local DIRECT_BUYER_SUMMON = {
    "lf summon", "lf summ", "need summon", "need summ",
    "wtb summon", "wtb summ", "want summon", "want summ",
    "looking for summon", "looking for summ",
    "summon me", "sum me", "can someone summon", "can somebody summon",
    "can you summon", "could you summon", "can u summon", "could u summon",
    "anyone can summon", "anybody can summon", "who can summon", "who can summ"
}

local SELLER_CUES = {
    "wts", "selling", "sell", "service", "available", "offering",
    "for sale", "summons available", "summon service", "summoning service",
    "selling summon", "sell summon", "summoning to", "summoning portals",
    "portal service", "pst", "whisper me", "dm me", "msg me", "travel service"
}

local OWN_SUMMON_CUES = {
    "can summon", "can summ", "we can summon", "we can summ",
    "i can summon", "i can summ", "have summon", "have a summon",
    "got summon", "got a summon", "summon available"
}

local RECRUITMENT_CUES = {
    "warrior", "mage", "rogue", "priest", "warlock", "hunter", "druid",
    "paladin", "shaman", "tank", "healer", "heals", "heal", "dps",
    "melee", "ranged", "caster", "farm", "run", "group", "grp"
}

local function brHasTravel(s)
    if brPhrase(s, "summon") or brPhrase(s, "summons")
        or brPhrase(s, "summoning") or brPhrase(s, "summ")
        or brPhrase(s, "summs") or brPhrase(s, "sum")
        or brPhrase(s, "sumon") or brPhrase(s, "port")
        or brPhrase(s, "portal") or brPhrase(s, "taxi")
        or brPhrase(s, "tp") then
        return true
    end

    local token
    for token in string.gfind(brNormalize(s), "%S+") do
        if string.sub(token, 1, 4) == "summ"
            or string.sub(token, 1, 4) == "port"
            or string.sub(token, 1, 4) == "tele" then
            return true
        end
    end
    return false
end

local function brRecruitment(s)
    return brAny(s, BUYER_LEADS)
        and brAny(s, OWN_SUMMON_CUES)
        and brAny(s, RECRUITMENT_CUES)
        and not brAny(s, DIRECT_BUYER_SUMMON)
end

local function brFindLocations(api, message)
    local result = {}
    local seen = {}
    local catalog = api and api.GetLocationCatalog and api.GetLocationCatalog() or nil
    local normalized = brNormalize(message)
    local i, j

    if type(catalog) ~= "table" then return result end

    for i = 1, table.getn(catalog) do
        local loc = catalog[i]
        local matched = false
        if type(loc) == "table" and loc.id then
            if type(loc.aliases) == "table" then
                for j = 1, table.getn(loc.aliases) do
                    if brPhrase(normalized, loc.aliases[j]) then
                        matched = true
                        break
                    end
                end
            end
            if not matched and type(loc.roots) == "table" then
                for j = 1, table.getn(loc.roots) do
                    if brTokenRoot(normalized, loc.roots[j]) then
                        matched = true
                        break
                    end
                end
            end
            if matched and not seen[string.lower(tostring(loc.id))] then
                seen[string.lower(tostring(loc.id))] = true
                result[table.getn(result) + 1] = loc
            end
        end
    end
    return result
end

local function brCanonicalize(api, message)
    local normalized = brNormalize(message)
    if normalized == "" then return message, false, nil end

    local locations = brFindLocations(api, message)
    if table.getn(locations) ~= 1 then return message, false, locations end
    if not brAny(normalized, BUYER_LEADS) then return message, false, locations end
    if brAny(normalized, SELLER_CUES) then return message, false, locations end
    if brRecruitment(normalized) then return message, false, locations end
    if not brHasTravel(normalized) then return message, false, locations end

    -- Already canonical enough for the legacy/direct phrase matchers.
    if brAny(normalized, DIRECT_BUYER_SUMMON) then
        return message, false, locations
    end

    -- Internal-only lexical bridge.  Keeping the destination untouched means
    -- FindLocation/ownership/blacklist/dedupe/queue semantics stay canonical.
    return tostring(message or "") .. " lf summon", true, locations
end

local function brInstall()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.handleChannelMessage) ~= "function"
        or type(api.GetLocationCatalog) ~= "function" then
        S.lastStatus = "api-unavailable"
        return false
    end

    if S.wrapper and api.handleChannelMessage == S.wrapper then
        return true
    end

    local original = api.handleChannelMessage
    local wrapper = function(message, sender, channelBaseName, channelFullName)
        local routed, changed, locations = brCanonicalize(api, message)
        if changed and SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
            local loc = locations and locations[1] or nil
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World buyer:|r order-independent request -> "
                .. tostring(sender or "?") .. " [" .. tostring(loc and (loc.label or loc.id) or "?") .. "]")
        end
        return original(routed, sender, channelBaseName, channelFullName)
    end

    S.original = original
    S.wrapper = wrapper
    api.handleChannelMessage = wrapper
    S.lastStatus = "installed"
    return true
end

local M = {}

function M.Init()
    brInstall()
end

function M.Shutdown()
    -- RosterOwnership may legitimately wrap this handler after load.  Do not
    -- peel an outer canonical guard during hot-host shutdown.
end

H.Register("worldbuyerrelation", M, VERSION)
W112_SUMMONSCOUT_WORLD_BUYER_RELATION_VERSION = VERSION
