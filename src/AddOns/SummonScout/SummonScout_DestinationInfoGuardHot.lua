-- SummonScout destination-information priority guard for WoW 1.12.1 / Lua 5.0.
--
-- Informational whispers such as "where can u summon" must never enter the
-- invite/grouped-resume/unknown-probe paths. This file is loaded last and wraps
-- both the core SummonScout event frame and the HotHost dispatcher so the query
-- is classified before any invite-oriented handler can consume it.
--
-- The reply reuses fallbackrouter state: it advertises the live directory and
-- arms pendingChoice so a follow-up containing only a destination continues
-- through the existing fallback router and its master/provider handoff.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.GetState) ~= "function" then return end

local VERSION = "2-info-sum-auto-probe"
local D = H.GetState("destinationinfoguard")
local F = H.GetState("fallbackrouter")

local DISPLAY_LABELS = {
    hyjal = "Hyjal",
    hydraxian = "Hydraxis",
    winterspring = "Winterspring"
}

local PROVIDER_TTL = 38.0
local CHOICE_TTL = 45.0
local MAX_DESTINATIONS = 12

local function diNow()
    if GetTime then return GetTime() end
    return 0
end

local function diTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function diLower(s)
    return string.lower(diTrim(s or ""))
end

local function diNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return diTrim(s)
end

local function diPhraseHas(s, phrase)
    s = diNormalize(s)
    phrase = diNormalize(phrase)
    if s == "" or phrase == "" then return false end
    return string.find(" " .. s .. " ", " " .. phrase .. " ", 1, true) ~= nil
end

local function diIsInfoQuestion(message)
    local s = diNormalize(message)
    if s == "" then return false end

    local asksWhere = diPhraseHas(s, "where")
    local asksWhat = diPhraseHas(s, "what")
    local asksWhich = diPhraseHas(s, "which")
    if not asksWhere and not asksWhat and not asksWhich then return false end

    local summonWord = diPhraseHas(s, "sum") or string.find(s, "summ", 1, true) ~= nil
    local routeWord = diPhraseHas(s, "location") or diPhraseHas(s, "locations")
        or diPhraseHas(s, "destination") or diPhraseHas(s, "destinations")
        or diPhraseHas(s, "place") or diPhraseHas(s, "places")
        or diPhraseHas(s, "route") or diPhraseHas(s, "routes")

    return summonWord or routeWord
end

local function diValidPlayerName(name)
    name = diTrim(name)
    if name == "" or string.len(name) > 32 then return false end
    if string.find(name, "[%c%s:;,=|]") then return false end
    return true
end

local function diCatalog()
    local byId = {}
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.GetLocationCatalog) ~= "function" then return byId end
    local list = api.GetLocationCatalog()
    if type(list) ~= "table" then return byId end
    local i
    for i = 1, table.getn(list) do
        local loc = list[i]
        if type(loc) == "table" and loc.id then
            byId[diLower(loc.id)] = loc
        end
    end
    return byId
end

local function diLabel(catalog, id)
    id = diLower(id)
    if DISPLAY_LABELS[id] then return DISPLAY_LABELS[id] end
    local loc = catalog[id]
    return loc and tostring(loc.label or loc.id) or id
end

local function diAddId(ids, seen, catalog, id)
    id = diLower(id)
    if id == "" or seen[id] then return end
    if next(catalog) ~= nil and not catalog[id] then return end
    seen[id] = true
    ids[table.getn(ids) + 1] = id
end

local function diAvailableIds()
    local ids = {}
    local seen = {}
    local catalog = diCatalog()

    local service = diLower(SummonScoutDB and SummonScoutDB.service or "")
    if service ~= "" and service ~= "all" then
        local token
        for token in string.gfind(service, "[^,]+") do
            diAddId(ids, seen, catalog, token)
        end
    end

    if type(F.directory) == "table" then
        local id
        for id, enabled in pairs(F.directory) do
            if enabled then diAddId(ids, seen, catalog, id) end
        end
    end

    if type(F.providers) == "table" then
        local t = diNow()
        local id, providers, _, item
        for id, providers in pairs(F.providers) do
            local live = false
            if type(providers) == "table" then
                for _, item in pairs(providers) do
                    if type(item) == "table" and (t - (tonumber(item.seen) or 0)) <= PROVIDER_TTL then
                        live = true
                        break
                    end
                end
            end
            if live then diAddId(ids, seen, catalog, id) end
        end
    end

    table.sort(ids)
    while table.getn(ids) > MAX_DESTINATIONS do table.remove(ids) end
    return ids, catalog
