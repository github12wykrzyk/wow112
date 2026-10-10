local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "3-wtb-location-invite-reinvite8"
local S = H.GetState("worldbuyerrelation")
local REINVITE_SECONDS = 8
local REINVITE_DEBUG_TAG = "reinvite-dedupe-reset"

local function brNow()
    if GetTime then return GetTime() end
    return 0
end

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

local function brTokenStarts(s, root)
    s = brNormalize(s)
    root = brNormalize(root)
    if root == "" then return false end
    local token
    for token in string.gfind(s, "%S+") do
        if string.len(token) >= string.len(root)
            and string.sub(token, 1, string.len(root)) == root then
            return true
        end
    end
    return false
end

local function brTokenRoot(s, root)
    root = brNormalize(root)
    if string.len(root) < 5 then return false end
    return brTokenStarts(s, root)
end

local function brAny(s, cues)
    local i
    for i = 1, table.getn(cues) do
        if brPhrase(s, cues[i]) then return true end
    end
    return false
end

local function brTokenCount(s)
    local count = 0
    local token
    for token in string.gfind(brNormalize(s), "%S+") do
        count = count + 1
    end
    return count
end

local BUYER_LEADS = {
    "lf", "need", "needed", "wtb", "buy", "buying", "want", "looking for",
    "pls", "plz", "please", "can i", "could i", "anyone", "anybody",
    "someone", "somebody", "who can", "inv", "invite", "invite me",
    "need one", "want one", "take one", "get one", "one pls", "one plz"
}

local DIRECT_BUYER_SUMMON = {
    "lf summon", "lf summ", "need summon", "need summ",
    "wtb summon", "wtb summ", "want summon", "want summ",
    "looking for summon", "looking for summ",
    "summon me", "sum me", "can someone summon", "can somebody summon",
    "can you summon", "could you summon", "can u summon", "could u summon",
    "anyone can summon", "anybody can summon", "who can summon", "who can summ"
}

local HARD_SELLER_CUES = {
    "wts", "selling", "sell", "service", "available", "offering",
    "for sale", "summons available", "summon service", "summoning service",
    "selling summon", "sell summon", "summoning to", "summoning portals",
    "portal service", "travel service"
}

