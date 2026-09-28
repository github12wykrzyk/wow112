-- SummonScout for World of Warcraft 1.12.1 (build 5875)
-- Watches World chat for summon requests, recognizes destinations and can
-- auto-invite only requests for the place currently served by the warlock.

SummonScoutDB = SummonScoutDB or {}

local SS = {}
SS.queue = {}
SS.queued = {}
SS.recent = {}
SS.nextInviteAt = 0

local LOCATIONS = {
    -- Instances / raids. Put more specific or potentially colliding aliases first.
    { id="deadmines", label="Deadmines", aliases={"deadmines", "the deadmines", "vc"} },
    { id="dme", label="Dire Maul East", aliases={"dire maul east", "dm east", "dme"} },
    { id="dmn", label="Dire Maul North", aliases={"dire maul north", "dm north", "dmn"} },
    { id="dmw", label="Dire Maul West", aliases={"dire maul west", "dm west", "dmw"} },
    { id="diremaul", label="Dire Maul", aliases={"dire maul"} },
    { id="rfc", label="Ragefire Chasm", aliases={"ragefire chasm", "ragefire", "rfc"} },
    { id="wc", label="Wailing Caverns", aliases={"wailing caverns", "wc"} },
    { id="sfk", label="Shadowfang Keep", aliases={"shadowfang keep", "shadowfang", "sfk"} },
    { id="bfd", label="Blackfathom Deeps", aliases={"blackfathom deeps", "blackfathom", "bfd"} },
    { id="stocks", label="The Stockade", aliases={"the stockade", "stockades", "stockade", "stocks"} },
    { id="gnomer", label="Gnomeregan", aliases={"gnomeregan", "gnomer"} },
    { id="rfk", label="Razorfen Kraul", aliases={"razorfen kraul", "rfk"} },
    { id="sm", label="Scarlet Monastery", aliases={"scarlet monastery", "sm cathedral", "sm cath", "sm armory", "sm armoury", "sm library", "sm lib", "sm graveyard", "sm gy", "sm"} },
    { id="rfd", label="Razorfen Downs", aliases={"razorfen downs", "rfd"} },
    { id="ulda", label="Uldaman", aliases={"uldaman", "ulda"} },
    { id="zf", label="Zul'Farrak", aliases={"zul farrak", "zulfarrak", "zf"} },
    { id="mara", label="Maraudon", aliases={"maraudon", "mara"} },
    { id="st", label="Sunken Temple", aliases={"sunken temple", "temple of atal hakkar", "atal hakkar"} },
    { id="brd", label="Blackrock Depths", aliases={"blackrock depths", "brd"} },
    { id="brs", label="Blackrock Spire", aliases={"blackrock spire", "upper blackrock spire", "lower blackrock spire", "ubrs", "lbrs", "brs"} },
    { id="scholo", label="Scholomance", aliases={"scholomance", "scholo"} },
    { id="strat", label="Stratholme", aliases={"stratholme", "strat"} },
    { id="mc", label="Molten Core", aliases={"molten core", "mc"} },
    { id="ony", label="Onyxia", aliases={"onyxia", "ony"} },
    { id="bwl", label="Blackwing Lair", aliases={"blackwing lair", "bwl"} },
    { id="zg", label="Zul'Gurub", aliases={"zul gurub", "zulgurub", "zg"} },
    { id="aq20", label="Ruins of Ahn'Qiraj", aliases={"ruins of ahn qiraj", "aq20"} },
    { id="aq40", label="Temple of Ahn'Qiraj", aliases={"temple of ahn qiraj", "aq40"} },
    { id="naxx", label="Naxxramas", aliases={"naxxramas", "naxx"} },

    -- Cities / common summon hubs.
    { id="org", label="Orgrimmar", aliases={"orgrimmar", "orgri", "org"} },
    { id="uc", label="Undercity", aliases={"undercity", "uc"} },
    { id="tb", label="Thunder Bluff", aliases={"thunder bluff", "tb"} },
    { id="sw", label="Stormwind", aliases={"stormwind", "sw"} },
    { id="darn", label="Darnassus", aliases={"darnassus", "darn"} },
    { id="bootybay", label="Booty Bay", aliases={"booty bay"} },
    { id="gadgetzan", label="Gadgetzan", aliases={"gadgetzan", "gadget"} },
    { id="ratchet", label="Ratchet", aliases={"ratchet"} },
    { id="kargath", label="Kargath", aliases={"kargath"} },
    { id="thorium", label="Thorium Point", aliases={"thorium point"} },
    { id="lhc", label="Light's Hope Chapel", aliases={"light s hope chapel", "lights hope chapel", "light s hope", "lights hope", "lhc"} },
    { id="everlook", label="Everlook", aliases={"everlook"} },
    { id="cenarion", label="Cenarion Hold", aliases={"cenarion hold"} },
    { id="crossroads", label="The Crossroads", aliases={"the crossroads", "crossroads", "xroads"} },
    { id="gromgol", label="Grom'gol", aliases={"grom gol", "gromgol"} },
    { id="stonard", label="Stonard", aliases={"stonard"} },
    { id="tarren", label="Tarren Mill", aliases={"tarren mill"} },
    { id="southshore", label="Southshore", aliases={"southshore"} },
    { id="menethil", label="Menethil Harbor", aliases={"menethil harbor", "menethil"} },
    { id="auberdine", label="Auberdine", aliases={"auberdine"} },

    -- Zones often named directly in World chat.
    { id="stv", label="Stranglethorn Vale", aliases={"stranglethorn vale", "stranglethorn", "stv"} },
    { id="epl", label="Eastern Plaguelands", aliases={"eastern plaguelands", "epl"} },
    { id="wpl", label="Western Plaguelands", aliases={"western plaguelands", "wpl"} },
    { id="searing", label="Searing Gorge", aliases={"searing gorge"} },
    { id="burning", label="Burning Steppes", aliases={"burning steppes"} },
    { id="badlands", label="Badlands", aliases={"badlands"} },
    { id="blasted", label="Blasted Lands", aliases={"blasted lands"} },
    { id="hinterlands", label="The Hinterlands", aliases={"the hinterlands", "hinterlands"} },
    { id="silithus", label="Silithus", aliases={"silithus"} },
    { id="tanaris", label="Tanaris", aliases={"tanaris"} },
    { id="ungoro", label="Un'Goro Crater", aliases={"un goro crater", "ungoro crater", "un goro", "ungoro"} },
    { id="winterspring", label="Winterspring", aliases={"winterspring"} },
    { id="felwood", label="Felwood", aliases={"felwood"} },
    { id="feralas", label="Feralas", aliases={"feralas"} },
    { id="desolace", label="Desolace", aliases={"desolace"} },
    { id="azshara", label="Azshara", aliases={"azshara"} },
    { id="ashenvale", label="Ashenvale", aliases={"ashenvale"} },
    { id="barrens", label="The Barrens", aliases={"the barrens", "barrens"} },
    { id="dustwallow", label="Dustwallow Marsh", aliases={"dustwallow marsh", "dustwallow"} },
    { id="thousandneedles", label="Thousand Needles", aliases={"thousand needles"} },
    { id="stonetalon", label="Stonetalon Mountains", aliases={"stonetalon mountains", "stonetalon"} },
}