end

local function diAvailableText()
    local ids, catalog = diAvailableIds()
    local labels = {}
    local i
    for i = 1, table.getn(ids) do
        labels[table.getn(labels) + 1] = diLabel(catalog, ids[i])
    end
    return table.concat(labels, ", ")
end

local function diHandleInfo(message, sender)
    if not diIsInfoQuestion(message) then return false end
    sender = diTrim(sender)
    if not diValidPlayerName(sender) then return true end
    if not SummonScoutDB or not SummonScoutDB.enabled
        or not SummonScoutDB.whisperAutoInvite
        or SummonScoutDB.fallbackRouterEnabled == false then
        return true
    end
    if H.IsManualChatLocked and H.IsManualChatLocked(sender) then return true end

    local available = diAvailableText()
    if available == "" then
        if SendChatMessage then
            SendChatMessage("I don't have an available summon route right now.", "WHISPER", nil, sender)
        end
        return true
    end

    local key = diLower(sender)
    F.pendingChoice = F.pendingChoice or {}
    F.promptRecent = F.promptRecent or {}
    F.pendingChoice[key] = { name = sender, expires = diNow() + CHOICE_TTL }
    F.promptRecent[key] = diNow()

    if SendChatMessage then
        SendChatMessage("I can help with summons. Available: " .. available .. ". Reply with the destination.", "WHISPER", nil, sender)
    end
    return true
end

local function diAutomaticOutgoing(message)
    local raw = diTrim(message)
    local normalized = diNormalize(raw)
    if string.find(raw, "I can help with summons. Available:", 1, true) == 1 then return true end
    if raw == "I don't have an available summon route right now." then return true end
    if string.sub(raw, 1, 9) == "Got it - " then return true end
    if string.find(raw, " is currently unavailable. Please try again shortly.", 1, true) then return true end
    if string.find(normalized, "do you need ", 1, true) == 1
        and string.find(normalized, " summon", 1, true) then
        return true
    end
    return false
end

local function diRestorePrevious()
    if H.frame and H.frame.GetScript and H.frame.SetScript
        and D.hostWrapper and D.hostBase
        and H.frame:GetScript("OnEvent") == D.hostWrapper then
        H.frame:SetScript("OnEvent", D.hostBase)
    end
    if SummonScoutFrame and SummonScoutFrame.GetScript and SummonScoutFrame.SetScript
        and D.coreWrapper and D.coreBase
        and SummonScoutFrame:GetScript("OnEvent") == D.coreWrapper then
        SummonScoutFrame:SetScript("OnEvent", D.coreBase)
    end
    if D.manualWrapper and D.manualBase and H.ManualChatObserveOutgoing == D.manualWrapper then
        H.ManualChatObserveOutgoing = D.manualBase
    end
end

diRestorePrevious()

if SummonScoutFrame and SummonScoutFrame.GetScript and SummonScoutFrame.SetScript then
    local coreBase = SummonScoutFrame:GetScript("OnEvent")
    if type(coreBase) == "function" then
        local coreWrapper = function()
            if event == "CHAT_MSG_WHISPER" and diIsInfoQuestion(arg1 or "") then
                return
            end
            return coreBase()
        end
        D.coreBase = coreBase
        D.coreWrapper = coreWrapper
        SummonScoutFrame:SetScript("OnEvent", coreWrapper)
    end
end

if H.frame and H.frame.GetScript and H.frame.SetScript then
    local hostBase = H.frame:GetScript("OnEvent")
    if type(hostBase) == "function" then
        local hostWrapper = function()
            if event == "CHAT_MSG_WHISPER" and diIsInfoQuestion(arg1 or "") then
                diHandleInfo(arg1 or "", arg2 or "")
                return
            end
            return hostBase()
        end
        D.hostBase = hostBase
        D.hostWrapper = hostWrapper
        H.frame:SetScript("OnEvent", hostWrapper)
    end
end

if type(H.ManualChatObserveOutgoing) == "function" then
    local manualBase = H.ManualChatObserveOutgoing
    local manualWrapper = function(message, target)
        if diAutomaticOutgoing(message) then return end
        return manualBase(message, target)
    end
    D.manualBase = manualBase
    D.manualWrapper = manualWrapper
    H.ManualChatObserveOutgoing = manualWrapper
end

H.IsDestinationInfoQuestion = diIsInfoQuestion
D.version = VERSION
W112_SUMMONSCOUT_DESTINATION_INFO_GUARD_VERSION = VERSION
