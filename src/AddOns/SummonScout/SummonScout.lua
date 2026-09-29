-- SummonScout for World of Warcraft 1.12.1 (build 5875)
-- World summon request observer + destination classifier + optional auto-invite.
-- Persistent request statistics live in SummonScoutDB SavedVariables.

SummonScoutDB = SummonScoutDB or {}

local ADDON_VERSION = "1.17"
local SS = {}
SS.queue = {}
SS.queued = {}
SS.recent = {}
SS.loggedRecent = {}
SS.nextInviteAt = 0
SS.nextSpamAt = 0
SS.counterAt = 0
SS.counterSender = nil
SS.counterLocationLabel = nil
SS.lastCounterAt = -100000
SS.lastInvitedName = nil
SS.lastInvitedLocation = nil
SS.lastInvitedAt = 0
SS.tradeRequestedBy = nil
SS.tradePartner = nil
SS.tradeMoneyBefore = 0
SS.tradeTargetMoney = 0
SS.tradeBothAccepted = false
SS.tradeActive = false
SS.gui = nil
SS.nextGuiRefreshAt = 0
SS.partyKnown = {}
SS.partyRosterReady = false
SS.partySyncAt = 0
SS.summonQueue = {}
SS.summonQueued = {}
SS.summonActiveName = nil
SS.summonActiveExpires = 0
SS.summonActiveStarted = false
SS.summonWhisperRecent = {}
SS.lastAdvertMessage = ""
SS.lastAdvertSentAt = -100000
SS.lastSummonRequestAt = -100000
SS.lastSummonRequestName = nil
SS.lastSummonError = ""

