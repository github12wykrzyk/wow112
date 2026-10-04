-- FAST HOTFIX: prevent WhisperConfirmSpam from re-attaching its core alias hook
-- during PLAYER_LOGIN. On cold load the alias is already installed by M.Init().
-- Re-attaching after CoreErrorGuard has wrapped SummonScoutFrame creates a
-- W1 -> Guard -> W1 recursion cycle because the legacy module wrapper shares
-- the mutable OWN_CORE_BASE upvalue, eventually surfacing as "C stack overflow".
-- WoW 1.12.1 / Lua 5.0 compatible.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.GetState) ~= "function" or type(H.modules) ~= "table" then
    return
end

local M = H.modules["whisperconfirm"]
if type(M) ~= "table" or type(M.OnEvent) ~= "function" then
    return
end
if M.__stackFixPlayerLogin then
    return
end

local ORIGINAL_ON_EVENT = M.OnEvent
local VERSION = "2-player-login-no-reattach-standard-sync"

M.OnEvent = function(ev, a1, a2)
    if ev == "PLAYER_LOGIN" then
        local WC = H.GetState("whisperconfirm")
        WC.pending = {}
        WC.candidates = {}
        WC.confirmations = {}
        WC.inviteIssuedAt = {}
        WC.startupSpamScheduled = false
        WC.startupSpamDelay = 0
        WC.nextGuiRefreshAt = 0

        -- M.Init() has already attached the alias hook. Do NOT attach it again
        -- here after CoreErrorGuard is installed.
        W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION = W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION or VERSION
        W112_SUMMONSCOUT_COREHOT_VERSION = W112_SUMMONSCOUT_COREHOT_VERSION or VERSION
        return
    end

    return ORIGINAL_ON_EVENT(ev, a1, a2)
end

M.__stackFixPlayerLogin = true
W112_SUMMONSCOUT_WHISPER_STACK_FIX_VERSION = VERSION

if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout]|r WhisperConfirm stack-overflow hotfix active")
end
