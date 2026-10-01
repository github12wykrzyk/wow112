-- SummonScout for World of Warcraft 1.12.1 (build 5875)
-- World summon request observer + destination classifier + optional auto-invite.
-- Persistent request statistics live in SummonScoutDB SavedVariables.

SummonScoutDB = SummonScoutDB or {}

local ADDON_VERSION = "1.47"
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
SS.pendingTrade = nil
SS.gui = nil
SS.nextGuiRefreshAt = 0
SS.partyKnown = {}
SS.partyRosterReady = false
SS.partySyncAt = 0
SS.nextRosterPollAt = 0
SS.summonPending = {}
SS.summonActiveName = nil
SS.summonActiveQueuedAt = 0
SS.summonActiveAttempts = 0
SS.summonActiveRequestSeq = nil
SS.summonActiveNextAt = 0
SS.summonActiveExpires = 0
SS.summonActiveStarted = false
SS.summonActiveStartReported = false
SS.summonWhisperRecent = {}
SS.whisperInviteRecent = {}
SS.pendingManualInvites = {}
SS.lastAdvertMessage = ""
SS.lastAdvertSentAt = -100000
SS.lastSummonRequestAt = -100000
SS.lastSummonRequestName = nil
SS.lastSummonError = ""
SS.summonRequestSeq = 0
SS.shardGuardPaused = false
SS.shardGuardLastCount = -1
SS.shardGuardNextCheckAt = 0

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
    { id="hydraxian", label="Hydraxian Waterlords (Azshara)", aliases={"azshara", "azsh", "hydraxian waterlords"}, roots={"hydrax"} },
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
    "lf summon", "lf summ", "wtb summon", "wtb summ",
    "still summoning", "take one", "i d take one", "ill take one", "i ll take one"
}

local WHISPER_PRICE_CUES = {
    "how much", "price", "cost", "fee"
}

local WHISPER_PAYMENT_OFFER_CUES = {
    "i can pay", "can pay", "i will pay", "will pay",
    "i ll pay", "ill pay", "happy to pay", "pay you"
}

local WHISPER_PAYMENT_NEGATIVE_CUES = {
    "cannot pay", "cant pay", "can t pay",
    "wont pay", "won t pay", "will not pay",
    "not paying", "no pay"
}

local WHISPER_EXACT_CODES = {
    ["123"] = true,
    ["here"] = true,
    ["sure"] = true,
    ["+"] = true
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

-- Recruitment chatter can contain both a buyer-looking token ("LF"/"need")
-- and "summon" even though the sender is explicitly saying that THEIR group
-- can provide the summon. Keep this separate from seller detection so a farm/
-- group recruitment post never triggers an invite or a competitive counter.
local RECRUITMENT_ROLE_CUES = {
    "warrior", "mage", "rogue", "priest", "warlock", "hunter", "druid",
    "paladin", "shaman", "tank", "healer", "heals", "heal", "dps",
    "melee", "ranged", "caster"
}

local OWN_SUMMON_CUES = {
    "can summon", "can summ", "we can summon", "we can summ",
    "i can summon", "i can summ", "have summon", "have a summon",
    "got summon", "got a summon", "summon available"
}

local DIRECT_SUMMON_REQUEST_CUES = {
    "lf summon", "lf summ", "need summon", "need summ",
    "wtb summon", "wtb summ", "want summon", "want summ",
    "looking for summon", "looking for summ",
    "summon me", "sum me", "who can summon", "who can summ",
    "anyone can summon", "anybody can summon",
    "can someone summon", "can somebody summon",
    "can you summon", "could you summon", "can u summon", "could u summon"
}

local function hasCue(s, cues)
    local j
    for j = 1, table.getn(cues) do
        if phraseHas(s, cues[j]) then return true end
    end
    return false
end

local function isRecruitmentWithOwnSummon(message)
    local s = normalizeMessage(message)
    local recruitmentLead

    if s == "" or not hasCue(s, OWN_SUMMON_CUES) then return false end

    -- Never suppress genuine requests merely because they contain the words
    -- "can summon", e.g. "who can summon me" or "can you summon".
    if hasCue(s, DIRECT_SUMMON_REQUEST_CUES) then return false end

    recruitmentLead = phraseHas(s, "lf")
        or phraseHas(s, "lfm")
        or has(s, "lf1m")
        or has(s, "lf2m")
        or has(s, "lf3m")
        or phraseHas(s, "looking for")
        or phraseHas(s, "need")
        or phraseHas(s, "needed")

    if not recruitmentLead then return false end

    -- A role/class target is the strongest signal. Farm/run/group vocabulary
    -- covers posts such as "LF Mage for ... farm. Can summon."
    if hasCue(s, RECRUITMENT_ROLE_CUES)
        or phraseHas(s, "farm")
        or phraseHas(s, "run")
        or phraseHas(s, "group")
        or phraseHas(s, "grp") then
        return true
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

local function hasWhisperPaymentOffer(s)
    if not hasGoldPrice(s) then return false end
    if hasCue(s, WHISPER_PAYMENT_NEGATIVE_CUES) then return false end
    return hasCue(s, WHISPER_PAYMENT_OFFER_CUES)
end

local function findLocationsInMessage(message)
    local s = normalizeMessage(message)
    local found = {}
    local seen = {}
    local j, k

    for j = 1, table.getn(LOCATIONS) do
        local loc = LOCATIONS[j]
        local matched = false
        for k = 1, table.getn(loc.aliases) do
            if phraseHas(s, loc.aliases[k]) then
                matched = true
                break
            end
        end
        if not matched and loc.roots then
            for k = 1, table.getn(loc.roots) do
                if tokenHasRoot(s, loc.roots[k]) then
                    matched = true
                    break
                end
            end
        end
        if matched and not seen[loc.id] then
            seen[loc.id] = true
            found[table.getn(found) + 1] = loc
        end
    end

    return found
end

local function locationListLabel(locations)
    local labels = {}
    local j
    for j = 1, table.getn(locations or {}) do
        labels[table.getn(labels) + 1] = locations[j].label
    end
    if table.getn(labels) == 0 then return "UNKNOWN" end
    return table.concat(labels, " + ")
end

local function isSellerMessage(message)
    local raw = lower(message or "")
    local s = normalizeMessage(message)
    local locations
    local locationCount

    if s == "" or not hasSummonToken(s) then return false end
    if hasBuyerIntentCue(s) then return false end
    if hasSellerCue(s) or hasGoldPrice(s) then return true end

    locations = findLocationsInMessage(s)
    locationCount = table.getn(locations)

    -- Multiple known destinations plus a summon token is a strong offer
    -- signal even when the seller omits WTS, price or the word "service".
    if locationCount >= 2 then return true end

    -- One known destination with active/plural seller wording is also enough,
    -- but keep explicit questions out of this fallback.
    if locationCount >= 1 and not string.find(raw, "?", 1, true) then
        if phraseHas(s, "summons") or phraseHas(s, "summoning")
            or phraseHas(s, "summon service") or phraseHas(s, "summon to") then
            return true
        end
    end

    if phraseHas(s, "summons") and string.len(s) >= 40 then return true end
    return false
end

local function looksLikeSummonRequest(message)
    local s = normalizeMessage(message)
    if s == "" or isRecruitmentWithOwnSummon(s)
        or isSellerMessage(message) or not hasSummonToken(s) then
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
    local locations = findLocationsInMessage(s)
    if table.getn(locations) > 0 then
        return locations[1], nil
    end
    if phraseHas(s, "dm") then
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

local function resolveServiceSpec(text)
    local raw = trim(text or "")
    if raw == "" then return nil, nil end
    if lower(raw) == "all" then return "all", "ALL" end

    raw = string.gsub(raw, ";", ",")
    local ids = {}
    local labels = {}
    local seen = {}
    local startAt = 1

    while true do
        local commaAt = string.find(raw, ",", startAt, true)
        local part
        if commaAt then
            part = trim(string.sub(raw, startAt, commaAt - 1))
        else
            part = trim(string.sub(raw, startAt))
        end

        if part ~= "" then
            local id, label = resolveLocationName(part)
            if not id or id == "all" then return nil, nil end
            if not seen[id] then
                seen[id] = true
                ids[table.getn(ids) + 1] = id
                labels[table.getn(labels) + 1] = label
            end
        end

        if not commaAt then break end
        startAt = commaAt + 1
    end

    if table.getn(ids) == 0 then return nil, nil end
    return table.concat(ids, ","), table.concat(labels, " + ")
end

local function serviceContains(locationId)
    local service = lower(trim(SummonScoutDB.service or "all"))
    if service == "all" then return true end
    if not locationId or locationId == "" then return false end
    local haystack = "," .. service .. ","
    local needle = "," .. lower(locationId) .. ","
    return string.find(haystack, needle, 1, true) ~= nil
end

local function singleServiceLocation()
    local service = lower(trim(SummonScoutDB.service or "all"))
    if service == "all" or string.find(service, ",", 1, true) then return nil end
    return LOCATION_BY_ID[service]
end

local function servedLocationLabel()
    local service = SummonScoutDB.service or "all"
    local _, label = resolveServiceSpec(service)
    return label or service
end

local function locationAllowed(loc, ambiguous)
    local service = lower(trim(SummonScoutDB.service or "all"))
    if service == "all" then
        return ambiguous == nil
    end
    if ambiguous or not loc then return false end
    return serviceContains(loc.id)
end

local function whisperInviteDecision(message)
    local raw = trim(message or "")
    local s = normalizeMessage(message)
    local loc, ambiguous = findLocation(message)
    local service = SummonScoutDB.service or "all"
    local score = 0
    local paymentOffer = hasWhisperPaymentOffer(s)
    -- Explicit one-word service codes such as "123", "here" and "sure" are
    -- accepted immediately. 123 also remains tolerant as a whole token in short
    -- whispers so normal politeness variants like "123 pls" still work.
    local exactCode = WHISPER_EXACT_CODES[s]
        or raw == "+"
        or (string.len(s) <= 32 and phraseHas(s, "123"))
    local directSummonQuestion = hasSummonToken(s)
        and (phraseHas(s, "can i")
            or phraseHas(s, "could i")
            or phraseHas(s, "can i get")
            or phraseHas(s, "could i get")
            or phraseHas(s, "get summon")
            or phraseHas(s, "get a summon")
            or phraseHas(s, "summon pls")
            or phraseHas(s, "summon please"))

    if (s == "" and not exactCode)
        or (s ~= "" and isSellerMessage(message) and not paymentOffer) then
        return false, nil, "not-request"
    end
    if ambiguous then return false, nil, "ambiguous-location" end
    if exactCode then score = score + 3 end
    if directSummonQuestion then score = score + 5 end
    if paymentOffer then score = score + 5 end

    -- Explicitly asking for another known destination must never trigger.
    if loc then
        if service ~= "all" and not serviceContains(loc.id) then
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
        local single = singleServiceLocation()
        if not single then return false, nil, "multi-service-needs-location" end
        loc = single
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

local function safeOutboundChat(value)
    local s = tostring(value or "")
    -- A literal pipe starts WoW chat escape sequences. ChatThrottleLib rejects
    -- unknown escapes (for example " | total "), so never send raw pipes.
    s = string.gsub(s, "|", "/")
    s = string.gsub(s, "[\r\n]", " ")
    s = string.gsub(s, "%s+", " ")
    s = trim(s)
    if string.len(s) > 240 then
        s = string.sub(s, 1, 240)
    end
    return s
end

local function reportMaster(kind, text)
    if not masterReady() or not SendChatMessage then return false end
    local payload = safeOutboundChat("[SSI " .. tostring(kind or "INFO") .. "] " .. tostring(text or ""))
    if payload == "" then return false end

    local master = trim(SummonScoutDB.masterName or "")
    if pcall then
        local ok = pcall(SendChatMessage, payload, "WHISPER", nil, master)
        if not ok then
            if SummonScoutDB.debug then
                chat("master report failed -> " .. tostring(kind or "INFO"))
            end
            return false
        end
    else
        SendChatMessage(payload, "WHISPER", nil, master)
    end
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
            .. " - total " .. formatMoney(SummonScoutDB.revenueCopper or 0))
    end
    if SummonScoutDB.paymentChatEnabled then
        chat("received gold from " .. name .. ": " .. formatMoney(copper))
    end
    guiRefreshSafe()