local LOCATIONS = {
    -- Instances / raids. More specific / colliding aliases first.
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
    { id="hyjal", label="Mount Hyjal", aliases={"mount hyjal", "hyjal"} },
    { id="felwood", label="Felwood", aliases={"felwood"} },
    { id="feralas", label="Feralas", aliases={"feralas"} },
    { id="desolace", label="Desolace", aliases={"desolace"} },
    { id="hydraxian", label="Hydraxian Waterlords (Azshara)", aliases={"azshara", "hydraxian waterlords"}, roots={"hydrax"} },
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

local function wallTime()
    if time then return time() end
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

local function tokenHasRoot(s, root)
    root = normalizeMessage(root)
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

local REQUEST_CUES = {
    "need", "lf", "lf summon", "lf summ", "wtb", "buy", "want", "looking",
    "pls", "plz", "please", "can i", "could i", "anyone",
    "who can", "inv", "invite", "me", "port"
}

local WHISPER_INVITE_CUES = {
    "inv", "invite", "invite me", "port", "summon me", "sum me",
    "can i get a summon", "can i get summon", "need summon", "need summ",
    "lf summon", "lf summ", "wtb summon", "wtb summ"
}

local WHISPER_PRICE_CUES = {
    "how much", "price", "cost", "fee"
}

local WHISPER_EXACT_CODES = {
    ["123"] = true
}

-- Strong buyer intent only. Generic words such as "me", "inv" and "port"
-- are intentionally excluded because seller ads often contain "whisper me",
-- "invite me" or "portal/port" language.
local BUYER_INTENT_CUES = {
    "need", "lf", "lf summon", "lf summ", "wtb", "buy", "want", "looking",
    "can i", "could i", "anyone", "who can"
}

local SELLER_CUES = {
    "wts", "selling", "sell", "service", "available", "offering",
    "summons available", "summon service", "summoning service",
    "selling summon", "sell summon", "summoning to", "summoning portals",
    "portal service", "pst", "whisper me", "dm me"
}

local function hasCue(s, cues)
    local j
    for j = 1, table.getn(cues) do
        if phraseHas(s, cues[j]) then return true end
    end
    return false
end

local function hasRequestCue(s)
    return hasCue(s, REQUEST_CUES)
end

local function hasBuyerIntentCue(s)
    return hasCue(s, BUYER_INTENT_CUES)
end

local function hasSellerCue(s)
    return hasCue(s, SELLER_CUES)
end

local function hasSummonToken(s)
    return phraseHas(s, "summon")
        or phraseHas(s, "summons")
        or phraseHas(s, "summoning")
        or phraseHas(s, "summ")
        or phraseHas(s, "summs")
        or phraseHas(s, "sum")
        or phraseHas(s, "sumon")
end

local function hasGoldPrice(s)
    return string.find(s, "%d+%s*g") ~= nil
end

local function isSellerMessage(s)
    s = normalizeMessage(s)
    if s == "" or not hasSummonToken(s) then return false end
    if hasBuyerIntentCue(s) then return false end
    if hasSellerCue(s) or hasGoldPrice(s) then return true end

    -- Common seller format: "<name> Summons: place1, place2, place3...".
    -- Keep the fallback long-only so a short buyer line like "summons hyjal?"
    -- still falls through to the request classifier instead of becoming an ad.
    if phraseHas(s, "summons") and string.len(s) >= 40 then return true end
    return false
end

local function looksLikeSummonRequest(message)
    local s = normalizeMessage(message)
    if s == "" or isSellerMessage(s) or not hasSummonToken(s) then
        return false
    end

    if hasRequestCue(s) then return true end

    if string.len(s) <= 32 then
        return true
    end
    return false
end

local function findLocation(message)
    local s = normalizeMessage(message)
    local j, k
    local plainDm = phraseHas(s, "dm")

    for j = 1, table.getn(LOCATIONS) do
        local loc = LOCATIONS[j]
        for k = 1, table.getn(loc.aliases) do
            if phraseHas(s, loc.aliases[k]) then
                return loc, nil
            end
        end
        if loc.roots then
            for k = 1, table.getn(loc.roots) do
                if tokenHasRoot(s, loc.roots[k]) then
                    return loc, nil
                end
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
        return ambiguous == nil
    end
    if ambiguous or not loc then return false end
    return loc.id == service
end

local function whisperInviteDecision(message)
    local s = normalizeMessage(message)
    local loc, ambiguous = findLocation(message)
    local service = SummonScoutDB.service or "all"
    local score = 0

    if s == "" or isSellerMessage(s) then return false, nil, "not-request" end
    if ambiguous then return false, nil, "ambiguous-location" end
    if WHISPER_EXACT_CODES[s] then score = score + 3 end

    -- Explicitly asking for another known destination must never trigger.
    if loc then
        if service ~= "all" and loc.id ~= service then
            return false, loc, "other-location"
        end
        score = score + 3
    end

    if hasSummonToken(s) then score = score + 3 end
    if hasCue(s, WHISPER_INVITE_CUES) then score = score + 3 end
    if hasBuyerIntentCue(s) then score = score + 2 end
    if hasCue(s, WHISPER_PRICE_CUES) then score = score + 1 end
    if hasGoldPrice(s) then score = score + 1 end

    -- Direct whispers are a strong signal, but generic chatter is ignored.
    if score < 3 then return false, loc, "weak-intent" end

    -- A destination-less whisper inherits this summoner's configured service.
    if not loc and service ~= "all" then
        loc = LOCATION_BY_ID[service]
    end
    return true, loc, "smart-match"
end

local function channelMatches(channelBaseName, channelFullName)
    local wanted = lower(trim(SummonScoutDB.channel or "world"))
    local base = lower(trim(channelBaseName or ""))
    local full = lower(trim(channelFullName or ""))
    local stripped = full

    -- Vanilla normally exposes arg9 as the base name, but private servers can
    -- be inconsistent. Accept the visible form too, e.g. "5. World".
    stripped = string.gsub(stripped, "^%s*%d+%s*%.%s*", "")
    stripped = trim(stripped)

    return wanted ~= "" and (base == wanted or stripped == wanted)
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

local function logKey(sender, message)
    return lower(sender or "") .. "|" .. normalizeMessage(message)
end

local function shouldLogRequest(sender, message)
    local key = logKey(sender, message)
    local last = SS.loggedRecent[key]
    local t = now()
    if last and (t - last) < (SummonScoutDB.logDedupeSeconds or 60) then
        return false
    end
    SS.loggedRecent[key] = t
    return true
end

local function ensureStats()
    if type(SummonScoutDB.stats) ~= "table" then SummonScoutDB.stats = {} end
    if type(SummonScoutDB.stats.byLocation) ~= "table" then SummonScoutDB.stats.byLocation = {} end
    if type(SummonScoutDB.requestLog) ~= "table" then SummonScoutDB.requestLog = {} end
    if SummonScoutDB.stats.total == nil then SummonScoutDB.stats.total = 0 end
    if SummonScoutDB.stats.unknown == nil then SummonScoutDB.stats.unknown = 0 end
    if SummonScoutDB.stats.ambiguous == nil then SummonScoutDB.stats.ambiguous = 0 end
    if type(SummonScoutDB.paymentLog) ~= "table" then SummonScoutDB.paymentLog = {} end
    if SummonScoutDB.revenueCopper == nil then SummonScoutDB.revenueCopper = 0 end
    if SummonScoutDB.paymentCount == nil then SummonScoutDB.paymentCount = 0 end
end

local function logRequest(sender, message, loc, ambiguous)
    if not SummonScoutDB.loggingEnabled then return end
    if not shouldLogRequest(sender, message) then return end
    ensureStats()

    local id
    local label
    if ambiguous then
        id = "ambiguous_dm"
        label = "AMBIGUOUS DM"
        SummonScoutDB.stats.ambiguous = SummonScoutDB.stats.ambiguous + 1
    elseif loc then
        id = loc.id
        label = loc.label
        SummonScoutDB.stats.byLocation[id] = (SummonScoutDB.stats.byLocation[id] or 0) + 1
    else
        id = "unknown"
        label = "UNKNOWN"
        SummonScoutDB.stats.unknown = SummonScoutDB.stats.unknown + 1
    end

    SummonScoutDB.stats.total = SummonScoutDB.stats.total + 1
    SummonScoutDB.requestLog[table.getn(SummonScoutDB.requestLog) + 1] = {
        ts = wallTime(),
        sender = trim(sender),
        message = message or "",
        locationId = id,
        locationLabel = label
    }

    local maxEntries = SummonScoutDB.maxLogEntries or 200
    while table.getn(SummonScoutDB.requestLog) > maxEntries do
        table.remove(SummonScoutDB.requestLog, 1)
    end

    if SummonScoutDB.debug then
        chat("logged: " .. trim(sender) .. " [" .. label .. "] -> " .. (message or ""))
    end
end

local function formatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < 0 then copper = 0 end
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local coin = math.mod(copper, 100)
    if gold > 0 then
        return tostring(gold) .. "g " .. tostring(silver) .. "s " .. tostring(coin) .. "c"
    elseif silver > 0 then
        return tostring(silver) .. "s " .. tostring(coin) .. "c"
    end
    return tostring(coin) .. "c"
end

local function masterReady()
    local name = trim(SummonScoutDB.masterName or "")
    return SummonScoutDB.masterReportingEnabled
        and name ~= ""
        and not samePlayer(name, UnitName("player"))
end

local function reportMaster(kind, text)
    if not masterReady() or not SendChatMessage then return false end
    SendChatMessage("[SSI " .. tostring(kind or "INFO") .. "] " .. tostring(text or ""),
        "WHISPER", nil, trim(SummonScoutDB.masterName or ""))
    return true
end

local function guiRefreshSafe()
    if SS.guiRefresh then SS.guiRefresh() end
end

local function recordInvite(name, loc)
    local label = loc and loc.label or "?"
    SS.lastInvitedName = trim(name)
    SS.lastInvitedLocation = label
    SS.lastInvitedAt = now()
    if SummonScoutDB.masterReportInvites then
        reportMaster("INVITE", SS.lastInvitedName .. " -> " .. label)
    end
    guiRefreshSafe()
end

local function currentTradePartner()
    local name
    if UnitName then
        name = UnitName("NPC")
        if trim(name or "") ~= "" then return trim(name) end
    end
    if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        name = TradeFrameRecipientNameText:GetText()
        if trim(name or "") ~= "" then return trim(name) end
    end
    if trim(SS.tradeRequestedBy or "") ~= "" then return trim(SS.tradeRequestedBy) end
    if SS.lastInvitedName and (now() - (SS.lastInvitedAt or 0)) < 600 then
        return SS.lastInvitedName
    end
    return "UNKNOWN"
end

local function resetTradeState()
    SS.tradeRequestedBy = nil
    SS.tradePartner = nil
    SS.tradeMoneyBefore = 0
    SS.tradeTargetMoney = 0
    SS.tradeBothAccepted = false
    SS.tradeActive = false
end

local function beginTrade()
    -- Some 1.12/custom-server UIs can surface TRADE_SHOW more than once for
    -- the same window. Never overwrite the wallet snapshot mid-session.
    if SS.tradeActive then return end
    SS.tradeActive = true
    SS.tradePartner = currentTradePartner()
    SS.tradeMoneyBefore = GetMoney and GetMoney() or 0
    SS.tradeTargetMoney = GetTargetTradeMoney and GetTargetTradeMoney() or 0
    SS.tradeBothAccepted = false
end

local function recordPayment(name, copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return end
    ensureStats()

    name = trim(name or "")
    if name == "" then name = "UNKNOWN" end

    SummonScoutDB.revenueCopper = (SummonScoutDB.revenueCopper or 0) + copper
    SummonScoutDB.paymentCount = (SummonScoutDB.paymentCount or 0) + 1
    SummonScoutDB.paymentLog[table.getn(SummonScoutDB.paymentLog) + 1] = {
        ts = wallTime(),
        player = name,
        copper = copper
    }
    while table.getn(SummonScoutDB.paymentLog) > 100 do
        table.remove(SummonScoutDB.paymentLog, 1)
    end

    if SummonScoutDB.masterReportPayments then
        reportMaster("PAID", name .. " -> " .. formatMoney(copper)
            .. " | total " .. formatMoney(SummonScoutDB.revenueCopper or 0))
    end
    if SummonScoutDB.paymentChatEnabled then
        chat("received gold from " .. name .. ": " .. formatMoney(copper))
    end
    guiRefreshSafe()
end

local function finishTrade()
    if not SS.tradeActive then return end

    local partner = SS.tradePartner or currentTradePartner()
    local before = SS.tradeMoneyBefore or 0
    local offered = SS.tradeTargetMoney or 0
    local accepted = SS.tradeBothAccepted
    local after = GetMoney and GetMoney() or before
    local delta = after - before
    local amount = 0

    -- Close the session first so a duplicate TRADE_CLOSED cannot record again.
    resetTradeState()

    -- The payer's accepted offer is the authoritative per-trade amount.
    -- Wallet delta is only a fallback when the acceptance event was missed.
    if accepted and offered > 0 then
        amount = offered
    elseif offered > 0 and delta > 0 then
        amount = offered
    elseif accepted and delta > 0 then
        amount = delta
    end

    if amount > 0 then
        recordPayment(partner, amount)
    end
end

local function playerIsCasting()
    return CastingBarFrame and (CastingBarFrame.casting or CastingBarFrame.channeling)
end

local function groupUnitByName(name)
    local j
    for j = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        local unit = "party" .. j
        if samePlayer(UnitName(unit), name) then return unit end
    end
    for j = 1, (GetNumRaidMembers and GetNumRaidMembers() or 0) do
        local unit = "raid" .. j
        if samePlayer(UnitName(unit), name) then return unit end
    end
    return nil
end

local function queuePartySummon(name)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return end
    if SS.summonQueued[lower(name)] then return end
    SS.summonQueued[lower(name)] = true
    SS.summonQueue[table.getn(SS.summonQueue) + 1] = {
        name = name,
        attempts = 0,
        phase = "target",
        nextAt = now() + 0.35
    }
    chat("party join -> summon queued: " .. name)
end

local function syncPartyRoster(suppressNew)
    local current = {}
    local j

    local function observeUnit(unit)
        local name = trim(UnitName(unit) or "")
        if name == "" or samePlayer(name, UnitName("player")) then return end
        current[lower(name)] = name
        if SS.partyRosterReady and not suppressNew and not SS.partyKnown[lower(name)]
            and SummonScoutDB.partyAutoSummon then
            queuePartySummon(name)
        end
    end

    for j = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        observeUnit("party" .. j)
    end
    for j = 1, (GetNumRaidMembers and GetNumRaidMembers() or 0) do
        observeUnit("raid" .. j)
    end

    SS.partyKnown = current
    SS.partyRosterReady = true
end

local function findSpellBookSlot(spellName)
    if not GetSpellName then return nil, nil end
    local book = BOOKTYPE_SPELL or "spell"
    local wanted = lower(spellName or "")
    local index
    for index = 1, 200 do
        local name = GetSpellName(index, book)
        if not name then break end
        if lower(name) == wanted then
            return index, book
        end
    end
    return nil, book
end

local function castRitualOnUnit(unit)
    local slot, book = findSpellBookSlot("Ritual of Summoning")
    local requested = false
    local method = "none"

    SS.lastSummonRequestAt = now()
    SS.lastSummonRequestName = trim(UnitName(unit) or UnitName("target") or "")
    SS.lastSummonError = ""

    if CastSpellByName then
        CastSpellByName("Ritual of Summoning")
        requested = true
        method = "by-name"
    elseif slot and CastSpell then
        CastSpell(slot, book)
        requested = true
        method = "spellbook"
    end

    if requested and SpellIsTargeting and SpellIsTargeting() and SpellTargetUnit then
        SpellTargetUnit(unit)
    end
    return requested, slot, method
end

local function summonDestinationLabel()
    local service = SummonScoutDB.service or "all"
    if service ~= "all" then
        local loc = LOCATION_BY_ID[service]
        if loc and loc.label then return loc.label end
    end
    if GetZoneText then
        local zone = trim(GetZoneText() or "")
        if zone ~= "" then return zone end
    end
    return "my location"
end

local function whisperSummonTarget(name)
    name = trim(name)
    if not SummonScoutDB.summonWhisperEnabled or name == "" or not SendChatMessage then return end

    local key = lower(name)
    local t = now()
    local cooldown = tonumber(SummonScoutDB.summonWhisperCooldown) or 10
    if cooldown < 1 then cooldown = 1 end
    if cooldown > 120 then cooldown = 120 end

    local last = SS.summonWhisperRecent[key]
    if last and (t - last) < cooldown then
        if SummonScoutDB.debug then
            chat("summon whisper suppressed -> " .. name .. " [cooldown]")
        end
        return
    end

    SendChatMessage("Summoning you to " .. summonDestinationLabel() .. ".", "WHISPER", nil, name)
    SS.summonWhisperRecent[key] = t
end

local function clearActiveSummon()
    SS.summonActiveName = nil
    SS.summonActiveExpires = 0
    SS.summonActiveStarted = false
end

local function finishActiveSummon(name)
    name = trim(name or SS.summonActiveName or "")
    if name ~= "" then
        SS.summonQueued[lower(name)] = nil
        if table.getn(SS.summonQueue) > 0 and samePlayer(SS.summonQueue[1].name, name) then
            table.remove(SS.summonQueue, 1)
        else
            local j
            for j = table.getn(SS.summonQueue), 1, -1 do
                if samePlayer(SS.summonQueue[j].name, name) then
                    table.remove(SS.summonQueue, j)
                    break
                end
            end
        end
    end
    clearActiveSummon()
end

local function retryActiveSummon(delay)
    local name = SS.summonActiveName
    clearActiveSummon()
    if name and table.getn(SS.summonQueue) > 0 and samePlayer(SS.summonQueue[1].name, name) then
        SS.summonQueue[1].phase = "target"
        SS.summonQueue[1].nextAt = now() + (delay or 0.50)
    end
end

local function processPartySummon()
    if not SummonScoutDB.enabled or not SummonScoutDB.partyAutoSummon then return end
    if SS.summonActiveName then
        if now() < (SS.summonActiveExpires or 0) then return end
        if SS.summonActiveStarted then
            finishActiveSummon(SS.summonActiveName)
        else
            retryActiveSummon(0.20)
        end
        return
    end
    if table.getn(SS.summonQueue) == 0 then return end
    if playerIsCasting() then return end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return end

    local item = SS.summonQueue[1]
    local unit = groupUnitByName(item.name)
    if not unit then
        finishActiveSummon(item.name)
        return
    end
    if UnitIsConnected and not UnitIsConnected(unit) then
        item.nextAt = now() + 2
        return
    end
    if now() < (item.nextAt or 0) then return end

    -- Vanilla is more reliable when target selection and spell execution are
    -- separated by a short UI-frame settle instead of happening back-to-back.
    if not item.phase or item.phase == "target" then
        if TargetUnit then
            TargetUnit(unit)
        elseif TargetByName then
            TargetByName(item.name, true)
        end
        item.phase = "cast"
        item.nextAt = now() + 0.20
        return
    end

    if item.phase == "cast" then
        if not samePlayer(UnitName("target"), item.name) then
            item.phase = "target"
            item.nextAt = now() + 0.10
            return
        end

        item.attempts = (item.attempts or 0) + 1
        if item.attempts > 3 then
            chat("summon failed after retries: " .. item.name)
            finishActiveSummon(item.name)
            return
        end

        SS.summonActiveName = item.name
        SS.summonActiveStarted = false
        SS.summonActiveExpires = now() + 1.25

        local requested, slot, method = castRitualOnUnit(unit)
        if requested then
            item.phase = SS.summonActiveStarted and "casting" or "wait"
            item.nextAt = now() + 1.25
            if SummonScoutDB.debug then
                chat("summon cast requested -> " .. item.name
                    .. " attempt " .. tostring(item.attempts)
                    .. " method=" .. tostring(method)
                    .. (slot and (" spellbook=" .. tostring(slot)) or ""))
            end
        else
            chat("cannot cast Ritual of Summoning: spell API unavailable")
            finishActiveSummon(item.name)
        end
        return
    end

    if item.phase == "wait" then
        -- No SPELLCAST_START arrived: retry the target+cast sequence.
        item.phase = "target"
        item.nextAt = now() + 0.10
    end
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

local function tryImmediateInvite(name, loc)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return false end
    if table.getn(SS.queue) ~= 0 then return false end
    if now() < SS.nextInviteAt then return false end
    if isInGroup(name) or recentlyHandled(name) or SS.queued[lower(name)] then return false end

    -- Fast path for the first eligible request after idle: invite directly from
    -- CHAT_MSG_CHANNEL instead of waiting for the next OnUpdate frame.
    local t = now()
    SS.recent[lower(name)] = t
    SS.nextInviteAt = t + (SummonScoutDB.inviteDelay or 0.8)
    InviteByName(name)
    recordInvite(name, loc)
    chat("invite -> " .. name .. " [" .. (loc and loc.label or "?") .. "]")
    return true
end


local function counterDelay(sender, message)
    local minDelay = tonumber(SummonScoutDB.counterDelayMin) or 4
    local maxDelay = tonumber(SummonScoutDB.counterDelayMax) or 8
    local seed = math.floor(now() * 10)
    local key = lower(sender or "") .. "|" .. normalizeMessage(message or "")
    local j

    if minDelay < 1 then minDelay = 1 end
    if maxDelay < minDelay then maxDelay = minDelay end
    if maxDelay > 60 then maxDelay = 60 end

    for j = 1, string.len(key) do
        seed = math.mod((seed * 33) + string.byte(key, j), 1000003)
    end

    local tenths = math.floor((maxDelay - minDelay) * 10)
    if tenths <= 0 then return minDelay end
    return minDelay + (math.mod(seed, tenths + 1) / 10)
end

local function counterLocationAllowed(loc, ambiguous)
    local scope = SummonScoutDB.counterScope or "all"
    if scope == "all" then return true end

    if ambiguous or not loc then return false end
    local service = SummonScoutDB.service or "all"
    return service == "all" or loc.id == service
end

local function clearCounterPending()
    SS.counterAt = 0
    SS.counterSender = nil
    SS.counterLocationLabel = nil
end

local function scheduleCounter(sender, message, loc, ambiguous)
    if not SummonScoutDB.counterEnabled then return end
    if trim(SummonScoutDB.spamMessage or "") == "" then return end
    if not counterLocationAllowed(loc, ambiguous) then return end
    if SS.counterAt and SS.counterAt > 0 then return end

    local cooldown = tonumber(SummonScoutDB.counterCooldown) or 60
    local t = now()
    if cooldown < 15 then cooldown = 15 end
    if cooldown > 3600 then cooldown = 3600 end
    if (t - (SS.lastCounterAt or -100000)) < cooldown then return end

    local lastOwnAdvert = tonumber(SummonScoutDB.lastAdvertWall) or 0
    local wall = wallTime()
    if lastOwnAdvert > 0 and wall >= lastOwnAdvert and (wall - lastOwnAdvert) < cooldown then
        if SummonScoutDB.debug then chat("counter suppressed: recent own advert") end
        return
    end

    local delay = counterDelay(sender, message)
    SS.counterAt = t + delay
    SS.counterSender = trim(sender)
    SS.counterLocationLabel = loc and loc.label or "?"
    if SummonScoutDB.debug then
        chat("competitor " .. SS.counterSender .. " [" .. SS.counterLocationLabel
            .. "] -> counter in " .. tostring(delay) .. "s")
    end
end

local function configuredChannelId()
    if not GetChannelName then return 0 end
    local id = GetChannelName(SummonScoutDB.channel or "World")
    if type(id) ~= "number" then return 0 end
    return id
end

local function sendSpamMessage(manual)
    local message = trim(SummonScoutDB.spamMessage or "")
    if message == "" then
        if manual then chat("spam message is empty; use /ssi spammsg <text>") end
        return false
    end

    local normalized = normalizeMessage(message)
    local wall = wallTime()
    local sharedLast = tonumber(SummonScoutDB.lastAdvertWall) or 0
    local sharedSame = normalized ~= ""
        and normalized == (SummonScoutDB.lastAdvertNormalized or "")
        and sharedLast > 0 and wall >= sharedLast and (wall - sharedLast) < 15
    local localSame = normalized == normalizeMessage(SS.lastAdvertMessage or "")
        and (now() - (SS.lastAdvertSentAt or -100000)) < 15

    if not manual and (sharedSame or localSame) then
        if SummonScoutDB.debug then chat("duplicate advert suppressed") end
        return true, "suppressed"
    end

    local channelId = configuredChannelId()
    if not channelId or channelId <= 0 then
        if manual or SummonScoutDB.debug then
            chat("cannot send spam: not joined to #" .. (SummonScoutDB.channel or "World"))
        end
        return false
    end

    if SendChatMessage then
        SendChatMessage(message, "CHANNEL", nil, channelId)
        SS.lastAdvertMessage = message
        SS.lastAdvertSentAt = now()
        SummonScoutDB.lastAdvertNormalized = normalized
        SummonScoutDB.lastAdvertWall = wall
        if manual or SummonScoutDB.debug then
            chat("spam -> #" .. (SummonScoutDB.channel or "World") .. ": " .. message)
        end
        return true, "sent"
    end
    return false, "failed"
end

local function processCounter()
    if not SummonScoutDB.enabled or not SummonScoutDB.counterEnabled then
        clearCounterPending()
        return
    end
    if not SS.counterAt or SS.counterAt <= 0 then return end

    local t = now()
    if t < SS.counterAt then return end

    local sender = SS.counterSender or "?"
    local ok, result = sendSpamMessage(false)
    if ok then
        SS.lastCounterAt = t
        clearCounterPending()

        -- A competitive response is already an advert. Push the regular
        -- scheduler out by its full interval to avoid two posts back-to-back.
        if SummonScoutDB.spamEnabled then
            SS.nextSpamAt = t + (SummonScoutDB.spamInterval or 120)
        end
        if result == "sent" then
            chat("counter sent -> " .. sender)
        elseif SummonScoutDB.debug then
            chat("counter handled without send -> " .. sender .. " [duplicate cooldown]")
        end
    else
        -- World temporarily unavailable: retain one pending response and retry
        -- slowly rather than create additional queued advertisements.
        SS.counterAt = t + 10
    end
end

local function processSpam()
    if not SummonScoutDB.enabled or not SummonScoutDB.spamEnabled then return end
    if SS.counterAt and SS.counterAt > 0 then return end

    local t = now()
    if SS.nextSpamAt == 0 then
        SS.nextSpamAt = t + 1
        return
    end
    if t < SS.nextSpamAt then return end

    local interval = tonumber(SummonScoutDB.spamInterval) or 120
    if interval < 30 then interval = 30 end
    if interval > 3600 then interval = 3600 end

    if sendSpamMessage(false) then
        SS.nextSpamAt = t + interval
    else
        -- Channel unavailable: retry later without hammering the API.
        SS.nextSpamAt = t + 10
    end
end

local function processQueue()
    if not SummonScoutDB.enabled or not SummonScoutDB.autoInvite then return end
    if now() < SS.nextInviteAt then return end

    local item = popInvite()
    if not item then return end
    if isInGroup(item.name) or recentlyHandled(item.name) then return end

    SS.recent[lower(item.name)] = now()
    SS.nextInviteAt = now() + (SummonScoutDB.inviteDelay or 0.8)
    InviteByName(item.name)
    recordInvite(item.name, item.locationId and LOCATION_BY_ID[item.locationId] or nil)
    chat("invite -> " .. item.name .. " [" .. (item.locationLabel or "?") .. "]")
end

local function setDefaults()
    if SummonScoutDB.enabled == nil then SummonScoutDB.enabled = true end
    if SummonScoutDB.autoInvite == nil then SummonScoutDB.autoInvite = true end
    if SummonScoutDB.loggingEnabled == nil then SummonScoutDB.loggingEnabled = true end
    if SummonScoutDB.channel == nil then SummonScoutDB.channel = "world" end
    if SummonScoutDB.duplicateSeconds == nil then SummonScoutDB.duplicateSeconds = 120 end
    if SummonScoutDB.inviteDelay == nil then SummonScoutDB.inviteDelay = 0.8 end
    if SummonScoutDB.logDedupeSeconds == nil then SummonScoutDB.logDedupeSeconds = 60 end
    if SummonScoutDB.maxLogEntries == nil then SummonScoutDB.maxLogEntries = 200 end
    if SummonScoutDB.debug == nil then SummonScoutDB.debug = false end
    if SummonScoutDB.service == nil then SummonScoutDB.service = "all" end
    if SummonScoutDB.spamEnabled == nil then SummonScoutDB.spamEnabled = false end
    if SummonScoutDB.spamInterval == nil then SummonScoutDB.spamInterval = 120 end
    if SummonScoutDB.spamMessage == nil then SummonScoutDB.spamMessage = "" end
    if SummonScoutDB.counterEnabled == nil then SummonScoutDB.counterEnabled = false end
    if SummonScoutDB.counterDelayMin == nil then SummonScoutDB.counterDelayMin = 4 end
    if SummonScoutDB.counterDelayMax == nil then SummonScoutDB.counterDelayMax = 8 end
    if SummonScoutDB.counterCooldown == nil then SummonScoutDB.counterCooldown = 60 end
    if SummonScoutDB.counterScope == nil then SummonScoutDB.counterScope = "all" end
    if SummonScoutDB.masterReportingEnabled == nil then SummonScoutDB.masterReportingEnabled = false end
    if SummonScoutDB.masterName == nil then SummonScoutDB.masterName = "" end
    if SummonScoutDB.masterReportInvites == nil then SummonScoutDB.masterReportInvites = true end
    if SummonScoutDB.masterReportPayments == nil then SummonScoutDB.masterReportPayments = true end
    if SummonScoutDB.whisperAutoInvite == nil then SummonScoutDB.whisperAutoInvite = true end
    if SummonScoutDB.summonWhisperCooldown == nil then SummonScoutDB.summonWhisperCooldown = 10 end
    if SummonScoutDB.partyAutoSummon == nil then SummonScoutDB.partyAutoSummon = false end
    if SummonScoutDB.summonWhisperEnabled == nil then SummonScoutDB.summonWhisperEnabled = true end
    if SummonScoutDB.paymentChatEnabled == nil then SummonScoutDB.paymentChatEnabled = true end
    if SummonScoutDB.lastAdvertNormalized == nil then SummonScoutDB.lastAdvertNormalized = "" end
    if SummonScoutDB.lastAdvertWall == nil then SummonScoutDB.lastAdvertWall = 0 end
    ensureStats()
end

local function status()
    ensureStats()
    chat("v" .. ADDON_VERSION .. " enabled=" .. (SummonScoutDB.enabled and "ON" or "OFF")
        .. ", invite=" .. (SummonScoutDB.autoInvite and "ON" or "OFF")
        .. ", log=" .. (SummonScoutDB.loggingEnabled and "ON" or "OFF")
        .. ", channel=" .. (SummonScoutDB.channel or "world")
        .. ", serving=" .. servedLocationLabel()
        .. ", requests=" .. tostring(SummonScoutDB.stats.total or 0)
        .. ", spam=" .. (SummonScoutDB.spamEnabled and "ON" or "OFF")
        .. "/" .. tostring(SummonScoutDB.spamInterval or 120) .. "s"
        .. ", counter=" .. (SummonScoutDB.counterEnabled and "ON" or "OFF")
        .. "/" .. tostring(SummonScoutDB.counterDelayMin or 4)
        .. "-" .. tostring(SummonScoutDB.counterDelayMax or 8)
        .. "s cd=" .. tostring(SummonScoutDB.counterCooldown or 60) .. "s"
        .. " scope=" .. tostring(SummonScoutDB.counterScope or "all")
        .. ", master=" .. (SummonScoutDB.masterReportingEnabled and (trim(SummonScoutDB.masterName or "") ~= "" and SummonScoutDB.masterName or "NO-NAME") or "OFF")
        .. ", whisperInvite=" .. (SummonScoutDB.whisperAutoInvite and "ON" or "OFF")
        .. ", partySummon=" .. (SummonScoutDB.partyAutoSummon and "ON" or "OFF")
        .. ", summonWhisper=" .. (SummonScoutDB.summonWhisperEnabled and "ON" or "OFF")
        .. ", revenue=" .. formatMoney(SummonScoutDB.revenueCopper or 0)
        .. ", queue=" .. tostring(table.getn(SS.queue)))
end

local function showPlaces()
    chat("instances: rfc wc deadmines/vc sfk bfd stocks gnomer rfk sm rfd ulda zf mara sunken-temple brd brs scholo strat")
    chat("endgame: dme dmn dmw dire-maul mc ony bwl zg aq20 aq40 naxx")
    chat("cities/hubs: org uc tb sw darn kargath gadgetzan ratchet lhc everlook cenarion crossroads")
    chat("zones: stv epl wpl searing burning badlands blasted hinterlands silithus tanaris ungoro winterspring felwood feralas")
end

local function showStats()
    ensureStats()
    local rows = {}
    local id, count
    for id, count in pairs(SummonScoutDB.stats.byLocation) do
        rows[table.getn(rows) + 1] = { id=id, count=count }
    end
    table.sort(rows, function(a, b)
        if a.count == b.count then return a.id < b.id end
        return a.count > b.count
    end)

    chat("requests total=" .. tostring(SummonScoutDB.stats.total or 0)
        .. ", unknown=" .. tostring(SummonScoutDB.stats.unknown or 0)
        .. ", ambiguousDM=" .. tostring(SummonScoutDB.stats.ambiguous or 0))

    local limit = math.min(table.getn(rows), 10)
    local j
    for j = 1, limit do
        local loc = LOCATION_BY_ID[rows[j].id]
        chat("#" .. tostring(j) .. " " .. (loc and loc.label or rows[j].id) .. " = " .. tostring(rows[j].count))
    end
    if limit == 0 then chat("no recognized destinations logged yet") end
end

local function showRecent(filterUnknown, limit)
    ensureStats()
    limit = tonumber(limit) or 10
    if limit < 1 then limit = 1 end
    if limit > 30 then limit = 30 end

    local shown = 0
    local j
    for j = table.getn(SummonScoutDB.requestLog), 1, -1 do
        local item = SummonScoutDB.requestLog[j]
        if not filterUnknown or item.locationId == "unknown" then
            chat((item.locationLabel or "?") .. " | " .. (item.sender or "?") .. ": " .. (item.message or ""))
            shown = shown + 1
            if shown >= limit then break end
        end
    end
    if shown == 0 then
        chat(filterUnknown and "no UNKNOWN requests logged" or "request log is empty")
    end
end

local function clearPayments()
    SummonScoutDB.paymentLog = {}
    SummonScoutDB.revenueCopper = 0
    SummonScoutDB.paymentCount = 0
    chat("payment ledger cleared")
    guiRefreshSafe()
end

local function clearStats()
    SummonScoutDB.stats = { total=0, unknown=0, ambiguous=0, byLocation={} }
    SummonScoutDB.requestLog = {}
    SS.loggedRecent = {}
    chat("request statistics and recent log cleared")
end

local function showSummonCheck()
    local slot = findSpellBookSlot("Ritual of Summoning")
    local queued = table.getn(SS.summonQueue) > 0 and SS.summonQueue[1].name or "-"
    local target = trim(UnitName("target") or "")
    local targetUnit = queued ~= "-" and groupUnitByName(queued) or nil
    local shards = GetItemCount and GetItemCount(6265) or -1
    chat("summoncheck v" .. ADDON_VERSION
        .. " spellbook=" .. tostring(slot or "NONE")
        .. " byName=" .. (CastSpellByName and "YES" or "NO")
        .. " CastSpell=" .. (CastSpell and "YES" or "NO")
        .. " shards=" .. tostring(shards))
    chat("summoncheck queued=" .. queued
        .. " groupUnit=" .. tostring(targetUnit or "-")
        .. " target=" .. (target ~= "" and target or "-")
        .. " combat=" .. ((UnitAffectingCombat and UnitAffectingCombat("player")) and "YES" or "NO")
        .. " lastError=" .. (SS.lastSummonError ~= "" and SS.lastSummonError or "-"))
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

local function describeCounterTest(message)
    local s = normalizeMessage(message)
    local loc, ambiguous = findLocation(message)
    local seller = isSellerMessage(s)
    local allowed = seller and counterLocationAllowed(loc, ambiguous)
    if seller then
        chat("countertest: OFFER, location="
            .. (ambiguous and "AMBIGUOUS DM" or (loc and loc.label or "UNKNOWN"))
            .. ", decision=" .. (allowed and "COUNTER" or "IGNORE"))
    else
        chat("countertest: NOT A SUMMON OFFER")
    end
end

local GUI = {}
local guiRefresh
local guiControlId = 0

local function guiText(parent, text, x, y, small)
    local fs = parent:CreateFontString(nil, "OVERLAY", small and "GameFontNormalSmall" or "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text or "")
    return fs
end

local function guiHeader(parent, text, x, y)
    local fs = guiText(parent, text, x, y, false)
    fs:SetTextColor(1.0, 0.82, 0.0)
    return fs
end

local function guiName(prefix)
    guiControlId = guiControlId + 1
    return "SummonScout" .. prefix .. tostring(guiControlId)
end

local function guiCheck(parent, x, y, label, getter, setter)
    local b = CreateFrame("CheckButton", guiName("Check"), parent, "UICheckButtonTemplate")
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetWidth(20)
    b:SetHeight(20)
    b.ssGetter = getter
    guiText(parent, label, x + 22, y - 2, true)
    b:SetScript("OnClick", function()
        setter(b:GetChecked() and true or false)
        if guiRefresh then guiRefresh() end
    end)
    return b
end

local function guiEdit(parent, x, y, width, text)
    local e = CreateFrame("EditBox", guiName("Edit"), parent, "InputBoxTemplate")
    e:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    e:SetWidth(width)
    e:SetHeight(22)
    e:SetAutoFocus(false)
    e:SetMaxLetters(220)
    e:SetText(text or "")
    e.ssFocused = false
    e:SetScript("OnEditFocusGained", function() e.ssFocused = true end)
    e:SetScript("OnEditFocusLost", function() e.ssFocused = false end)
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    return e
end

local function guiButton(parent, x, y, width, text, onClick)
    local b = CreateFrame("Button", guiName("Button"), parent, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetWidth(width)
    b:SetHeight(22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function guiApplyService()
    local value = trim(GUI.serviceEdit and GUI.serviceEdit:GetText() or "")
    local id, label = resolveLocationName(value)
    if id then
        SummonScoutDB.service = id
        chat("serving -> " .. label)
    else
        chat("unknown/ambiguous place: " .. value)
    end
    if guiRefresh then guiRefresh() end
end

local function guiSaveAdvert()
    local value = trim(GUI.advertEdit and GUI.advertEdit:GetText() or "")
    if string.len(value) > 220 then
        chat("spam message too long (max 220 chars)")
        return
    end
    SummonScoutDB.spamMessage = value
    chat("advert saved")
    if guiRefresh then guiRefresh() end
end

local function guiSaveMaster()
    local value = trim(GUI.masterEdit and GUI.masterEdit:GetText() or "")
    SummonScoutDB.masterName = value
    chat("master -> " .. (value ~= "" and value or "<empty>"))
    if guiRefresh then guiRefresh() end
end

local function guiSaveSummonWhisperCd()
    local seconds = tonumber(trim(GUI.summonWhisperCdEdit and GUI.summonWhisperCdEdit:GetText() or ""))
    if not seconds or seconds < 1 or seconds > 120 then
        chat("summon whisper cooldown must be 1-120 seconds")
        if GUI.summonWhisperCdEdit then
            GUI.summonWhisperCdEdit:SetText(tostring(SummonScoutDB.summonWhisperCooldown or 10))
        end
        return
    end
    SummonScoutDB.summonWhisperCooldown = math.floor(seconds)
    chat("summon whisper cooldown -> " .. tostring(SummonScoutDB.summonWhisperCooldown) .. "s")
    if guiRefresh then guiRefresh() end
end

local function createGui()
    if GUI.frame then return GUI.frame end

    local f = CreateFrame("Frame", "SummonScoutOptionsFrame", UIParent)
    f:SetWidth(720)
    f:SetHeight(560)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.035, 0.025, 0.045, 0.96)
    f:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("SummonScout " .. ADDON_VERSION .. " Control Center")
    title:SetTextColor(1.0, 0.82, 0.0)

    guiButton(f, 682, -8, 26, "X", function() f:Hide() end)

    guiHeader(f, "Automation", 28, -46)
    GUI.enabledCheck = guiCheck(f, 26, -68, "SummonScout enabled",
        function() return SummonScoutDB.enabled end,
        function(v) SummonScoutDB.enabled = v end)
    GUI.inviteCheck = guiCheck(f, 26, -94, "World smart auto invite",
        function() return SummonScoutDB.autoInvite end,
        function(v) SummonScoutDB.autoInvite = v end)
    GUI.whisperInviteCheck = guiCheck(f, 26, -120, "Whisper smart auto invite",
        function() return SummonScoutDB.whisperAutoInvite end,
        function(v) SummonScoutDB.whisperAutoInvite = v end)
    GUI.partySummonCheck = guiCheck(f, 26, -146, "Auto summon new party member",
        function() return SummonScoutDB.partyAutoSummon end,
        function(v)
            SummonScoutDB.partyAutoSummon = v
            if not v then
                SS.summonQueue = {}
                SS.summonQueued = {}
                SS.summonActiveName = nil
            end
            syncPartyRoster(true)
        end)
    GUI.summonWhisperCheck = guiCheck(f, 26, -172, "Whisper summon destination",
        function() return SummonScoutDB.summonWhisperEnabled end,
        function(v) SummonScoutDB.summonWhisperEnabled = v end)
    guiText(f, "CD:", 220, -176, true)
    GUI.summonWhisperCdEdit = guiEdit(f, 244, -171, 38, tostring(SummonScoutDB.summonWhisperCooldown or 10))
    GUI.summonWhisperCdEdit:SetMaxLetters(3)
    guiButton(f, 286, -171, 40, "Set", guiSaveSummonWhisperCd)
    GUI.logCheck = guiCheck(f, 26, -198, "Demand logging",
        function() return SummonScoutDB.loggingEnabled end,
        function(v) SummonScoutDB.loggingEnabled = v end)
    GUI.counterCheck = guiCheck(f, 26, -224, "Competitive response",
        function() return SummonScoutDB.counterEnabled end,
        function(v)
            if v and trim(SummonScoutDB.spamMessage or "") == "" then
                chat("set advert text first")
                SummonScoutDB.counterEnabled = false
            else
                SummonScoutDB.counterEnabled = v
                if not v then clearCounterPending() end
            end
        end)
    GUI.spamCheck = guiCheck(f, 26, -250, "Periodic World advert",
        function() return SummonScoutDB.spamEnabled end,
        function(v)
            if v and trim(SummonScoutDB.spamMessage or "") == "" then
                chat("set advert text first")
                SummonScoutDB.spamEnabled = false
            else
                SummonScoutDB.spamEnabled = v
                SS.nextSpamAt = v and (now() + 1) or 0
            end
        end)
    GUI.scopeCheck = guiCheck(f, 26, -276, "Counter all summon sellers",
        function() return (SummonScoutDB.counterScope or "all") == "all" end,
        function(v)
            SummonScoutDB.counterScope = v and "all" or "same"
            clearCounterPending()
        end)

    guiHeader(f, "Service / advert", 28, -314)
    guiText(f, "Serve:", 28, -338, true)
    GUI.serviceEdit = guiEdit(f, 80, -331, 155, SummonScoutDB.service or "all")
    guiButton(f, 244, -331, 66, "Apply", guiApplyService)

    guiText(f, "World text:", 28, -370, true)
    GUI.advertEdit = guiEdit(f, 100, -363, 210, SummonScoutDB.spamMessage or "")
    guiButton(f, 244, -394, 66, "Save", guiSaveAdvert)

    guiHeader(f, "Master reporting", 370, -46)
    GUI.masterEnabledCheck = guiCheck(f, 368, -68, "Report to master character",
        function() return SummonScoutDB.masterReportingEnabled end,
        function(v) SummonScoutDB.masterReportingEnabled = v end)
    GUI.masterInviteCheck = guiCheck(f, 368, -94, "Report invite attempts",
        function() return SummonScoutDB.masterReportInvites end,
        function(v) SummonScoutDB.masterReportInvites = v end)
    GUI.masterPaymentCheck = guiCheck(f, 368, -120, "Report received payments",
        function() return SummonScoutDB.masterReportPayments end,
        function(v) SummonScoutDB.masterReportPayments = v end)
    GUI.paymentChatCheck = guiCheck(f, 368, -146, "Show received gold in chat",
        function() return SummonScoutDB.paymentChatEnabled end,
        function(v) SummonScoutDB.paymentChatEnabled = v end)

    guiText(f, "Master:", 370, -184, true)
    GUI.masterEdit = guiEdit(f, 430, -177, 170, SummonScoutDB.masterName or "")
    guiButton(f, 608, -177, 70, "Save", guiSaveMaster)
    guiButton(f, 608, -206, 70, "Test", function()
        if not reportMaster("TEST", "reporting online from " .. (UnitName("player") or "?")) then
            chat("master reporting is OFF or master name is empty")
        end
    end)

    guiHeader(f, "Live operation", 370, -252)
    GUI.lastInviteText = guiText(f, "Last invite: -", 370, -276, true)
    GUI.lastPaymentText = guiText(f, "Last payment: -", 370, -300, true)
    GUI.revenueText = guiText(f, "Received total: 0c", 370, -324, true)
    GUI.currentGoldText = guiText(f, "Current gold: 0c", 370, -348, true)
    GUI.counterText = guiText(f, "Counter: -", 370, -372, true)
    GUI.summonStateText = guiText(f, "Summon: idle", 370, -396, true)
    guiButton(f, 586, -316, 92, "Reset total", function() clearPayments() end)
    GUI.stateText = guiText(f, "State: -", 28, -450, true)
    GUI.helpText = guiText(f, "/ssi gui toggles this panel. Settings persist in SummonScoutDB.", 28, -524, true)

    f:Hide()
    GUI.frame = f
    SS.gui = f
    return f
end

guiRefresh = function()
    local f = createGui()
    local checks = {
        GUI.enabledCheck, GUI.inviteCheck, GUI.whisperInviteCheck,
        GUI.partySummonCheck, GUI.summonWhisperCheck, GUI.logCheck,
        GUI.counterCheck, GUI.spamCheck, GUI.scopeCheck, GUI.masterEnabledCheck,
        GUI.masterInviteCheck, GUI.masterPaymentCheck, GUI.paymentChatCheck
    }
    local i
    for i = 1, table.getn(checks) do
        local c = checks[i]
        if c and c.ssGetter then c:SetChecked(c.ssGetter() and 1 or nil) end
    end

    if GUI.summonWhisperCdEdit and not GUI.summonWhisperCdEdit.ssFocused then
        GUI.summonWhisperCdEdit:SetText(tostring(SummonScoutDB.summonWhisperCooldown or 10))
    end

    if GUI.lastInviteText then
        GUI.lastInviteText:SetText("Last invite: " .. (SS.lastInvitedName or "-")
            .. (SS.lastInvitedLocation and (" -> " .. SS.lastInvitedLocation) or ""))
    end

    local last = SummonScoutDB.paymentLog and SummonScoutDB.paymentLog[table.getn(SummonScoutDB.paymentLog)]
    if GUI.lastPaymentText then
        GUI.lastPaymentText:SetText("Last payment: "
            .. (last and ((last.player or "?") .. " -> " .. formatMoney(last.copper or 0)) or "-"))
    end
    if GUI.revenueText then
        GUI.revenueText:SetText("Received total: " .. formatMoney(SummonScoutDB.revenueCopper or 0)
            .. " | payments: " .. tostring(SummonScoutDB.paymentCount or 0))
    end
    if GUI.currentGoldText then
        GUI.currentGoldText:SetText("Current gold: " .. formatMoney(GetMoney and GetMoney() or 0))
    end
    if GUI.counterText then
        local pending = SS.counterAt and SS.counterAt > now()
        GUI.counterText:SetText("Counter: " .. (SummonScoutDB.counterEnabled and "ON" or "OFF")
            .. " | scope " .. tostring(SummonScoutDB.counterScope or "all")
            .. (pending and (" | pending " .. tostring(math.ceil(SS.counterAt - now())) .. "s") or ""))
    end
    if GUI.summonStateText then
        local pendingName = SS.summonActiveName
            or (table.getn(SS.summonQueue) > 0 and SS.summonQueue[1].name)
            or "-"
        GUI.summonStateText:SetText("Summon: " .. pendingName
            .. (SS.lastSummonError ~= "" and (" | " .. SS.lastSummonError) or ""))
    end
    if GUI.stateText then
        GUI.stateText:SetText("Serve: " .. servedLocationLabel()
            .. " | invite " .. (SummonScoutDB.autoInvite and "ON" or "OFF")
            .. " | World advert " .. (SummonScoutDB.spamEnabled and "ON" or "OFF")
            .. " | master " .. (SummonScoutDB.masterReportingEnabled and (trim(SummonScoutDB.masterName or "") ~= "" and SummonScoutDB.masterName or "NO NAME") or "OFF"))
    end
    return f
end

SS.guiRefresh = guiRefresh

local function toggleGui()
    local f = createGui()
    guiRefresh()
    if f:IsShown() then f:Hide() else f:Show() end
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
    elseif cmd == "observe" then
        SummonScoutDB.enabled = true
        SummonScoutDB.loggingEnabled = true
        SummonScoutDB.autoInvite = false
        SS.queue = {}
        SS.queued = {}
        chat("observe mode: logging ON, auto-invite OFF")
        status()
    elseif cmd == "invite" then
        rest = lower(trim(rest))
        if rest == "on" then SummonScoutDB.autoInvite = true end
        if rest == "off" then
            SummonScoutDB.autoInvite = false
            SS.queue = {}
            SS.queued = {}
        end
        status()
    elseif cmd == "log" then
        rest = lower(trim(rest))
        if rest == "on" then SummonScoutDB.loggingEnabled = true end
        if rest == "off" then SummonScoutDB.loggingEnabled = false end
        status()
    elseif cmd == "spam" then
        rest = lower(trim(rest))
        if rest == "on" then
            if trim(SummonScoutDB.spamMessage or "") == "" then
                chat("set text first: /ssi spammsg <text>")
            else
                SummonScoutDB.spamEnabled = true
                SS.nextSpamAt = now() + 1
                status()
            end
        elseif rest == "off" then
            SummonScoutDB.spamEnabled = false
            SS.nextSpamAt = 0
            status()
        else
            chat("use /ssi spam on|off")
        end
    elseif cmd == "spammsg" then
        rest = trim(rest)
        if rest == "" then
            chat("spam message: " .. (trim(SummonScoutDB.spamMessage or "") ~= "" and SummonScoutDB.spamMessage or "<empty>"))
        elseif string.len(rest) > 220 then
            chat("spam message too long (max 220 chars)")
        else
            SummonScoutDB.spamMessage = rest
            chat("spam message set: " .. rest)
        end
    elseif cmd == "spamsec" then
        local seconds = tonumber(trim(rest))
        if not seconds or seconds < 30 or seconds > 3600 then
            chat("spam interval must be 30-3600 seconds")
        else
            SummonScoutDB.spamInterval = math.floor(seconds)
            if SummonScoutDB.spamEnabled then SS.nextSpamAt = now() + SummonScoutDB.spamInterval end
            chat("spam interval -> " .. tostring(SummonScoutDB.spamInterval) .. "s")
        end
    elseif cmd == "spamnow" then
        if sendSpamMessage(true) then
            clearCounterPending()
            if SummonScoutDB.spamEnabled then
                SS.nextSpamAt = now() + (SummonScoutDB.spamInterval or 120)
            end
        end
    elseif cmd == "counter" then
        rest = lower(trim(rest))
        if rest == "on" then
            if trim(SummonScoutDB.spamMessage or "") == "" then
                chat("set text first: /ssi spammsg <text>")
            else
                SummonScoutDB.counterEnabled = true
                status()
            end
        elseif rest == "off" then
            SummonScoutDB.counterEnabled = false
            clearCounterPending()
            status()
        else
            chat("use /ssi counter on|off")
        end
    elseif cmd == "counterdelay" then
        local _, _, a, b = string.find(trim(rest), "^(%d+)%s+(%d+)$")
        local minDelay = tonumber(a)
        local maxDelay = tonumber(b)
        if not minDelay or not maxDelay or minDelay < 1 or maxDelay < minDelay or maxDelay > 60 then
            chat("counter delay must be: /ssi counterdelay <1-60> <min..60>")
        else
            SummonScoutDB.counterDelayMin = minDelay
            SummonScoutDB.counterDelayMax = maxDelay
            chat("counter delay -> " .. tostring(minDelay) .. "-" .. tostring(maxDelay) .. "s")
        end
    elseif cmd == "countercool" then
        local seconds = tonumber(trim(rest))
        if not seconds or seconds < 15 or seconds > 3600 then
            chat("counter cooldown must be 15-3600 seconds")
        else
            SummonScoutDB.counterCooldown = math.floor(seconds)
            chat("counter cooldown -> " .. tostring(SummonScoutDB.counterCooldown) .. "s")
        end
    elseif cmd == "counterscope" then
        rest = lower(trim(rest))
        if rest == "all" or rest == "same" then
            SummonScoutDB.counterScope = rest
            clearCounterPending()
            chat("counter scope -> " .. rest)
        else
            chat("use /ssi counterscope all|same")
        end
    elseif cmd == "countertest" and trim(rest) ~= "" then
        describeCounterTest(rest)
    elseif cmd == "gui" or cmd == "options" then
        toggleGui()
    elseif cmd == "master" then
        local sub = lower(trim(rest))
        if sub == "on" then
            SummonScoutDB.masterReportingEnabled = true
            status()
        elseif sub == "off" then
            SummonScoutDB.masterReportingEnabled = false
            status()
        elseif trim(rest) ~= "" then
            SummonScoutDB.masterName = trim(rest)
            chat("master -> " .. SummonScoutDB.masterName)
            guiRefreshSafe()
        else
            chat("use /ssi master <name>|on|off")
        end
    elseif cmd == "reporttest" then
        if not reportMaster("TEST", "reporting online from " .. (UnitName("player") or "?")) then
            chat("master reporting is OFF or master name is empty")
        end
    elseif cmd == "whisperinvite" then
        rest = lower(trim(rest))
        if rest == "on" then SummonScoutDB.whisperAutoInvite = true end
        if rest == "off" then SummonScoutDB.whisperAutoInvite = false end
        status()
    elseif cmd == "partysummon" then
        rest = lower(trim(rest))
        if rest == "on" then
            SummonScoutDB.partyAutoSummon = true
            syncPartyRoster(true)
        elseif rest == "off" then
            SummonScoutDB.partyAutoSummon = false
            SS.summonQueue = {}
            SS.summonQueued = {}
            SS.summonActiveName = nil
        end
        status()
    elseif cmd == "summonwhisper" then
        rest = lower(trim(rest))
        if rest == "on" then SummonScoutDB.summonWhisperEnabled = true end
        if rest == "off" then SummonScoutDB.summonWhisperEnabled = false end
        status()
    elseif cmd == "summonwhispercd" then
        local seconds = tonumber(trim(rest))
        if not seconds or seconds < 1 or seconds > 120 then
            chat("summon whisper cooldown must be 1-120 seconds")
        else
            SummonScoutDB.summonWhisperCooldown = math.floor(seconds)
            chat("summon whisper cooldown -> " .. tostring(SummonScoutDB.summonWhisperCooldown) .. "s")
        end
    elseif cmd == "paymentchat" then
        rest = lower(trim(rest))
        if rest == "on" then SummonScoutDB.paymentChatEnabled = true end
        if rest == "off" then SummonScoutDB.paymentChatEnabled = false end
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
    elseif cmd == "stats" then
        showStats()
    elseif cmd == "recent" then
        showRecent(false, trim(rest))
    elseif cmd == "unknown" then
        showRecent(true, trim(rest))
    elseif cmd == "clearpayments" then
        if lower(trim(rest)) == "confirm" then
            clearPayments()
        else
            chat("use /ssi clearpayments confirm")
        end
    elseif cmd == "clearstats" then
        if lower(trim(rest)) == "confirm" then
            clearStats()
        else
            chat("use /ssi clearstats confirm")
        end
    elseif cmd == "summoncheck" then
        showSummonCheck()
    elseif cmd == "version" then
        chat("version " .. ADDON_VERSION)
    elseif cmd == "test" and trim(rest) ~= "" then
        describeTest(rest)
    elseif cmd == "status" or cmd == "" then
        status()
    else
        chat("/ssi on|off|status | observe | invite on/off | log on/off | stats | recent [n] | unknown [n]")
        chat("/ssi spam on|off | spammsg <text> | spamsec <30-3600> | spamnow")
        chat("/ssi counter on|off | counterscope all|same | counterdelay <min> <max> | countercool <15-3600>")
        chat("/ssi countertest <message> | gui")
        chat("/ssi master <name>|on|off | reporttest")
        chat("/ssi whisperinvite on|off | partysummon on|off | summonwhisper on|off | summonwhispercd <1-120>")
        chat("/ssi paymentchat on|off")
        chat("/ssi clearpayments confirm | summoncheck | version")
        chat("/ssi serve <place|all> | places | channel <name> | debug on/off | test <message> | clearstats confirm")
    end
end

local frame = CreateFrame("Frame", "SummonScoutFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("TRADE_REQUEST")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_MONEY_CHANGED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("SPELLCAST_START")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        setDefaults()
        syncPartyRoster(true)
        chat("v" .. ADDON_VERSION .. " loaded; watching #" .. (SummonScoutDB.channel or "world")
            .. "; serving=" .. servedLocationLabel()
            .. "; logged=" .. tostring(SummonScoutDB.stats.total or 0))
        return
    end

    if event == "UI_ERROR_MESSAGE" or event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" then
        if (now() - (SS.lastSummonRequestAt or -100000)) < 3 then
            SS.lastSummonError = trim(arg1 or "spell rejected")
            chat("summon rejected -> " .. SS.lastSummonError)
            guiRefreshSafe()
        end
        return
    end

    if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        SS.partySyncAt = now() + 0.20
        return
    end

    if event == "CHAT_MSG_WHISPER" then
        if not SummonScoutDB.enabled or not SummonScoutDB.whisperAutoInvite then return end
        local message = arg1 or ""
        local sender = trim(arg2 or "")
        if sender == "" or samePlayer(sender, UnitName("player")) or isInGroup(sender) then return end
        local accept, loc, reason = whisperInviteDecision(message)
        if accept then
            if not tryImmediateInvite(sender, loc) then
                queueInvite(sender, message, loc)
            end
            if SummonScoutDB.debug then
                chat("whisper invite match -> " .. sender .. " [" .. (loc and loc.label or servedLocationLabel()) .. "]")
            end
        elseif SummonScoutDB.debug then
            chat("whisper ignore -> " .. sender .. " [" .. tostring(reason) .. "]")
        end
        return
    end

    if event == "SPELLCAST_START" then
        local spell = normalizeMessage(arg1 or "")
        if spell == "ritual of summoning" then
            local targetName = trim(SS.summonActiveName or UnitName("target") or "")
            if targetName ~= "" then whisperSummonTarget(targetName) end

            if SS.summonActiveName and samePlayer(UnitName("target"), SS.summonActiveName) then
                SS.summonActiveStarted = true
                SS.summonActiveExpires = now() + 8.0
                if table.getn(SS.summonQueue) > 0
                    and samePlayer(SS.summonQueue[1].name, SS.summonActiveName) then
                    SS.summonQueue[1].phase = "casting"
                end
            end
        end
        return
    end

    if event == "SPELLCAST_STOP" then
        if SS.summonActiveName and SS.summonActiveStarted then
            if SummonScoutDB.debug then
                chat("summon cast completed -> " .. SS.summonActiveName)
            end
            finishActiveSummon(SS.summonActiveName)
        end
        return
    end

    if event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        if SS.summonActiveName then
            local spell = normalizeMessage(arg1 or "")
            if spell == "" or spell == "ritual of summoning" then
                if SummonScoutDB.debug then
                    chat("summon cast retry -> " .. SS.summonActiveName)
                end
                retryActiveSummon(0.75)
            end
        end
        return
    end

    if event == "TRADE_REQUEST" then
        SS.tradeRequestedBy = trim(arg1 or "")
        return
    end

    if event == "TRADE_SHOW" then
        beginTrade()
        return
    end

    if event == "TRADE_MONEY_CHANGED" then
        if GetTargetTradeMoney then
            SS.tradeTargetMoney = GetTargetTradeMoney() or SS.tradeTargetMoney or 0
        end
        if not SS.tradePartner or SS.tradePartner == "" then
            SS.tradePartner = currentTradePartner()
        end
        return
    end

    if event == "TRADE_ACCEPT_UPDATE" then
        SS.tradeBothAccepted = (arg1 == 1 and arg2 == 1) and true or false
        if GetTargetTradeMoney then
            SS.tradeTargetMoney = GetTargetTradeMoney() or SS.tradeTargetMoney or 0
        end
        if not SS.tradePartner or SS.tradePartner == "" then
            SS.tradePartner = currentTradePartner()
        end
        return
    end

    if event == "TRADE_CLOSED" then
        finishTrade()
        return
    end

    if event == "CHAT_MSG_CHANNEL" then
        if not SummonScoutDB.enabled then return end

        local message = arg1 or ""
        local sender = arg2 or ""
        local channelBaseName = arg9 or ""
        local channelFullName = arg4 or ""

        if not channelMatches(channelBaseName, channelFullName) then
            return
        end

        -- Never react to this character's own advertisement/request.
        if samePlayer(sender, UnitName("player")) then return end

        local loc, ambiguous = findLocation(message)

        -- Seller detection is independent from buyer detection. Competitor ads
        -- never enter demand statistics or the invite queue.
        if isSellerMessage(message) then
            scheduleCounter(sender, message, loc, ambiguous)
            return
        end

        if not looksLikeSummonRequest(message) then return end

        local inviteCandidate = SummonScoutDB.autoInvite and locationAllowed(loc, ambiguous)

        -- Lowest-latency path: the first eligible request after idle is invited
        -- synchronously in CHAT_MSG_CHANNEL. Only subsequent/cooldown requests
        -- use the OnUpdate queue.
        if inviteCandidate then
            if not tryImmediateInvite(sender, loc) then
                queueInvite(sender, message, loc)
            end
        end

        -- Keep demand accounting, but do it after the latency-critical invite
        -- path so statistics cannot delay the first InviteByName().
        logRequest(sender, message, loc, ambiguous)

        if not inviteCandidate and SummonScoutDB.debug then
            if not SummonScoutDB.autoInvite then
                chat("observe only: " .. sender .. " -> " .. message)
            elseif ambiguous then
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
    if SS.partySyncAt and SS.partySyncAt > 0 and now() >= SS.partySyncAt then
        SS.partySyncAt = 0
        syncPartyRoster(false)
    end
    processQueue()
    processPartySummon()
    processCounter()
    processSpam()
    if SS.gui and SS.gui:IsShown() and guiRefresh and now() >= (SS.nextGuiRefreshAt or 0) then
        SS.nextGuiRefreshAt = now() + 0.5
        guiRefresh()
    end
end)

SLASH_SUMMONSCOUT1 = "/ssi"
SLASH_SUMMONSCOUT2 = "/summonscout"
SlashCmdList["SUMMONSCOUT"] = slash
