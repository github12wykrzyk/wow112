-- SummonScout hot core-event error containment for WoW 1.12.1 / Lua 5.0.
-- Loaded last so it contains errors rethrown by earlier SummonScoutFrame wrappers
-- without flooding the Blizzard error popup. The first residual runtime failure
-- is captured with a one-shot xpcall/debug.traceback diagnostic and persisted in
-- hot state + SummonScoutDB; later failures use the lighter pcall path.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "3-core-error-guard-chat-throttle-filter"
local G = H.GetState("coreerrorguard")
G.lastError = G.lastError or ""
G.lastErrorAt = tonumber(G.lastErrorAt) or 0
G.lastShownError = G.lastShownError or ""
G.lastShownAt = tonumber(G.lastShownAt) or 0
G.traceCaptured = G.traceCaptured and true or false
G.traceback = G.traceback or ""
G.traceCapturedAt = tonumber(G.traceCapturedAt) or 0

local OWN_WRAPPER = nil
local OWN_BASE = nil
local REPORT_COOLDOWN = 60

local function cgNow()
    if GetTime then return GetTime() end
    return 0
end

local function cgWallTime()
    if time then return time() end
    return 0
end

local function cgChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666SummonScout core error suppressed:|r " .. tostring(text or ""))
    end
end

local function cgIsChatThrottle(ev, message)
    if ev ~= "UI_ERROR_MESSAGE" and ev ~= "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" then
        return false
    end
    local s = string.lower(tostring(message or ""))
    if s == "" then return false end
    return string.find(s, "must wait", 1, true) ~= nil
        or string.find(s, "before speaking again", 1, true) ~= nil
end

local function cgCaptureTrace(err)
    local message = tostring(err or "unknown SummonScout core event error")
    if G.traceCaptured then return message end

    G.traceCaptured = true
    G.traceCapturedAt = cgNow()

    local trace = message
    if debug and type(debug.traceback) == "function" then
        if pcall then
            local ok, value = pcall(debug.traceback, message)
            if ok and type(value) == "string" and value ~= "" then
                trace = value
            else
                trace = message .. "\n[traceback unavailable: " .. tostring(value or "unknown") .. "]"
            end
        else
            trace = debug.traceback(message)
        end
    end

    G.traceback = tostring(trace or message)
    H.lastTraceback = G.traceback
    W112_SUMMONSCOUT_LAST_TRACEBACK = G.traceback

    if SummonScoutDB then
        SummonScoutDB.coreErrorTraceback = G.traceback
        SummonScoutDB.coreErrorTracebackAt = cgWallTime()
        SummonScoutDB.coreErrorTracebackVersion = VERSION
    end

    return message
end

local function cgDetachPrevious()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then return end
    if G.wrapper and G.base and frame:GetScript("OnEvent") == G.wrapper then
        frame:SetScript("OnEvent", G.base)
    end
end

local function cgInstall()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then return false end

    cgDetachPrevious()

    local current = frame:GetScript("OnEvent")
    if type(current) ~= "function" then return false end

    OWN_BASE = current
    OWN_WRAPPER = function()
        if cgIsChatThrottle(event, arg1) then return end

        if not pcall then
            OWN_BASE()
            return
        end

        local ok, err
        if not G.traceCaptured and xpcall and debug and type(debug.traceback) == "function" then
            ok, err = xpcall(OWN_BASE, cgCaptureTrace)
        else
            ok, err = pcall(OWN_BASE)
        end
        if ok then return end

        local message = tostring(err or "unknown SummonScout core event error")
        local t = cgNow()
        G.lastError = message
        G.lastErrorAt = t
        H.lastError = "SummonScout core event: " .. message

        if G.lastShownError ~= message or (t - (G.lastShownAt or 0)) >= REPORT_COOLDOWN then
            G.lastShownError = message
            G.lastShownAt = t
            cgChat(message)
        end
    end

    frame:SetScript("OnEvent", OWN_WRAPPER)
    G.base = OWN_BASE
    G.wrapper = OWN_WRAPPER
    G.version = VERSION
    return true
end

local M = {}

function M.Init()
    cgInstall()
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

H.Register("coreerrorguard", M, VERSION)
W112_SUMMONSCOUT_CORE_ERROR_GUARD_VERSION = VERSION