local LOCATION_BY_ID = {}
local i
for i = 1, table.getn(LOCATIONS) do
    LOCATION_BY_ID[LOCATIONS[i].id] = LOCATIONS[i]
end

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

local function phraseHas(s, phrase)
    local p = normalizeMessage(phrase)
    if p == "" then return false end
    return has(" " .. s .. " ", " " .. p .. " ")
end

local function isSellerMessage(s)
    local seller = {
        "wts", "selling", "sell summon", "selling summon",
        "summon service", "summoning service", "summons available",
        "summoning to", "portal service"
    }
    local j
    for j = 1, table.getn(seller) do
        if has(s, seller[j]) then return true end
    end
    return false
end

local function hasSummonToken(s)
    return phraseHas(s, "summon")
        or phraseHas(s, "summ")
        or phraseHas(s, "sum")
        or phraseHas(s, "sumon")
end

local function looksLikeSummonRequest(message)
    local s = normalizeMessage(message)
    if s == "" or isSellerMessage(s) or not hasSummonToken(s) then
        return false
    end

    local cues = {
        "need", "lf", "wtb", "buy", "want", "looking",
        "pls", "plz", "please", "can i", "could i", "anyone",
        "who can", "inv", "invite", "me", "port"
    }
    local j
    for j = 1, table.getn(cues) do
        if phraseHas(s, cues[j]) then return true end
    end

    if string.len(s) <= 32 then
        return true
    end
    return false