end

local function finishTrade()
    if not SS.tradeActive then return end

    -- TRADE_CLOSED can fire before GetMoney() reflects the received copper on
    -- this client/server. Snapshot the session and settle from the actual wallet
    -- change a few frames later instead of trusting GetTargetTradeMoney().
    SS.pendingTrade = {
        partner = SS.tradePartner or currentTradePartner(),
        before = SS.tradeMoneyBefore or (GetMoney and GetMoney() or 0),
        offered = SS.tradeTargetMoney or 0,
        accepted = SS.tradeBothAccepted and true or false,
        closedAt = now(),
        deadline = now() + 2.0
    }

    -- Close the session immediately so duplicate TRADE_CLOSED cannot enqueue twice.
    resetTradeState()
end

local function processPendingTrade()
    local p = SS.pendingTrade
    if not p then return end

    local after = GetMoney and GetMoney() or p.before
    local delta = after - (p.before or 0)

    if delta > 0 then
        -- Actual wallet gain is authoritative. This cannot accidentally count
        -- the character's pre-trade balance as revenue.
        SS.pendingTrade = nil
        recordPayment(p.partner, delta)
        return
    end

    if now() >= (p.deadline or 0) then
        if SummonScoutDB.debug and (p.offered or 0) > 0 then
            chat("trade closed with no positive wallet gain; payment ignored")
        end
        SS.pendingTrade = nil
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
        local raidName = GetRaidRosterInfo and GetRaidRosterInfo(j) or nil
        if samePlayer(raidName or UnitName(unit), name) then return unit end
    end
    return nil
end

local function ensureInviteBlacklist()
    if type(SummonScoutDB.inviteBlacklist) ~= "table" then
        SummonScoutDB.inviteBlacklist = {}
    end
    return SummonScoutDB.inviteBlacklist
end

local function inviteBlacklistKey(name)
    return lower(trim(name or ""))
end

local function invitePlayerBlacklisted(name)
    local key = inviteBlacklistKey(name)
    if key == "" then return false end
    return ensureInviteBlacklist()[key] ~= nil
end

local function inviteBlacklistNames()
    local names = {}
    local key, value
    for key, value in pairs(ensureInviteBlacklist()) do
        names[table.getn(names) + 1] = type(value) == "string" and value or key
    end
    table.sort(names)
    return names
end

local function inviteBlacklistSummary()
    local names = inviteBlacklistNames()
    if table.getn(names) == 0 then return "empty" end
    local shown = {}
    local j
    for j = 1, table.getn(names) do
        if j > 5 then break end
        shown[table.getn(shown) + 1] = names[j]
    end
    local suffix = table.getn(names) > 5 and (" +" .. tostring(table.getn(names) - 5)) or ""
    return table.concat(shown, ", ") .. suffix
end

