-- SummonScout hot-swappable advert/counter timing module.
-- Packaged into an already watched hot payload by tools/summonscout_hot_transform.py.
-- WoW 1.12.1 / Lua 5.0 compatible.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

-- Keep this marker stable because the hot packager validates it fail-closed.
local TIMING_VERSION = "1-random-spam-counter1"
local ADVERT_PROFILE_VERSION = 2
local SPAM_MIN_SECONDS = 100
local SPAM_MAX_SECONDS = 180
local COUNTER_PROFILE_VERSION = 3
local COUNTER_DEFAULT_SECONDS = 1

local T = H.GetState("timing")
T.sequence = tonumber(T.sequence) or 0
T.currentDelay = tonumber(T.currentDelay) or 0
T.lastAdvertWall = tonumber(T.lastAdvertWall) or 0
T.armed = T.armed and true or false
T.nextCheckAt = tonumber(T.nextCheckAt) or 0
T.advertProfileVersion = tonumber(T.advertProfileVersion) or 0

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
    -- Reassert this client's random delay without touching global math.random state.
    if tonumber(SummonScoutDB.spamInterval) ~= tonumber(T.currentDelay) then
        tArmRandomSpam("resync", true)
    end
end

local M = {}

function M.Init()
    tApplyCounterDefaults()
    local changed = T.moduleVersion ~= TIMING_VERSION
        or (tonumber(T.advertProfileVersion) or 0) < ADVERT_PROFILE_VERSION
    T.moduleVersion = TIMING_VERSION
    T.advertProfileVersion = ADVERT_PROFILE_VERSION
    H.RegisterEvent("PLAYER_LOGIN")

    if changed then
        T.armed = false
        T.lastAdvertWall = tonumber(SummonScoutDB and SummonScoutDB.lastAdvertWall) or 0
        tArmRandomSpam("hotload", true)
    end

    W112_SUMMONSCOUT_TIMING_VERSION = TIMING_VERSION
    W112_SUMMONSCOUT_ADVERT_PROFILE_VERSION = ADVERT_PROFILE_VERSION
    W112_SUMMONSCOUT_PEER_GUARD_VERSION = 0
end

function M.OnEvent(ev)
    if ev ~= "PLAYER_LOGIN" then return end
    T.sequence = 0
    T.currentDelay = 0
    T.lastAdvertWall = tonumber(SummonScoutDB and SummonScoutDB.lastAdvertWall) or 0
    T.armed = false
    T.nextCheckAt = 0
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
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout PING]|r independent random advert 100-180s + counter 1s loaded")
end
