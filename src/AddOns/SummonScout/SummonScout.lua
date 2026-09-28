-- SummonScout for World of Warcraft 1.12.1 (build 5875)
-- Watches the configured custom channel (World by default) and queues invites
-- only when the message looks like a request for a summon.

SummonScoutDB = SummonScoutDB or {}

local SS = {}
SS.queue = {}
SS.queued = {}
SS.recent = {}
SS.nextInviteAt = 0

local function chat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. text)
    end
end

local function now()
    if GetTime then return GetTime() end
    return 0
end

local function trim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function lower(s)
    return string.lower(s or "")
end

local function normalizeMessage(s)
    s = lower(s)
    -- Remove color/link control characters and turn punctuation into spaces.
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return trim(s)
end

local function has(s, needle)
    return string.find(s, needle, 1, true) ~= nil
end

local function paddedHas(s, token)
    return has(" " .. s .. " ", " " .. token .. " ")
end

local function isSellerMessage(s)
    local seller = {
        "wts", "selling", "sell summon", "selling summon",
        "summon service", "summoning service", "summons available",
        "summoning to", "portal service"
    }
    local i
    for i = 1, table.getn(seller) do
        if has(s, seller[i]) then return true end
    end
    return false
end

local function hasSummonToken(s)
    return paddedHas(s, "summon")
        or paddedHas(s, "summ")
        or paddedHas(s, "sum")
        or paddedHas(s, "sumon")
end

local function looksLikeSummonRequest(message)
    local s = normalizeMessage(message)
    if s == "" or isSellerMessage(s) or not hasSummonToken(s) then
        return false
    end

    -- Strong request/intention cues. Any summon token plus one of these is enough.
    local cues = {
        "need", "lf", "wtb", "buy", "want", "looking",
        "pls", "plz", "please", "can i", "could i", "anyone",
        "who can", "inv", "invite", "me", "port"
    }
    local i
    for i = 1, table.getn(cues) do
        if has(s, cues[i]) then return true end
    end

    -- Accept terse World messages such as "summ", "sum?", "summon dm".
    if string.len(s) <= 24 then
        return true
    end
    return false
end

local function channelMatches(channelName)
    local wanted = lower(trim(SummonScoutDB.channel or "world"))
    local got = lower(trim(channelName or ""))
    return wanted ~= "" and got == wanted
end

local function samePlayer(a, b)
    return lower(a or "") == lower(b or "")
end

local function isInGroup(name)
    local i
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if samePlayer(UnitName("party" .. i), name) then return true end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(i)
            if samePlayer(raidName, name) then return true end
        end
    end
    return false
end

local function recentlyHandled(name)
    local t = SS.recent[lower(name)]
    if not t then return false end
    return (now() - t) < (SummonScoutDB.duplicateSeconds or 120)
end

local function queueInvite(name, message)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return end
    if isInGroup(name) or recentlyHandled(name) or SS.queued[lower(name)] then return end

    SS.queue[table.getn(SS.queue) + 1] = { name = name, message = message or "" }
    SS.queued[lower(name)] = true

    if SummonScoutDB.debug then
        chat("match: " .. name .. " -> " .. (message or ""))
    end
end

local function popInvite()
    if table.getn(SS.queue) == 0 then return nil end
    local item = SS.queue[1]
    table.remove(SS.queue, 1)
    SS.queued[lower(item.name)] = nil
    return item
end

local function processQueue()
    if not SummonScoutDB.enabled then return end
    if now() < SS.nextInviteAt then return end

    local item = popInvite()
    if not item then return end
    if isInGroup(item.name) or recentlyHandled(item.name) then return end

    SS.recent[lower(item.name)] = now()
    SS.nextInviteAt = now() + (SummonScoutDB.inviteDelay or 0.8)
    InviteByName(item.name)
    chat("invite -> " .. item.name)
end

local function setDefaults()
    if SummonScoutDB.enabled == nil then SummonScoutDB.enabled = true end
    if SummonScoutDB.channel == nil then SummonScoutDB.channel = "world" end
    if SummonScoutDB.duplicateSeconds == nil then SummonScoutDB.duplicateSeconds = 120 end
    if SummonScoutDB.inviteDelay == nil then SummonScoutDB.inviteDelay = 0.8 end
    if SummonScoutDB.debug == nil then SummonScoutDB.debug = false end
end

local function status()
    chat("enabled=" .. (SummonScoutDB.enabled and "ON" or "OFF")
        .. ", channel=" .. (SummonScoutDB.channel or "world")
        .. ", duplicate=" .. tostring(SummonScoutDB.duplicateSeconds or 120) .. "s"
        .. ", queue=" .. tostring(table.getn(SS.queue)))
end

local function slash(msg)
    msg = trim(msg)
    local cmd, rest = string.match(msg, "^(%S+)%s*(.-)$")
    cmd = lower(cmd or "")

    if cmd == "on" then
        SummonScoutDB.enabled = true
        status()
    elseif cmd == "off" then
        SummonScoutDB.enabled = false
        SS.queue = {}
        SS.queued = {}
        status()
    elseif cmd == "debug" then
        rest = lower(trim(rest))
        SummonScoutDB.debug = (rest == "on" or rest == "1" or rest == "true")
        status()
    elseif cmd == "channel" and trim(rest) ~= "" then
        SummonScoutDB.channel = trim(rest)
        status()
    elseif cmd == "test" and trim(rest) ~= "" then
        chat("test=" .. (looksLikeSummonRequest(rest) and "MATCH" or "NO MATCH") .. " -> " .. rest)
    elseif cmd == "status" or cmd == "" then
        status()
    else
        chat("/ssi on | off | status | channel <name> | debug on/off | test <message>")
    end
end

local frame = CreateFrame("Frame", "SummonScoutFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        setDefaults()
        chat("loaded; watching #" .. (SummonScoutDB.channel or "world"))
        return
    end

    if event == "CHAT_MSG_CHANNEL" then
        if not SummonScoutDB.enabled then return end
        local message = arg1 or ""
        local sender = arg2 or ""
        local channelBaseName = arg9 or ""

        if channelMatches(channelBaseName) and looksLikeSummonRequest(message) then
            queueInvite(sender, message)
        end
    end
end)
frame:SetScript("OnUpdate", function()
    processQueue()
end)

SLASH_SUMMONSCOUT1 = "/ssi"
SLASH_SUMMONSCOUT2 = "/summonscout"
SlashCmdList["SUMMONSCOUT"] = slash