end

local function findLocation(message)
    local s = normalizeMessage(message)
    local j, k

    -- Plain "DM" is historically ambiguous: Deadmines vs Dire Maul.
    -- Specific spellings (VC, DME/DMN/DMW, "dire maul", "deadmines") are
    -- resolved by the normal table below.
    local plainDm = phraseHas(s, "dm")

    for j = 1, table.getn(LOCATIONS) do
        local loc = LOCATIONS[j]
        for k = 1, table.getn(loc.aliases) do
            if phraseHas(s, loc.aliases[k]) then
                return loc, nil
            end
        end
    end

    if plainDm then
        return nil, "dm"
    end
    return nil, nil
end

local function resolveLocationName(text)
    local s = normalizeMessage(text)
    if s == "all" then return "all", "ALL" end

    local loc, ambiguous = findLocation(s)
    if loc then return loc.id, loc.label end
    if ambiguous then return nil, "AMBIGUOUS" end

    local direct = LOCATION_BY_ID[s]
    if direct then return direct.id, direct.label end
    return nil, nil
end

local function servedLocationLabel()
    local service = SummonScoutDB.service or "all"
    if service == "all" then return "ALL" end
    local loc = LOCATION_BY_ID[service]
    return loc and loc.label or service
end

local function locationAllowed(loc, ambiguous)
    local service = SummonScoutDB.service or "all"
    if service == "all" then
        -- Preserve old behavior in ALL mode, but do not guess plain DM.
        return ambiguous == nil
    end

    if ambiguous or not loc then return false end
    if loc.id == service then return true end

    -- Generic Blackrock Spire and Scarlet Monastery aliases intentionally share
    -- one canonical destination because their common summon point serves wings.
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
    local j
    for j = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if samePlayer(UnitName("party" .. j), name) then return true end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for j = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(j)
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

local function queueInvite(name, message, loc)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return end
    if isInGroup(name) or recentlyHandled(name) or SS.queued[lower(name)] then return end

    SS.queue[table.getn(SS.queue) + 1] = {
        name = name,
        message = message or "",
        locationId = loc and loc.id or nil,
        locationLabel = loc and loc.label or "unknown"
    }
    SS.queued[lower(name)] = true

    if SummonScoutDB.debug then
        chat("match: " .. name .. " [" .. (loc and loc.label or "?") .. "] -> " .. (message or ""))
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
    chat("invite -> " .. item.name .. " [" .. (item.locationLabel or "?") .. "]")
end

local function setDefaults()
    if SummonScoutDB.enabled == nil then SummonScoutDB.enabled = true end
    if SummonScoutDB.channel == nil then SummonScoutDB.channel = "world" end
    if SummonScoutDB.duplicateSeconds == nil then SummonScoutDB.duplicateSeconds = 120 end
    if SummonScoutDB.inviteDelay == nil then SummonScoutDB.inviteDelay = 0.8 end
    if SummonScoutDB.debug == nil then SummonScoutDB.debug = false end
    if SummonScoutDB.service == nil then SummonScoutDB.service = "all" end
