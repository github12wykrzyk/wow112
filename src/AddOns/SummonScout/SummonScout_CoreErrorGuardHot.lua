-- SummonScout hot core-event error containment for WoW 1.12.1 / Lua 5.0.
-- Loaded last so it contains errors rethrown by earlier SummonScoutFrame wrappers
-- without flooding the Blizzard error popup. The original error text remains
-- visible in H.lastError / persistent hot state for diagnosis.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-core-error-guard1"
local G = H.GetState("coreerrorguard")
G.lastError = G.lastError or ""
G.lastErrorAt = tonumber(G.lastErrorAt) or 0
G.lastShownError = G.lastShownError or ""
G.lastShownAt = tonumber(G.lastShownAt) or 0

local OWN_WRAPPER = nil
local OWN_BASE = nil
local REPORT_COOLDOWN = 60

local function cgNow()
    if GetTime then return GetTime() end
    return 0
end

local function cgChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666SummonScout core error suppressed:|r " .. tostring(text or ""))
    end
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
        if not pcall then
            OWN_BASE()
            return
        end

        local ok, err = pcall(OWN_BASE)
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