local function purgeQueuedInvite(name)
    local key = inviteBlacklistKey(name)
    local j
    if key == "" then return end
    for j = table.getn(SS.queue), 1, -1 do
        if inviteBlacklistKey(SS.queue[j].name) == key then
            table.remove(SS.queue, j)
        end
    end
    SS.queued[key] = nil
    SS.pendingManualInvites[key] = nil
    SS.summonPending[key] = nil
end

local function addInviteBlacklist(name)
    name = trim(name or "")
    local key = inviteBlacklistKey(name)
    if key == "" then return false, "empty" end
    ensureInviteBlacklist()[key] = name
    purgeQueuedInvite(name)
    return true, name
end

local function removeInviteBlacklist(name)
    local key = inviteBlacklistKey(name)
    if key == "" then return false, "empty" end
    if not ensureInviteBlacklist()[key] then return false, "missing" end
    ensureInviteBlacklist()[key] = nil
    return true, trim(name)
end

local SUMMON_PLAYER_BLACKLIST = {
    ["hydraone"] = true,
    ["hydratwo"] = true,
    ["bolthyjal"] = true
}

local function summonPlayerBlacklisted(name)
    local key = lower(trim(name or ""))
    return SUMMON_PLAYER_BLACKLIST[key] == true or invitePlayerBlacklisted(name)
end

local function pendingSummonCount()
    local count = 0
    local _key
    for _key in pairs(SS.summonPending) do count = count + 1 end
    return count
end

local function oldestPendingSummon()
    local bestKey = nil
    local bestItem = nil
    local key, item
    for key, item in pairs(SS.summonPending) do
        if not bestItem or (item.queuedAt or 0) < (bestItem.queuedAt or 0) then
            bestKey = key
            bestItem = item
        end
    end
    return bestKey, bestItem
end

local function queuePartySummon(name)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return end
    if summonPlayerBlacklisted(name) then
        if SummonScoutDB.debug then chat("summon blacklist skip -> " .. name) end
        return
    end

    local key = lower(name)
    if SS.summonActiveName and samePlayer(SS.summonActiveName, name) then return end
    if SS.summonPending[key] then return end

    SS.summonPending[key] = {
        name = name,
        queuedAt = now(),
        readyAt = now() + 0.20
    }
    chat("party join -> summon pending: " .. name)
end

local function notePendingManualInvite(name)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return end
    if summonPlayerBlacklisted(name) then return end
    SS.pendingManualInvites[lower(name)] = {
        name = name,
        invitedAt = now()
    }
    if SummonScoutDB.debug then
        chat("invite tracked for summon -> " .. name)
    end
end

local function processPendingManualInvites()
    if not SummonScoutDB.enabled or not SummonScoutDB.partyAutoSummon then return end
    local t = now()
    local key, item
    for key, item in pairs(SS.pendingManualInvites) do
        if (t - (item.invitedAt or t)) > 90 then
            SS.pendingManualInvites[key] = nil
        elseif isInGroup(item.name) then
            queuePartySummon(item.name)
            SS.pendingManualInvites[key] = nil
        end
    end
end

local function syncPartyRoster(suppressNew)
    local current = {}
    local j

    local function observeUnit(unit)
        local name = trim(UnitName(unit) or "")
        if name == "" or samePlayer(name, UnitName("player")) then return end

        local key = lower(name)
        if current[key] then return end
        current[key] = name

        if SS.partyRosterReady and not suppressNew and not SS.partyKnown[key] then
            if SummonScoutDB.partyAutoSummon then
                queuePartySummon(name)
            end
            if SummonScoutDB.masterReportLifecycle and not summonPlayerBlacklisted(name) then
                reportMaster("JOIN", name .. " -> " .. servedLocationLabel())
            end
        end
    end

    for j = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        observeUnit("party" .. j)
    end
    for j = 1, (GetNumRaidMembers and GetNumRaidMembers() or 0) do
        local raidName = GetRaidRosterInfo and GetRaidRosterInfo(j) or nil
        if trim(raidName or "") ~= "" then
            local key = lower(raidName)
            if not current[key] and not samePlayer(raidName, UnitName("player")) then
                current[key] = raidName
                if SS.partyRosterReady and not suppressNew and not SS.partyKnown[key] then
                    if SummonScoutDB.partyAutoSummon then
                        queuePartySummon(raidName)
                    end
                    if SummonScoutDB.masterReportLifecycle and not summonPlayerBlacklisted(raidName) then
                        reportMaster("JOIN", raidName .. " -> " .. servedLocationLabel())
                    end
                end
            end
        else
            observeUnit("raid" .. j)
        end
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

local function countSoulShards()
    local total = 0
    if not GetContainerNumSlots or not GetContainerItemLink then return -1 end
    local bag, slot
    for bag = 0, 4 do
        local size = GetContainerNumSlots(bag) or 0
        for slot = 1, size do
            local link = GetContainerItemLink(bag, slot)
            if link and string.find(link, "|Hitem:6265:", 1, true) then
                local _, count = GetContainerItemInfo(bag, slot)
                total = total + (tonumber(count) or 1)
            end
        end
    end
    return total
end

local function shardGuardThreshold()
    local threshold = tonumber(SummonScoutDB.shardGuardMin) or 5
    threshold = math.floor(threshold)
    if threshold < 1 then threshold = 1 end
    if threshold > 100 then threshold = 100 end
    return threshold
end

local function shardGuardBlocked()
    local shards = countSoulShards()
    local threshold = shardGuardThreshold()
    if not SummonScoutDB.shardGuardEnabled or shards < 0 then
        return false, shards, threshold
    end
    return shards < threshold, shards, threshold
end

local function nativeSummonBridgeRequest(name)
    name = trim(name)
    if name == "" then return nil end

    SS.summonRequestSeq = (SS.summonRequestSeq or 0) + 1
    local seq = tostring(SS.summonRequestSeq)
    local destination = singleServiceLocation()

    W112_AUTOSUMMON_ACK = ""
    W112_AUTOSUMMON_ACK_SEQ = ""
    W112_AUTOSUMMON_STARTED_SEQ = ""
    W112_AUTOSUMMON_NATIVE_STATUS = "queued"
    W112_AUTOSUMMON_NATIVE_TARGET = ""
    W112_AUTOSUMMON_NATIVE_SLOT = ""
    W112_AUTOSUMMON_DESTINATION = destination and destination.id or ""
    W112_AUTOSUMMON_REQUEST_SEQ = seq
    W112_AUTOSUMMON_REQUEST = name

    SS.lastSummonRequestAt = now()
    SS.lastSummonRequestName = name
    SS.lastSummonError = ""
    return seq
end

local function nativeSummonStatus()
    return trim(tostring(W112_AUTOSUMMON_NATIVE_STATUS or "idle")),
        trim(tostring(W112_AUTOSUMMON_ACK_SEQ or "")),
        trim(tostring(W112_AUTOSUMMON_STARTED_SEQ or ""))
end

local function summonDestinationLabel()
    local single = singleServiceLocation()
    if single and single.label then return single.label end
    if GetZoneText then
        local zone = trim(GetZoneText() or "")
        if zone ~= "" then return zone end
    end
    return servedLocationLabel()
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
    SS.summonActiveQueuedAt = 0
    SS.summonActiveAttempts = 0
    SS.summonActiveRequestSeq = nil
    SS.summonActiveNextAt = 0
    SS.summonActiveExpires = 0
    SS.summonActiveStarted = false
    SS.summonActiveStartReported = false
    W112_AUTOSUMMON_REQUEST = ""
    W112_AUTOSUMMON_REQUEST_SEQ = ""
    W112_AUTOSUMMON_DESTINATION = ""
end