end

local function status()
    chat("enabled=" .. (SummonScoutDB.enabled and "ON" or "OFF")
        .. ", channel=" .. (SummonScoutDB.channel or "world")
        .. ", serving=" .. servedLocationLabel()
        .. ", duplicate=" .. tostring(SummonScoutDB.duplicateSeconds or 120) .. "s"
        .. ", queue=" .. tostring(table.getn(SS.queue)))
end

local function showPlaces()
    chat("instances: rfc wc deadmines/vc sfk bfd stocks gnomer rfk sm rfd ulda zf mara sunken-temple brd brs scholo strat")
    chat("endgame: dme dmn dmw dire-maul mc ony bwl zg aq20 aq40 naxx")
    chat("cities/hubs: org uc tb sw darn kargath gadgetzan ratchet lhc everlook cenarion crossroads")
    chat("zones: stv epl wpl searing burning badlands blasted hinterlands silithus tanaris ungoro winterspring felwood feralas")
end

local function describeTest(message)
    local request = looksLikeSummonRequest(message)
    local loc, ambiguous = findLocation(message)
    if not request then
        chat("test: NOT A SUMMON REQUEST")
        return
    end
    if ambiguous then
        chat("test: request, location=AMBIGUOUS DM, decision=IGNORE")
        return
    end
    if not loc then
        chat("test: request, location=UNKNOWN, decision=" .. ((SummonScoutDB.service or "all") == "all" and "INVITE" or "IGNORE"))
        return
    end
    chat("test: request, location=" .. loc.label .. ", decision=" .. (locationAllowed(loc, nil) and "INVITE" or "IGNORE"))
end

local function slash(msg)
    msg = trim(msg)
    local _, _, cmd, rest = string.find(msg, "^(%S+)%s*(.-)$")
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
    elseif cmd == "serve" and trim(rest) ~= "" then
        local id, label = resolveLocationName(rest)
        if id then
            SummonScoutDB.service = id
            chat("serving -> " .. label)
        else
            chat("unknown/ambiguous place: " .. rest .. " (use /ssi places)")
        end
    elseif cmd == "places" then
        showPlaces()
    elseif cmd == "test" and trim(rest) ~= "" then
        describeTest(rest)
    elseif cmd == "status" or cmd == "" then
        status()
    else
        chat("/ssi on|off|status | serve <place|all> | places | channel <name> | debug on/off | test <message>")
    end
end

local frame = CreateFrame("Frame", "SummonScoutFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        setDefaults()
        chat("loaded; watching #" .. (SummonScoutDB.channel or "world") .. "; serving=" .. servedLocationLabel())
        return
    end

    if event == "CHAT_MSG_CHANNEL" then
        if not SummonScoutDB.enabled then return end

        local message = arg1 or ""
        local sender = arg2 or ""
        local channelBaseName = arg9 or ""

        if not channelMatches(channelBaseName) or not looksLikeSummonRequest(message) then
            return
        end

        local loc, ambiguous = findLocation(message)
        if locationAllowed(loc, ambiguous) then
            queueInvite(sender, message, loc)
        elseif SummonScoutDB.debug then
            if ambiguous then
                chat("ignore: " .. sender .. " [ambiguous DM] -> " .. message)
            elseif loc then
                chat("ignore: " .. sender .. " [" .. loc.label .. "], serving=" .. servedLocationLabel())
            else
                chat("ignore: " .. sender .. " [unknown place], serving=" .. servedLocationLabel())
            end
        end
    end
end)
frame:SetScript("OnUpdate", function()
    processQueue()
end)

SLASH_SUMMONSCOUT1 = "/ssi"
SLASH_SUMMONSCOUT2 = "/summonscout"
SlashCmdList["SUMMONSCOUT"] = slash
