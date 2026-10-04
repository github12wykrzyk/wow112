-- SummonScout hot-swappable advert/counter timing module.
-- Packaged into an already watched hot payload by tools/summonscout_hot_transform.py.
-- WoW 1.12.1 / Lua 5.0 compatible.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

-- Keep this marker stable because the hot packager validates it fail-closed.
local TIMING_VERSION = "1-random-spam-counter1"
local PEER_GUARD_VERSION = 1
local SPAM_MIN_SECONDS = 200
local SPAM_MAX_SECONDS = 500
local COUNTER_PROFILE_VERSION = 3
local COUNTER_DEFAULT_SECONDS = 1
local PEER_GUARD_MIN_SECONDS = 45
local PEER_GUARD_SPREAD_SECONDS = 75
local PEER_GUARD_QUIET_RESET_SECONDS = 90
local PEER_GUARD_MAX_CHAIN_SECONDS = 240

local T = H.GetState("timing")
T.sequence = tonumber(T.sequence) or 0
T.currentDelay = tonumber(T.currentDelay) or 0
T.lastAdvertWall = tonumber(T.lastAdvertWall) or 0
T.armed = T.armed and true or false
T.nextCheckAt = tonumber(T.nextCheckAt) or 0
T.peerGuardChainStart = tonumber(T.peerGuardChainStart) or 0
T.lastPeerAdvertAt = tonumber(T.lastPeerAdvertAt) or -100000
T.lastPeerSender = tostring(T.lastPeerSender or "")

local function tNow()
    if GetTime then return GetTime() end
    return 0
end

local function tWall()
    if time then return tonumber(time()) or 0 end
    return math.floor(tNow())
end

local function tPlayerSalt()
    local name = ""
    if UnitName then name = string.lower(UnitName("player") or "") end
    local h = 0
    local i
    for i = 1, string.len(name) do
        h = math.mod((h * 131) + string.byte(name, i) + i, 1000003)
    end
    return h
end

local function tNextSpamDelay()
    T.sequence = (tonumber(T.sequence) or 0) + 1
    local span = SPAM_MAX_SECONDS - SPAM_MIN_SECONDS + 1
    local seed = (tWall() * 37)
        + (math.floor(tNow() * 10) * 17)
        + (tPlayerSalt() * 97)
        + (T.sequence * 7919)
    return SPAM_MIN_SECONDS + math.mod(seed, span)
end

local function tChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. tostring(text or ""))
    end
end

local function tApplyCounterDefaults()
    SummonScoutDB = SummonScoutDB or {}

    local profile = tonumber(SummonScoutDB.counterDelayProfileVersion) or 0
    local minDelay = tonumber(SummonScoutDB.counterDelayMin)
    local maxDelay = tonumber(SummonScoutDB.counterDelayMax)

    if profile < COUNTER_PROFILE_VERSION then
        local stockOld = (minDelay == 2 and maxDelay == 3)
            or (minDelay == 4 and maxDelay == 8)
            or minDelay == nil or maxDelay == nil
        if stockOld then
            SummonScoutDB.counterDelayMin = COUNTER_DEFAULT_SECONDS
            SummonScoutDB.counterDelayMax = COUNTER_DEFAULT_SECONDS
        end
        SummonScoutDB.counterDelayProfileVersion = COUNTER_PROFILE_VERSION
    end
end

local function tResetPeerGuard()
    T.peerGuardChainStart = 0
    T.lastPeerAdvertAt = -100000
    T.lastPeerSender = ""
end

local function tLooksLikeSummonAdvert(message)
    local s = string.lower(tostring(message or ""))
    if not string.find(s, "summon", 1, true) then return false end
    return string.find(s, "wts", 1, true) ~= nil
        or string.find(s, "selling", 1, true) ~= nil
end

local function tSamePlayer(a, b)
    a = string.lower(tostring(a or ""))
    b = string.lower(tostring(b or ""))
    return a ~= "" and b ~= "" and a == b
end