local function finishActiveSummon(name)
    name = trim(name or SS.summonActiveName or "")
    if name ~= "" then SS.summonPending[lower(name)] = nil end
    clearActiveSummon()
end

local function retryActiveSummon(delay)
    if not SS.summonActiveName then return end
    SS.summonActiveStarted = false
    SS.summonActiveRequestSeq = nil
    SS.summonActiveExpires = 0
    SS.summonActiveNextAt = now() + (delay or 0.50)
    W112_AUTOSUMMON_REQUEST = ""
    W112_AUTOSUMMON_REQUEST_SEQ = ""
    W112_AUTOSUMMON_DESTINATION = ""
end

local function markActiveSummonStarted(source)
    local name = trim(SS.summonActiveName or "")
    if name == "" or SS.summonActiveStarted then return end

    SS.summonActiveStarted = true
    SS.summonActiveExpires = now() + 8.0

    local startedSeq = trim(tostring(SS.summonActiveRequestSeq or ""))
    if startedSeq ~= "" then
        W112_AUTOSUMMON_STARTED_SEQ = startedSeq
        W112_AUTOSUMMON_NATIVE_STATUS = "cast-started:event"
    end

    if not SS.summonActiveStartReported then
        SS.summonActiveStartReported = true
        whisperSummonTarget(name)
        if SummonScoutDB.masterReportLifecycle then
            reportMaster("SUMMON START", name .. " -> " .. summonDestinationLabel())
        end
    end

    if SummonScoutDB.debug then
        chat("summon start confirmed -> " .. name .. " [" .. tostring(source or "unknown") .. "]")
    end
    guiRefreshSafe()
end

local function popReadyPendingSummon(t)
    local bestKey = nil
    local bestItem = nil
    local key, item

    for key, item in pairs(SS.summonPending) do
        local queuedAt = item.queuedAt or t
        if summonPlayerBlacklisted(item.name) then
            SS.summonPending[key] = nil
        elseif isInGroup(item.name) then
            if t >= (item.readyAt or 0) then
                if not bestItem or queuedAt < (bestItem.queuedAt or t) then
                    bestKey = key
                    bestItem = item
                end
            end
        elseif (t - queuedAt) > 25 then
            SS.summonPending[key] = nil
            if SummonScoutDB.masterReportLifecycle then
                reportMaster("SUMMON FAIL", item.name .. " - never became visible in party/raid")
            end
        end
    end

    if bestKey then SS.summonPending[bestKey] = nil end
    return bestItem
end

local function processPartySummon()
    if not SummonScoutDB.enabled or not SummonScoutDB.partyAutoSummon then return end
    local t = now()

    if not SS.summonActiveName then
        if UnitAffectingCombat and UnitAffectingCombat("player") then return end
        local item = popReadyPendingSummon(t)
        if not item then return end

        SS.summonActiveName = item.name
        SS.summonActiveQueuedAt = item.queuedAt or t
        SS.summonActiveAttempts = 0
        SS.summonActiveRequestSeq = nil
        SS.summonActiveNextAt = t
        SS.summonActiveExpires = 0
        SS.summonActiveStarted = false
        SS.summonActiveStartReported = false
    end

    local name = SS.summonActiveName
    if not isInGroup(name) then
        if (t - (SS.summonActiveQueuedAt or t)) < 5 then return end
        if SummonScoutDB.masterReportLifecycle then
            reportMaster("SUMMON FAIL", name .. " - left party/raid before cast")
        end
        finishActiveSummon(name)
        return
    end

    if (t - (SS.summonActiveQueuedAt or t)) > 30 then
        chat("summon watchdog dropped -> " .. name)
        if SummonScoutDB.masterReportLifecycle then
            reportMaster("SUMMON FAIL", name .. " - transaction watchdog timeout")
        end
        finishActiveSummon(name)
        return
    end

    local nativeStatus, ackSeq, startedSeq = nativeSummonStatus()
    local requestSeq = trim(tostring(SS.summonActiveRequestSeq or ""))

    if requestSeq ~= "" and startedSeq == requestSeq then
        markActiveSummonStarted("native")
    end

    if SS.summonActiveStarted then
        if t >= (SS.summonActiveExpires or 0) then
            if SummonScoutDB.debug then chat("summon completion watchdog -> " .. name) end
            if SummonScoutDB.masterReportLifecycle then
                reportMaster("SUMMON OK", name .. " -> " .. summonDestinationLabel())
            end
            finishActiveSummon(name)
        end
        return
    end

    if requestSeq ~= "" then
        if ackSeq == requestSeq
            and (nativeStatus == "target-failed"
                or nativeStatus == "no-spell"
                or nativeStatus == "no-cast-api-or-spell"
                or nativeStatus == "no-start"
                or nativeStatus == "blocked-busy"
                or nativeStatus == "coord-failed") then
            SS.lastSummonError = nativeStatus
            retryActiveSummon(nativeStatus == "blocked-busy" and 0.20 or 0.35)
            return
        end

        if t < (SS.summonActiveExpires or 0) then return end
        retryActiveSummon(0.20)
        return
    end

    if UnitAffectingCombat and UnitAffectingCombat("player") then return end
    if t < (SS.summonActiveNextAt or 0) then return end

    SS.summonActiveAttempts = (SS.summonActiveAttempts or 0) + 1
    if SS.summonActiveAttempts > 3 then
        local slot = findSpellBookSlot("Ritual of Summoning")
        local failReason = SS.lastSummonError
        if failReason == "" then failReason = nativeStatus ~= "" and nativeStatus or "no cast start after retries" end
        chat("summon failed after retries: " .. name
            .. " | unit=" .. tostring(groupUnitByName(name) or "-")
            .. " spellbook=" .. tostring(slot or "NONE")
            .. " shards=" .. tostring(countSoulShards())
            .. " nativeAck=" .. tostring(W112_AUTOSUMMON_ACK or "-")
            .. " nativeSeq=" .. tostring(W112_AUTOSUMMON_ACK_SEQ or "-")
            .. " nativeStatus=" .. tostring(nativeStatus or "-")
            .. " lastError=" .. failReason)
        if SummonScoutDB.masterReportLifecycle then
            reportMaster("SUMMON FAIL", name .. " -> " .. summonDestinationLabel() .. " - " .. failReason)
        end
        finishActiveSummon(name)
        return
    end

    local seq = nativeSummonBridgeRequest(name)
    if seq then
        SS.summonActiveRequestSeq = seq
        SS.summonActiveExpires = t + 2.20
        if SummonScoutDB.debug then
            chat("native summon request -> " .. name
                .. " seq " .. seq
                .. " attempt " .. tostring(SS.summonActiveAttempts))
        end
    else
        chat("cannot queue native Ritual request")
        if SummonScoutDB.masterReportLifecycle then
            reportMaster("SUMMON FAIL", name .. " - native bridge request failed")
        end
        finishActiveSummon(name)
    end
end

local function queueInvite(name, message, loc)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) then return end
    if invitePlayerBlacklisted(name) then
        if SummonScoutDB.debug then chat("invite blacklist skip -> " .. name) end
        return
    end
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
    if invitePlayerBlacklisted(name) then
        if SummonScoutDB.debug then chat("invite blacklist skip -> " .. name) end
        return false
    end
    if table.getn(SS.queue) ~= 0 then return false end
    if now() < SS.nextInviteAt then return false end
    if isInGroup(name) or recentlyHandled(name) or SS.queued[lower(name)] then return false end

    -- Fast path for the first eligible request after idle: invite directly from
    -- CHAT_MSG_CHANNEL instead of waiting for the next OnUpdate frame.
    local t = now()
    SS.recent[lower(name)] = t
    SS.nextInviteAt = t + (SummonScoutDB.inviteDelay or 0.8)
    InviteByName(name)
    notePendingManualInvite(name)
    recordInvite(name, loc)
    chat("invite -> " .. name .. " [" .. (loc and loc.label or "?") .. "]")
    return true