local CONTACT_CUES = {
    "pst", "whisper me", "dm me", "msg me"
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

local function brBuyerLead(s)
    return brAny(s, BUYER_LEADS)
        or brTokenStarts(s, "wtb")
        or brTokenStarts(s, "inv")
        or brTokenStarts(s, "need")
        or brTokenStarts(s, "want")
        or brTokenStarts(s, "look")
end

local function brWtbLead(s)
    return brPhrase(s, "wtb") or brTokenStarts(s, "wtb")
end

local function brHasTravel(s)
    if brPhrase(s, "summon") or brPhrase(s, "summons")
        or brPhrase(s, "summoning") or brPhrase(s, "summ")
        or brPhrase(s, "summs") or brPhrase(s, "sum")
        or brPhrase(s, "sumon") or brPhrase(s, "port")
        or brPhrase(s, "portal") or brPhrase(s, "taxi")
        or brPhrase(s, "tp") or brPhrase(s, "tele") then
        return true
    end

    return brTokenStarts(s, "summ")
        or brTokenStarts(s, "sumon")
        or brTokenStarts(s, "port")
        or brTokenStarts(s, "tele")
        or brTokenStarts(s, "taxi")
end

local function brHasPrice(s)
    s = brNormalize(s)
    return string.find(s, "%d+%s*g") ~= nil
        or brPhrase(s, "gold")
        or brPhrase(s, "fee")
        or brPhrase(s, "price")
end

local function brRecruitment(s)
    return brBuyerLead(s)
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

local function brServiceContains(id)
    local service = string.lower(brTrim(SummonScoutDB and SummonScoutDB.service or "all"))
    id = string.lower(brTrim(id or ""))
    if service == "" or service == "all" then return true end
    if id == "" then return false end
    return string.find("," .. service .. ",", "," .. id .. ",", 1, true) ~= nil
end

local function brSpecificServiceContains(id)
    local service = string.lower(brTrim(SummonScoutDB and SummonScoutDB.service or "all"))
    id = string.lower(brTrim(id or ""))
    if service == "" or service == "all" or id == "" then return false end
    return string.find("," .. service .. ",", "," .. id .. ",", 1, true) ~= nil
end

local function brRelation(api, message)
    local raw = tostring(message or "")
    local normalized = brNormalize(raw)
    if normalized == "" then return false, nil, "empty" end

    local locations = brFindLocations(api, raw)
    if table.getn(locations) ~= 1 then
        return false, locations, table.getn(locations) > 1 and "multi-destination" or "no-destination"
    end

    local buyer = brBuyerLead(normalized)
    if brAny(normalized, HARD_SELLER_CUES) then return false, locations, "seller" end
    if brAny(normalized, CONTACT_CUES) and not buyer then return false, locations, "seller-contact" end
    if brRecruitment(normalized) then return false, locations, "recruitment" end

    -- Operator rule: any World line with WTB + one recognized destination is
    -- a buyer summon signal. We canonicalize it into the normal core request
    -- path; the core still owns service matching, blacklist, dedupe and invite
    -- cooldown, so another-location WTB cannot invite the wrong summoner.
    if brWtbLead(normalized) then
        return true, locations, "wtb+destination"
    end

    local travel = brHasTravel(normalized)
    local short = brTokenCount(normalized) <= 4
    local question = string.find(raw, "?", 1, true) ~= nil
    local price = brHasPrice(normalized)

    if buyer and (travel or brSpecificServiceContains(locations[1].id)) then
        return true, locations, travel and "buyer+travel" or "buyer+served-destination"
    end

    if travel and not price and (question or short) then
        return true, locations, question and "travel-question" or "short-travel"
    end

    return false, locations, "weak-intent"
end

local function brCanonicalize(api, message)
    local accepted, locations, reason = brRelation(api, message)
    if not accepted then return message, false, locations, reason, false end

    local normalized = brNormalize(message)
    if brAny(normalized, DIRECT_BUYER_SUMMON) then
        return message, false, locations, reason, true
    end

    return tostring(message or "") .. " lf summon", true, locations, reason, true
end

local function brRelaxRecent(sender, locations)
    if not locations or table.getn(locations) ~= 1 or not brServiceContains(locations[1].id) then
        return false
    end

    local state = W112_SUMMONSCOUT_STATE
    if type(state) ~= "table" or type(state.recent) ~= "table" then return false end
    local key = string.lower(brTrim(sender or ""))
    if key == "" then return false end

    local last = tonumber(state.recent[key])
    if not last then return false end
    if (brNow() - last) < REINVITE_SECONDS then return false end

    state.recent[key] = nil
    return true
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
        local routed, changed, locations, reason, accepted = brCanonicalize(api, message)
        local relaxed = false

        if accepted then relaxed = brRelaxRecent(sender, locations) end

        S.lastRaw = tostring(message or "")
        S.lastSender = tostring(sender or "")
        S.lastReason = tostring(reason or "")
        S.lastAccepted = accepted and true or false
        S.lastChanged = changed and true or false
        S.lastRelaxedRecent = relaxed and true or false
        S.lastLocation = locations and locations[1]
            and tostring(locations[1].id or locations[1].label or "") or ""

        if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
            if accepted and (changed or relaxed) then
                local loc = locations and locations[1] or nil
                DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout World buyer:|r relation="
                    .. tostring(reason or "?") .. " -> " .. tostring(sender or "?")
                    .. " [" .. tostring(loc and (loc.label or loc.id) or "?") .. "]"
                    .. (relaxed and (" " .. REINVITE_DEBUG_TAG) or ""))
            end
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
end

H.Register("worldbuyerrelation", M, VERSION)
W112_SUMMONSCOUT_WORLD_BUYER_RELATION_VERSION = VERSION
