-- SummonScout manual whisper session guard for WoW 1.12.1 / Lua 5.0.
--
-- Contract:
--   * once the operator manually whispers a player, SummonScout must not send
--     any further automatic whisper to that player for the rest of the login
--     session;
--   * queued/pending automation for that player is cancelled through the
--     canonical ManualChatLock path;
--   * automatic SummonScout whispers are identified by their Lua caller, not
--     by message text, so a manually typed sentence that happens to resemble an
--     automatic template still establishes manual ownership;
--   * the SendChatMessage wrapper is hot-reload safe and restores only itself.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "3-session-manual-whisper-guard"
local S = H.GetState("manualwhispersessionguard")
S.locked = S.locked or {}
S.autoOutgoing = S.autoOutgoing or {}
S.blockLogAt = S.blockLogAt or {}

local BASE_IS_LOCKED = H.IsManualChatLocked
local BASE_LOCK = H.ManualChatLock
local BASE_OBSERVE = H.ManualChatObserveOutgoing
local OWN_SEND = nil
local OWN_SEND_BASE = nil

local function now()
    if GetTime then return GetTime() end
    return 0
end

local function trim(v)
    v = tostring(v or "")
    v = string.gsub(v, "^%s+", "")
    v = string.gsub(v, "%s+$", "")
    return v
end

local function key(name)
    return string.lower(trim(name))
end

local function samePlayer(name)
    local me = UnitName and UnitName("player") or ""
    local a = key(name)
    return a ~= "" and a == key(me)
end

local function chat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. tostring(text or ""))
    end
end

local function sessionLocked(name)
    local k = key(name)
    if k == "" then return false end
    if S.locked[k] then return true end
    if type(BASE_IS_LOCKED) == "function" then
        return BASE_IS_LOCKED(name) and true or false
    end
    return false
end

local function lockSession(name, quiet)
    local k = key(name)
    if k == "" or samePlayer(name) then return false end

    local first = not S.locked[k]
    S.locked[k] = true

    -- Reuse the canonical v2 lock for cancellation of pending probes / queued
    -- whisper confirmation state. Its 5 minute timestamp becomes irrelevant
    -- because this module owns the session-long decision above it.
    if type(BASE_LOCK) == "function" then
        BASE_LOCK(name, true)
    end

    if first and not quiet then
        chat("manual whisper conversation -> ALL auto whispers muted for " .. trim(name) .. " until relog")
    end
    return true
end

local function callerIsSummonScout()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return false
    end

    local i
    for i = 2, 9 do
        local ok, info
        if pcall then
            ok, info = pcall(debug.getinfo, i, "S")
            if not ok then info = nil end
        else
            info = debug.getinfo(i, "S")
        end
        if not info then break end

        local src = string.lower(tostring(info.source or info.short_src or ""))
        if string.find(src, "summonscout", 1, true) then
            return true
        end
    end
    return false
end

local function rememberAutomatic(target, message)
    local k = key(target)
    if k == "" then return end
    S.autoOutgoing[k] = {
        message = tostring(message or ""),
        at = now(),
    }
end

local function consumeAutomatic(target, message)
    local k = key(target)
    local item = S.autoOutgoing[k]
    if not item then return false end

    -- CHAT_MSG_WHISPER_INFORM should follow immediately. Keep a small window in
    -- case another addon delays presentation of the event.
    if (now() - (tonumber(item.at) or 0)) > 3 then
        S.autoOutgoing[k] = nil
        return false
    end
    if tostring(item.message or "") ~= tostring(message or "") then
        return false
    end

    S.autoOutgoing[k] = nil
    return true
end

local function observeOutgoing(message, target)
    target = trim(target)
    if target == "" or samePlayer(target) then return end

    if consumeAutomatic(target, message) then
        return
    end

    -- Anything not tagged by a SummonScout caller is operator-owned. This is
    -- intentionally independent from the text content of the whisper.
    lockSession(target, false)
end

local function detachOwnSendWrapper()
    if OWN_SEND and OWN_SEND_BASE and SendChatMessage == OWN_SEND then
        SendChatMessage = OWN_SEND_BASE
    end
    if S.wrapper == OWN_SEND then
        S.wrapper = nil
        S.wrapperBase = nil
    end
    OWN_SEND = nil
    OWN_SEND_BASE = nil
end

local function installSendWrapper()
    -- Peel only the previous generation installed by this module. Never unwrap
    -- an unrelated addon wrapper.
    if type(S.wrapper) == "function" and type(S.wrapperBase) == "function"
        and SendChatMessage == S.wrapper then
        SendChatMessage = S.wrapperBase
    end

    if type(SendChatMessage) ~= "function" then return false end

    OWN_SEND_BASE = SendChatMessage
    OWN_SEND = function(message, chatType, language, target)
        local whisper = string.upper(tostring(chatType or "")) == "WHISPER"
        local automatic = whisper and callerIsSummonScout()

        if automatic then
            if sessionLocked(target) then
                local k = key(target)
                local t = now()
                local last = tonumber(S.blockLogAt[k]) or -100000
                if SummonScoutDB and SummonScoutDB.debug and (t - last) >= 10 then
                    S.blockLogAt[k] = t
                    chat("manual ownership guard blocked auto whisper -> " .. trim(target))
                end
                return nil
            end
            rememberAutomatic(target, message)
        end

        return OWN_SEND_BASE(message, chatType, language, target)
    end

    SendChatMessage = OWN_SEND
    S.wrapper = OWN_SEND
    S.wrapperBase = OWN_SEND_BASE
    return true
end

local function installApi()
    -- Re-read the canonical bases only when another module legitimately
    -- replaced them; never point the base back at our own wrappers.
    if H.IsManualChatLocked ~= sessionLocked then
        BASE_IS_LOCKED = H.IsManualChatLocked
    end
    if H.ManualChatLock ~= lockSession then
        BASE_LOCK = H.ManualChatLock
    end
    if H.ManualChatObserveOutgoing ~= observeOutgoing then
        BASE_OBSERVE = H.ManualChatObserveOutgoing
    end

    H.IsManualChatLocked = sessionLocked
    H.ManualChatLock = lockSession
    H.ManualChatObserveOutgoing = observeOutgoing
    H.ManualChatLockSeconds = nil
    H.ManualChatLockScope = "session"
end

local M = {}

function M.Init()
    installApi()
    installSendWrapper()
    H.RegisterEvent("PLAYER_LOGIN")
    W112_SUMMONSCOUT_MANUAL_CHAT_LOCK_VERSION = VERSION
end

function M.Shutdown()
    detachOwnSendWrapper()
    if H.IsManualChatLocked == sessionLocked then H.IsManualChatLocked = BASE_IS_LOCKED end
    if H.ManualChatLock == lockSession then H.ManualChatLock = BASE_LOCK end
    if H.ManualChatObserveOutgoing == observeOutgoing then H.ManualChatObserveOutgoing = BASE_OBSERVE end
end

function M.OnEvent(ev)
    if ev == "PLAYER_LOGIN" then
        S.locked = {}
        S.autoOutgoing = {}
        S.blockLogAt = {}
        installApi()
        installSendWrapper()
    end
end

function M.OnUpdate()
    -- Expire stale automatic-outgoing markers so an unrelated later manual
    -- whisper with identical text can never inherit an old automation tag.
    local t = now()
    local k, item
    for k, item in pairs(S.autoOutgoing) do
        if (t - (tonumber(item.at) or 0)) > 3 then
            S.autoOutgoing[k] = nil
        end
    end
end

H.Register("manualwhispersessionguard", M, VERSION)