end


local function tryWhisperInvite(name, loc)
    name = trim(name)
    if name == "" or samePlayer(name, UnitName("player")) or isInGroup(name) then
        return false, "invalid"
    end
    if invitePlayerBlacklisted(name) then
        return false, "blacklisted"
    end

    local key = lower(name)
    local t = now()
    local last = SS.whisperInviteRecent[key]
    if last and (t - last) < 2 then
        return false, "duplicate-event"
    end

    -- Direct whisper demand is stronger than the long World-chat duplicate
    -- window. A customer who whispers again after an earlier World invite
    -- should still receive an immediate invite.
    SS.whisperInviteRecent[key] = t
    SS.recent[key] = t
    SS.nextInviteAt = t + (SummonScoutDB.inviteDelay or 0.8)
    InviteByName(name)
    notePendingManualInvite(name)
    recordInvite(name, loc)
    chat("whisper invite -> " .. name .. " [" .. (loc and loc.label or servedLocationLabel()) .. "]")
    return true, "invited"
end

local function counterDelay(sender, message)
    local minDelay = tonumber(SummonScoutDB.counterDelayMin) or 2
    local maxDelay = tonumber(SummonScoutDB.counterDelayMax) or 3
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

local function counterLocationAllowed(message, loc, ambiguous)
    local scope = SummonScoutDB.counterScope or "all"
    local service = SummonScoutDB.service or "all"
    local locations
    local j

    if scope == "all" then return true, loc end
    if service == "all" then return true, loc end

    locations = findLocationsInMessage(message)
    for j = 1, table.getn(locations) do
        if serviceContains(locations[j].id) then
            return true, locations[j]
        end
    end

    if ambiguous then return false, nil end
    return false, nil
end

local function clearCounterPending()
    SS.counterAt = 0
    SS.counterSender = nil
    SS.counterLocationLabel = nil
end

local function scheduleCounter(sender, message, loc, ambiguous)
    local allowed, matchedLoc
    if not SummonScoutDB.counterEnabled then return end
    if trim(SummonScoutDB.spamMessage or "") == "" then return end
    allowed, matchedLoc = counterLocationAllowed(message, loc, ambiguous)
    if not allowed then return end
    if SS.counterAt and SS.counterAt > 0 then return end

    local cooldown = tonumber(SummonScoutDB.counterCooldown) or 60
    local t = now()
    if cooldown < 15 then cooldown = 15 end
    if cooldown > 3600 then cooldown = 3600 end
    if (t - (SS.lastCounterAt or -100000)) < cooldown then return end

    -- Short anti-spam grace after our own advert: do not stack a competitive
    -- reply directly on top of a post we just sent. Fifteen seconds keeps the
    -- behavior polite without suppressing counters for a full minute.
    local lastOwnAdvert = tonumber(SummonScoutDB.lastAdvertWall) or 0
    local wall = wallTime()
    if lastOwnAdvert > 0 and wall >= lastOwnAdvert and (wall - lastOwnAdvert) < 15 then
        if SummonScoutDB.debug then chat("counter suppressed: own advert <15s") end
        return
    end

    local delay = counterDelay(sender, message)
    SS.counterAt = t + delay
    SS.counterSender = trim(sender)
    SS.counterLocationLabel = matchedLoc and matchedLoc.label or (loc and loc.label or "?")
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
    if invitePlayerBlacklisted(item.name) then
        if SummonScoutDB.debug then chat("queued invite blacklist skip -> " .. item.name) end
        return
    end
    if isInGroup(item.name) or recentlyHandled(item.name) then return end

    SS.recent[lower(item.name)] = now()
    SS.nextInviteAt = now() + (SummonScoutDB.inviteDelay or 0.8)
    InviteByName(item.name)
    notePendingManualInvite(item.name)
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
    if type(SummonScoutDB.inviteBlacklist) ~= "table" then SummonScoutDB.inviteBlacklist = {} end
    if SummonScoutDB.service == nil then SummonScoutDB.service = "all" end
    local canonicalService = resolveServiceSpec(SummonScoutDB.service)
    if canonicalService then SummonScoutDB.service = canonicalService else SummonScoutDB.service = "all" end
    if SummonScoutDB.spamEnabled == nil then SummonScoutDB.spamEnabled = false end
    if SummonScoutDB.spamInterval == nil then SummonScoutDB.spamInterval = 120 end
    if SummonScoutDB.spamMessage == nil then SummonScoutDB.spamMessage = "" end
    if SummonScoutDB.counterEnabled == nil then SummonScoutDB.counterEnabled = false end
    if SummonScoutDB.counterDelayMin == nil then SummonScoutDB.counterDelayMin = 2 end
    if SummonScoutDB.counterDelayMax == nil then SummonScoutDB.counterDelayMax = 3 end
    if SummonScoutDB.counterDelayProfileVersion == nil then
        -- Migrate the previous stock 4-8s defaults once. Other custom values
        -- remain untouched.
        if SummonScoutDB.counterDelayMin == 4 and SummonScoutDB.counterDelayMax == 8 then
            SummonScoutDB.counterDelayMin = 2
            SummonScoutDB.counterDelayMax = 3
        end
        SummonScoutDB.counterDelayProfileVersion = 2
    end
    if SummonScoutDB.counterCooldown == nil then SummonScoutDB.counterCooldown = 60 end
    if SummonScoutDB.counterScope == nil then SummonScoutDB.counterScope = "all" end
    if SummonScoutDB.masterReportingEnabled == nil then SummonScoutDB.masterReportingEnabled = false end
    if SummonScoutDB.masterName == nil then SummonScoutDB.masterName = "" end
    if SummonScoutDB.masterReportInvites == nil then SummonScoutDB.masterReportInvites = true end
    if SummonScoutDB.masterReportPayments == nil then SummonScoutDB.masterReportPayments = true end
    if SummonScoutDB.masterReportLifecycle == nil then SummonScoutDB.masterReportLifecycle = true end
    if SummonScoutDB.whisperAutoInvite == nil then SummonScoutDB.whisperAutoInvite = true end
    if SummonScoutDB.summonWhisperCooldown == nil then SummonScoutDB.summonWhisperCooldown = 10 end
    if SummonScoutDB.partyAutoSummon == nil then SummonScoutDB.partyAutoSummon = false end
    if SummonScoutDB.summonWhisperEnabled == nil then SummonScoutDB.summonWhisperEnabled = true end
    if SummonScoutDB.paymentChatEnabled == nil then SummonScoutDB.paymentChatEnabled = true end
    if SummonScoutDB.paymentLedgerVersion == nil or SummonScoutDB.paymentLedgerVersion < 2 then
        -- Older builds could record the full wallet/incorrect trade amount.
        -- Preserve that history separately, but start the trusted ledger clean.
        SummonScoutDB.legacyPaymentLog = SummonScoutDB.paymentLog or {}
        SummonScoutDB.legacyRevenueCopper = SummonScoutDB.revenueCopper or 0
        SummonScoutDB.legacyPaymentCount = SummonScoutDB.paymentCount or 0
        SummonScoutDB.paymentLog = {}
        SummonScoutDB.revenueCopper = 0
        SummonScoutDB.paymentCount = 0
        SummonScoutDB.paymentLedgerVersion = 2
    end
    if SummonScoutDB.shardGuardEnabled == nil then SummonScoutDB.shardGuardEnabled = false end
    if SummonScoutDB.shardGuardMin == nil then SummonScoutDB.shardGuardMin = 5 end
    SummonScoutDB.shardGuardMin = shardGuardThreshold()
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
        .. "/" .. tostring(SummonScoutDB.counterDelayMin or 2)
        .. "-" .. tostring(SummonScoutDB.counterDelayMax or 3)
        .. "s cd=" .. tostring(SummonScoutDB.counterCooldown or 60) .. "s"
        .. " scope=" .. tostring(SummonScoutDB.counterScope or "all")
        .. ", master=" .. (SummonScoutDB.masterReportingEnabled and (trim(SummonScoutDB.masterName or "") ~= "" and SummonScoutDB.masterName or "NO-NAME") or "OFF")
        .. "/events=" .. (SummonScoutDB.masterReportLifecycle and "ON" or "OFF")
        .. ", whisperInvite=" .. (SummonScoutDB.whisperAutoInvite and "ON" or "OFF")
        .. ", partySummon=" .. (SummonScoutDB.partyAutoSummon and "ON" or "OFF")
        .. ", summonWhisper=" .. (SummonScoutDB.summonWhisperEnabled and "ON" or "OFF")
        .. ", revenue=" .. formatMoney(SummonScoutDB.revenueCopper or 0)
        .. ", shardGuard=" .. (SummonScoutDB.shardGuardEnabled and ("ON<" .. tostring(shardGuardThreshold())) or "OFF")
        .. "/shards=" .. tostring(countSoulShards())
        .. (SS.shardGuardPaused and "[PAUSED]" or "")
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
    SS.pendingTrade = nil
    chat("trusted payment ledger cleared")
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
    local _, pendingItem = oldestPendingSummon()
    local pending = pendingItem and pendingItem.name or "-"
    local target = trim(UnitName("target") or "")
    local probeName = SS.summonActiveName or (pending ~= "-" and pending or target)
    local targetUnit = probeName ~= "" and groupUnitByName(probeName) or nil
    local shards = countSoulShards()
    chat("summoncheck v" .. ADDON_VERSION
        .. " spellbook=" .. tostring(slot or "NONE")
        .. " byName=" .. (CastSpellByName and "YES" or "NO")
        .. " CastSpell=" .. (CastSpell and "YES" or "NO")
        .. " shards=" .. tostring(shards))
    chat("summoncheck pending=" .. pending
        .. " depth=" .. tostring(pendingSummonCount())
        .. " active=" .. tostring(SS.summonActiveName or "-")
        .. " groupUnit=" .. tostring(targetUnit or "-")
        .. " target=" .. (target ~= "" and target or "-")
        .. " combat=" .. ((UnitAffectingCombat and UnitAffectingCombat("player")) and "YES" or "NO")
        .. " lastError=" .. (SS.lastSummonError ~= "" and SS.lastSummonError or "-"))
    local pendingInvites = 0
    local _k
    for _k in pairs(SS.pendingManualInvites) do pendingInvites = pendingInvites + 1 end
    chat("summoncheck bridge request=" .. tostring(W112_AUTOSUMMON_REQUEST or "-")
        .. " requestSeq=" .. tostring(W112_AUTOSUMMON_REQUEST_SEQ or "-")
        .. " ack=" .. tostring(W112_AUTOSUMMON_ACK or "-")
        .. " ackSeq=" .. tostring(W112_AUTOSUMMON_ACK_SEQ or "-")
        .. " startedSeq=" .. tostring(W112_AUTOSUMMON_STARTED_SEQ or "-")
        .. " nativeCount=" .. tostring(W112_AUTOSUMMON_NATIVE_COUNT or 0)
        .. " nativeStatus=" .. tostring(W112_AUTOSUMMON_NATIVE_STATUS or "-")
        .. " nativeTarget=" .. tostring(W112_AUTOSUMMON_NATIVE_TARGET or "-")
        .. " nativeSlot=" .. tostring(W112_AUTOSUMMON_NATIVE_SLOT or "-")
        .. " manualPending=" .. tostring(pendingInvites))