local function tApplyPeerAdvertGuard(message, sender)
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.spamEnabled then
        return
    end
    if not tLooksLikeSummonAdvert(message) then return end

    local me = ""
    if UnitName then me = UnitName("player") or "" end
    if tSamePlayer(sender, me) then return end

    local state = W112_SUMMONSCOUT_STATE
    if type(state) ~= "table" then return end

    local nowAt = tNow()
    local lastPeer = tonumber(T.lastPeerAdvertAt) or -100000
    if (tonumber(T.peerGuardChainStart) or 0) <= 0
        or (nowAt - lastPeer) > PEER_GUARD_QUIET_RESET_SECONDS then
        T.peerGuardChainStart = nowAt
    end
    T.lastPeerAdvertAt = nowAt
    T.lastPeerSender = tostring(sender or "")

    -- Do not let a very busy seller channel suppress our periodic advert forever.
    if (nowAt - (tonumber(T.peerGuardChainStart) or nowAt)) > PEER_GUARD_MAX_CHAIN_SECONDS then
        return
    end

    -- Everybody hears the same World advert, but each character gets a stable
    -- different backoff. A later peer advert can push us again, which breaks a
    -- burst into a spaced sequence instead of merely moving the whole burst.
    local bucket = math.floor(nowAt / 15)
    local spread = math.mod(tPlayerSalt() + (bucket * 17), PEER_GUARD_SPREAD_SECONDS + 1)
    local guardUntil = nowAt + PEER_GUARD_MIN_SECONDS + spread
    local current = tonumber(state.nextSpamAt) or 0
    if current < guardUntil then
        state.nextSpamAt = guardUntil
        if SummonScoutDB.debug then
            tChat("peer advert guard -> wait " .. tostring(math.floor(guardUntil - nowAt))
                .. "s after " .. tostring(sender or "seller"))
        end
    end
end

local function tArmRandomSpam(reason, quiet)
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.spamEnabled then
        T.armed = false
        return false
    end

    local state = W112_SUMMONSCOUT_STATE
    if type(state) ~= "table" then
        return false
    end

    local delay = tNextSpamDelay()
    SummonScoutDB.spamInterval = delay
    state.nextSpamAt = tNow() + delay
    T.currentDelay = delay
    T.lastAdvertWall = tonumber(SummonScoutDB.lastAdvertWall) or 0
    T.armed = true

    if reason == "advert" then
        tResetPeerGuard()
    end

    if not quiet and SummonScoutDB.debug then
        tChat("next World advert in " .. tostring(delay) .. "s [" .. tostring(reason or "random") .. "]")
    end
    return true
end

local function tMaintainRandomSpam()
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.spamEnabled then
        T.armed = false
        return
    end

    local wall = tonumber(SummonScoutDB.lastAdvertWall) or 0
    if not T.armed then
        tArmRandomSpam("enabled", true)
        return
    end

    if wall > 0 and wall ~= (tonumber(T.lastAdvertWall) or 0) then
        T.lastAdvertWall = wall
        tArmRandomSpam("advert", true)
        return
    end

    -- The legacy first-advert helper can still briefly write a fixed interval.
    -- Reassert the per-client random delay without touching global math.random state.
    if tonumber(SummonScoutDB.spamInterval) ~= tonumber(T.currentDelay) then
        tArmRandomSpam("resync", true)
    end
end

local M = {}

function M.Init()
    tApplyCounterDefaults()
    local changed = T.moduleVersion ~= TIMING_VERSION
    T.moduleVersion = TIMING_VERSION
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_CHANNEL")

    if changed then
        T.armed = false
        T.lastAdvertWall = tonumber(SummonScoutDB and SummonScoutDB.lastAdvertWall) or 0
        tArmRandomSpam("hotload", true)
    end

    W112_SUMMONSCOUT_TIMING_VERSION = TIMING_VERSION
    W112_SUMMONSCOUT_PEER_GUARD_VERSION = PEER_GUARD_VERSION
end

function M.OnEvent(ev, a1, a2)
    if ev == "CHAT_MSG_CHANNEL" then
        tApplyPeerAdvertGuard(a1, a2)
        return
    end
    if ev ~= "PLAYER_LOGIN" then return end
    T.sequence = 0
    T.currentDelay = 0
    T.lastAdvertWall = tonumber(SummonScoutDB and SummonScoutDB.lastAdvertWall) or 0
    T.armed = false
    T.nextCheckAt = 0
    tResetPeerGuard()
    tApplyCounterDefaults()
end

function M.OnUpdate()
    local nowAt = tNow()
    if nowAt < (T.nextCheckAt or 0) then return end
    T.nextCheckAt = nowAt + 0.25
    tApplyCounterDefaults()
    tMaintainRandomSpam()
end

H.Register("timing", M, TIMING_VERSION)
if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout PING]|r random advert 200-500s + peer gap 45-120s + counter 1s loaded")
end