-- SummonScout shard-guard observation hotfix for WoW 1.12.1 / Lua 5.0.
--
-- Core currently returns from SummonScoutFrame OnEvent before CHAT_MSG_CHANNEL
-- whenever the shard guard is paused. That makes a low-shard summoner blind:
-- clear buyer requests never reach the parser or request ledger.
--
-- This wrapper keeps World observation/logging alive while the guard is paused,
-- but explicitly disables outbound World mutations for the duration of that
-- event (auto-invite and competition counter). Summon/counter/spam execution
-- remains paused by the canonical shard guard.

local H = W112_SUMMONSCOUT_HOT
local API = W112_SUMMONSCOUT_API_V1
local SS = W112_SUMMONSCOUT_STATE
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function"
    or not API or type(API.handleChannelMessage) ~= "function"
    or type(API.refreshShardGuardState) ~= "function"
    or not SS then
    return
end

local VERSION = "1-shardguard-world-observe"
local G = H.GetState("shardguardobservation")
G.seenWhilePaused = tonumber(G.seenWhilePaused) or 0
G.lastSender = G.lastSender or ""
G.lastMessage = G.lastMessage or ""
G.lastSeenAt = tonumber(G.lastSeenAt) or 0

local OWN_BASE = nil
local OWN_WRAPPER = nil

local function sgNow()
    if GetTime then return GetTime() end
    return 0
end

local function sgDetachPrevious()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then return end
    if G.wrapper and G.base and frame:GetScript("OnEvent") == G.wrapper then
        frame:SetScript("OnEvent", G.base)
    end
end

local function sgObservePausedWorld()
    local db = SummonScoutDB
    if not db then return end

    local oldAutoInvite = db.autoInvite
    local oldCounterEnabled = db.counterEnabled
    local ok, err = true, nil

    -- Observation must stay read-only while the shard guard is paused.
    db.autoInvite = false
    db.counterEnabled = false

    if pcall then
        ok, err = pcall(API.handleChannelMessage, arg1, arg2, arg9, arg4)
    else
        API.handleChannelMessage(arg1, arg2, arg9, arg4)
    end

    db.autoInvite = oldAutoInvite
    db.counterEnabled = oldCounterEnabled

    G.seenWhilePaused = (tonumber(G.seenWhilePaused) or 0) + 1
    G.lastSender = tostring(arg2 or "")
    G.lastMessage = tostring(arg1 or "")
    G.lastSeenAt = sgNow()

    if not ok then
        error(err or "paused World observation failed")
    end
end

local function sgInstall()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then return false end

    sgDetachPrevious()

    local current = frame:GetScript("OnEvent")
    if type(current) ~= "function" then return false end

    OWN_BASE = current
    OWN_WRAPPER = function()
        if event == "CHAT_MSG_CHANNEL" then
            -- Refresh first so a just-crossed shard threshold is observed on
            -- this exact chat event rather than up to 0.5s later in OnUpdate.
            local blocked = API.refreshShardGuardState(false)
            if blocked then
                sgObservePausedWorld()
                return
            end
        end
        OWN_BASE()
    end

    frame:SetScript("OnEvent", OWN_WRAPPER)
    G.base = OWN_BASE
    G.wrapper = OWN_WRAPPER
    G.version = VERSION
    return true
end

local M = {}

function M.Init()
    sgInstall()
end

function M.Shutdown()
    local frame = SummonScoutFrame
    if frame and frame.GetScript and frame.SetScript
        and OWN_WRAPPER and OWN_BASE
        and frame:GetScript("OnEvent") == OWN_WRAPPER then
        frame:SetScript("OnEvent", OWN_BASE)
    end
    if G.wrapper == OWN_WRAPPER then
        G.wrapper = nil
        G.base = nil
    end
end

H.Register("shardguardobservation", M, VERSION)
W112_SUMMONSCOUT_SHARD_GUARD_OBSERVATION_VERSION = VERSION