end

local function describeTest(message)
    local request = looksLikeSummonRequest(message)
    local loc, ambiguous = findLocation(message)
    if isRecruitmentWithOwnSummon(message) then
        chat("test: NOT A SUMMON REQUEST [recruitment + own summon]")
        return
    end
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
    local loc, ambiguous = findLocation(message)
    local locations = findLocationsInMessage(message)
    local seller = isSellerMessage(message)
    local allowed, matchedLoc = false, nil
    if seller then
        allowed, matchedLoc = counterLocationAllowed(message, loc, ambiguous)
        chat("countertest: OFFER, locations="
            .. (ambiguous and "AMBIGUOUS DM" or locationListLabel(locations))
            .. ", matched=" .. (matchedLoc and matchedLoc.label or "-")
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
    local id, label = resolveServiceSpec(value)
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

local function guiSaveShardGuardMin()
    local value = tonumber(trim(GUI.shardGuardMinEdit and GUI.shardGuardMinEdit:GetText() or ""))
    if not value or value < 1 or value > 100 then
        chat("Soul Shard threshold must be 1-100")
        if GUI.shardGuardMinEdit then
            GUI.shardGuardMinEdit:SetText(tostring(shardGuardThreshold()))
        end
        return
    end
    SummonScoutDB.shardGuardMin = math.floor(value)
    chat("low-shard pause threshold -> " .. tostring(SummonScoutDB.shardGuardMin))
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

local function guiBlacklistAdd()
    local value = trim(GUI.blacklistEdit and GUI.blacklistEdit:GetText() or "")
    local ok, detail = addInviteBlacklist(value)
    if ok then
        chat("blacklist ADD -> " .. detail)
        if GUI.blacklistEdit then GUI.blacklistEdit:SetText("") end
    else
        chat("blacklist add failed: enter a player name")
    end
    if guiRefresh then guiRefresh() end
end

local function guiBlacklistRemove()
    local value = trim(GUI.blacklistEdit and GUI.blacklistEdit:GetText() or "")
    local ok, detail = removeInviteBlacklist(value)
    if ok then
        chat("blacklist REMOVE -> " .. detail)
        if GUI.blacklistEdit then GUI.blacklistEdit:SetText("") end
    else
        chat("blacklist remove: name not found")
    end
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
                SS.summonPending = {}
                clearActiveSummon()
                SS.pendingManualInvites = {}
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
    GUI.shardGuardCheck = guiCheck(f, 26, -302, "Low-shard global pause",
        function() return SummonScoutDB.shardGuardEnabled end,
        function(v) SummonScoutDB.shardGuardEnabled = v end)
    guiText(f, "Below:", 190, -306, true)
    GUI.shardGuardMinEdit = guiEdit(f, 232, -301, 38, tostring(shardGuardThreshold()))
    GUI.shardGuardMinEdit:SetMaxLetters(3)
    guiButton(f, 274, -301, 36, "Set", guiSaveShardGuardMin)

    guiHeader(f, "Service / advert", 28, -334)
    guiText(f, "Serve:", 28, -358, true)
    GUI.serviceEdit = guiEdit(f, 80, -351, 155, SummonScoutDB.service or "all")
    guiButton(f, 244, -351, 66, "Apply", guiApplyService)

    guiText(f, "World text:", 28, -390, true)
    GUI.advertEdit = guiEdit(f, 100, -383, 210, SummonScoutDB.spamMessage or "")
    guiButton(f, 244, -414, 66, "Save", guiSaveAdvert)

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
    GUI.masterLifecycleCheck = guiCheck(f, 368, -146, "Report joins / summon state",
        function() return SummonScoutDB.masterReportLifecycle end,
        function(v) SummonScoutDB.masterReportLifecycle = v end)
    GUI.paymentChatCheck = guiCheck(f, 368, -172, "Show received gold in chat",
        function() return SummonScoutDB.paymentChatEnabled end,
        function(v) SummonScoutDB.paymentChatEnabled = v end)

    guiText(f, "Master:", 370, -210, true)
    GUI.masterEdit = guiEdit(f, 430, -203, 170, SummonScoutDB.masterName or "")
    guiButton(f, 608, -203, 70, "Save", guiSaveMaster)
    guiButton(f, 608, -232, 70, "Test", function()
        if not reportMaster("TEST", "reporting online from " .. (UnitName("player") or "?")) then
            chat("master reporting is OFF or master name is empty")
        end
    end)

    guiHeader(f, "Live operation", 370, -278)
    GUI.lastInviteText = guiText(f, "Last invite: -", 370, -302, true)
    GUI.lastPaymentText = guiText(f, "Last payment: -", 370, -326, true)
    GUI.revenueText = guiText(f, "Received total (trusted): 0c", 370, -350, true)
    GUI.currentGoldText = guiText(f, "Current gold: 0c", 370, -374, true)
    GUI.counterText = guiText(f, "Counter: -", 370, -398, true)
    GUI.summonStateText = guiText(f, "Summon: idle", 370, -422, true)
    GUI.shardGuardText = guiText(f, "Shard guard: OFF", 370, -446, true)
    guiButton(f, 586, -342, 92, "Reset total", function() clearPayments() end)
    GUI.stateText = guiText(f, "State: -", 28, -450, true)
    guiText(f, "Invite blacklist:", 28, -478, true)
    GUI.blacklistEdit = guiEdit(f, 112, -471, 110, "")
    GUI.blacklistEdit:SetMaxLetters(32)
    guiButton(f, 230, -471, 42, "Add", guiBlacklistAdd)
    guiButton(f, 278, -471, 58, "Remove", guiBlacklistRemove)
    GUI.blacklistText = guiText(f, "Blacklist: empty", 28, -502, true)
    GUI.helpText = guiText(f, "/ssi gui | /ssi blacklist add|del|list <name>. Settings persist.", 28, -532, true)

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
        GUI.counterCheck, GUI.spamCheck, GUI.scopeCheck, GUI.shardGuardCheck, GUI.masterEnabledCheck,
        GUI.masterInviteCheck, GUI.masterPaymentCheck, GUI.masterLifecycleCheck, GUI.paymentChatCheck
    }
    local i
    for i = 1, table.getn(checks) do
        local c = checks[i]
        if c and c.ssGetter then c:SetChecked(c.ssGetter() and 1 or nil) end
    end

    if GUI.summonWhisperCdEdit and not GUI.summonWhisperCdEdit.ssFocused then
        GUI.summonWhisperCdEdit:SetText(tostring(SummonScoutDB.summonWhisperCooldown or 10))
    end
    if GUI.shardGuardMinEdit and not GUI.shardGuardMinEdit.ssFocused then
        GUI.shardGuardMinEdit:SetText(tostring(shardGuardThreshold()))
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
        GUI.revenueText:SetText("Received total (trusted): " .. formatMoney(SummonScoutDB.revenueCopper or 0)
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
        local _, pendingItem = oldestPendingSummon()
        local pendingName = SS.summonActiveName
            or (pendingItem and pendingItem.name)
            or "-"
        GUI.summonStateText:SetText("Summon: " .. pendingName
            .. " | " .. tostring(W112_AUTOSUMMON_NATIVE_STATUS or "idle")
            .. (SS.lastSummonError ~= "" and (" | " .. SS.lastSummonError) or ""))
    end
    if GUI.blacklistText then
        GUI.blacklistText:SetText("Blacklist: " .. inviteBlacklistSummary())
    end
    if GUI.shardGuardText then
        local blocked, shards, threshold = shardGuardBlocked()
        local guardState = SummonScoutDB.shardGuardEnabled and (blocked and "PAUSED" or "READY") or "OFF"
        GUI.shardGuardText:SetText("Shard guard: " .. guardState
            .. " | shards " .. tostring(shards)
            .. " | min " .. tostring(threshold))
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
    elseif cmd == "blacklist" then
        local _, _, sub, name = string.find(trim(rest), "^(%S+)%s*(.-)$")
        sub = lower(sub or "")
        name = trim(name or "")
        if sub == "add" and name ~= "" then
            local ok, detail = addInviteBlacklist(name)
            chat(ok and ("blacklist ADD -> " .. detail) or "blacklist add failed")
        elseif (sub == "del" or sub == "remove") and name ~= "" then
            local ok, detail = removeInviteBlacklist(name)
            chat(ok and ("blacklist REMOVE -> " .. detail) or "blacklist remove: name not found")
        elseif sub == "list" or sub == "" then
            chat("blacklist: " .. inviteBlacklistSummary())
        else
            chat("use /ssi blacklist add <name> | del <name> | list")
        end
        guiRefreshSafe()
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
    elseif cmd == "masterevents" then
        rest = lower(trim(rest))
        if rest == "on" then SummonScoutDB.masterReportLifecycle = true end
        if rest == "off" then SummonScoutDB.masterReportLifecycle = false end
        status()
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
            SS.summonPending = {}
            clearActiveSummon()
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
    elseif cmd == "shardguard" then
        rest = lower(trim(rest))
        if rest == "on" then
            SummonScoutDB.shardGuardEnabled = true
            chat("low-shard global pause -> ON")
        elseif rest == "off" then
            SummonScoutDB.shardGuardEnabled = false
            chat("low-shard global pause -> OFF")
        else
            chat("use /ssi shardguard on|off")
        end
        status()
        guiRefreshSafe()
    elseif cmd == "shardmin" then
        local value = tonumber(trim(rest))
        if not value or value < 1 or value > 100 then
            chat("Soul Shard threshold must be 1-100")
        else
            SummonScoutDB.shardGuardMin = math.floor(value)
            chat("low-shard pause threshold -> " .. tostring(SummonScoutDB.shardGuardMin))
            status()
            guiRefreshSafe()
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
        local id, label = resolveServiceSpec(rest)
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
        chat("/ssi countertest <message> | blacklist add <name> | blacklist del <name> | blacklist list | gui")
        chat("/ssi master <name>|on|off | masterevents on|off | reporttest")
        chat("/ssi whisperinvite on|off | partysummon on|off | summonwhisper on|off | summonwhispercd <1-120>")
        chat("/ssi shardguard on|off | shardmin <1-100> | paymentchat on|off")
        chat("/ssi clearpayments confirm | summoncheck | version")
        chat("/ssi serve <place[,place]|all> | places | channel <name> | debug on/off | test <message> | clearstats confirm")
    end
end

local function clearOperationalStateForShardGuard()
    SS.queue = {}
    SS.queued = {}
    SS.nextInviteAt = 0
    SS.summonPending = {}
    SS.pendingManualInvites = {}
    clearActiveSummon()
    clearCounterPending()
    SS.nextSpamAt = 0
    SS.pendingTrade = nil
    SS.tradeRequestedBy = nil
    SS.tradePartner = nil
    SS.tradeMoneyBefore = 0
    SS.tradeTargetMoney = 0
    SS.tradeBothAccepted = false
    SS.tradeActive = false
    SS.partySyncAt = 0
end

local function refreshShardGuardState(silent)
    local blocked, shards, threshold = shardGuardBlocked()
    SS.shardGuardLastCount = shards

    if blocked ~= SS.shardGuardPaused then
        SS.shardGuardPaused = blocked
        if blocked then
            clearOperationalStateForShardGuard()
            if not silent then
                chat("ALL automation paused: Soul Shards " .. tostring(shards)
                    .. " < " .. tostring(threshold))
            end
        else
            syncPartyRoster(true)
            if SummonScoutDB.spamEnabled then
                SS.nextSpamAt = now() + (SummonScoutDB.spamInterval or 120)
            end
            if not silent then
                chat("automation resumed: Soul Shards " .. tostring(shards)
                    .. " >= " .. tostring(threshold))
            end
        end
        guiRefreshSafe()
    end

    return blocked
end

local function handleChannelMessage(message, sender, channelBaseName, channelFullName)
    if not SummonScoutDB.enabled then return end

    message = message or ""
    sender = sender or ""
    channelBaseName = channelBaseName or ""
    channelFullName = channelFullName or ""

    if not channelMatches(channelBaseName, channelFullName) then
        return
    end

    -- Never react to this character's own advertisement/request.
    if samePlayer(sender, UnitName("player")) then return end

    local loc, ambiguous = findLocation(message)

    -- Recruitment posts such as "LF Mage for farm ... Can summon" advertise
    -- the sender's own group activity, not a summon request. Ignore them
    -- before seller/counter logic so they do not pollute demand statistics.
    if isRecruitmentWithOwnSummon(message) then
        if SummonScoutDB.debug then
            chat("ignore: " .. sender .. " [recruitment + own summon]")
        end
        return
    end

    -- Seller detection is independent from buyer detection. Competitor ads
    -- never enter demand statistics or the invite queue.
    if isSellerMessage(message) then
        scheduleCounter(sender, message, loc, ambiguous)
        return
    end

    if invitePlayerBlacklisted(sender) then
        if SummonScoutDB.debug then chat("ignore blacklisted requester -> " .. sender) end
        return
    end

    if not looksLikeSummonRequest(message) then return end

    local inviteCandidate = SummonScoutDB.autoInvite and locationAllowed(loc, ambiguous)

    -- Lowest-latency path: the first eligible request after idle is invited
    -- synchronously from the channel event. Later/cooldown requests are queued.
    if inviteCandidate then
        if not tryImmediateInvite(sender, loc) then
            queueInvite(sender, message, loc)
        end
    end

    -- Keep demand accounting after the latency-critical invite path.
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

local frame = CreateFrame("Frame", "SummonScoutFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("TRADE_REQUEST")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_MONEY_CHANGED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("SPELLCAST_START")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        setDefaults()
        W112_AUTOSUMMON_REQUEST = ""
        W112_AUTOSUMMON_REQUEST_SEQ = ""
        W112_AUTOSUMMON_ACK = ""
        W112_AUTOSUMMON_ACK_SEQ = ""
        W112_AUTOSUMMON_STARTED_SEQ = ""
        W112_AUTOSUMMON_NATIVE_COUNT = W112_AUTOSUMMON_NATIVE_COUNT or 0
        W112_AUTOSUMMON_NATIVE_STATUS = "idle"
        W112_AUTOSUMMON_NATIVE_TARGET = ""
        W112_AUTOSUMMON_NATIVE_SLOT = ""
        syncPartyRoster(true)
        SS.nextRosterPollAt = now() + 0.75
        refreshShardGuardState(true)
        chat("v" .. ADDON_VERSION .. " loaded; watching #" .. (SummonScoutDB.channel or "world")
            .. "; serving=" .. servedLocationLabel()
            .. "; logged=" .. tostring(SummonScoutDB.stats.total or 0))
        return
    end

    if refreshShardGuardState(false) then
        return
    end

    if event == "BAG_UPDATE" then
        return
    end

    if event == "UI_ERROR_MESSAGE" or event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" then
        if SS.summonActiveName and (now() - (SS.lastSummonRequestAt or -100000)) < 6 then
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

    if event == "CHAT_MSG_SYSTEM" then
        local line = trim(arg1 or "")

        -- Manual /invite and right-click invites do not pass through SSI's own
        -- InviteByName path. Track the client's confirmation and reconcile it
        -- against the real roster until that player actually joins.
        local _, _, invitedName = string.find(line, "^You have invited (.+) to join your group%.?$")
        invitedName = trim(invitedName or "")
        if invitedName ~= "" then
            notePendingManualInvite(invitedName)
            SS.partySyncAt = now() + 0.20
            return
        end

        local _, _, joinedName = string.find(line, "^(.+) has joined the raid group%.?$")
        if not joinedName then
            _, _, joinedName = string.find(line, "^(.+) has joined the party%.?$")
        end
        if not joinedName then
            _, _, joinedName = string.find(line, "^(.+) joins the party%.?$")
        end
        joinedName = trim(joinedName or "")
        if joinedName ~= "" and not samePlayer(joinedName, UnitName("player")) then
            if SummonScoutDB.partyAutoSummon then
                queuePartySummon(joinedName)
            end
            SS.pendingManualInvites[lower(joinedName)] = nil
            SS.partySyncAt = now() + 0.20
        end
        return
    end

    if event == "CHAT_MSG_WHISPER" then
        if not SummonScoutDB.enabled or not SummonScoutDB.whisperAutoInvite then return end
        local message = arg1 or ""
        local sender = trim(arg2 or "")
        if sender == "" or samePlayer(sender, UnitName("player")) or isInGroup(sender) then return end
        local accept, loc, reason = whisperInviteDecision(message)
        if accept then
            local invited, why = tryWhisperInvite(sender, loc)
            if not invited and SummonScoutDB.debug then
                chat("whisper invite suppressed -> " .. sender .. " [" .. tostring(why) .. "]")
            end
        elseif SummonScoutDB.debug then
            chat("whisper ignore -> " .. sender .. " [" .. tostring(reason) .. "]")
        end
        return
    end

    if event == "SPELLCAST_START" then
        local spell = normalizeMessage(arg1 or "")
        if SS.summonActiveName and spell == "ritual of summoning" then
            markActiveSummonStarted("event")
        end
        return
    end

    if event == "SPELLCAST_STOP" then
        if SS.summonActiveName and SS.summonActiveStarted then
            local completedName = SS.summonActiveName
            if SummonScoutDB.debug then
                chat("summon cast completed -> " .. completedName)
            end
            if SummonScoutDB.masterReportLifecycle then
                reportMaster("SUMMON OK", completedName .. " -> " .. summonDestinationLabel())
            end
            finishActiveSummon(completedName)
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
        handleChannelMessage(arg1, arg2, arg9, arg4)
        return
    end
end)
frame:SetScript("OnUpdate", function()
    local t = now()
    if t >= (SS.shardGuardNextCheckAt or 0) then
        SS.shardGuardNextCheckAt = t + 0.50
        refreshShardGuardState(false)
    end
    if SS.shardGuardPaused then
        if SS.gui and SS.gui:IsShown() and guiRefresh and t >= (SS.nextGuiRefreshAt or 0) then
            SS.nextGuiRefreshAt = t + 0.5
            guiRefresh()
        end
        return
    end
    if SS.partySyncAt and SS.partySyncAt > 0 and t >= SS.partySyncAt then
        SS.partySyncAt = 0
        syncPartyRoster(false)
        SS.nextRosterPollAt = t + 0.75
    elseif t >= (SS.nextRosterPollAt or 0) then
        -- Fallback for private-server/client cases where a roster event is
        -- delayed or missed. Existing members remain known, so this only
        -- queues genuinely new names.
        syncPartyRoster(false)
        SS.nextRosterPollAt = t + 0.75
    end
    processPendingTrade()
    processPendingManualInvites()
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
