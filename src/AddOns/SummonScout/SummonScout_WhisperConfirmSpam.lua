-- SummonScout hot-swappable whisper confirmation + advert timing + service-alias module.
-- WoW 1.12.1 / Lua 5.0 compatible. Runtime state is owned by SummonScout_HotHost.
-- No private event frame and no permanent InviteByName wrapper are created here.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local WC_VERSION = "2-hot2-manualchat-safe1"
local WC_PENDING_SECONDS = 60
local WC_PROBE_COOLDOWN = 120
local WC_STARTUP_SPAM_MIN = 300
local WC_STARTUP_SPAM_MAX = 400
local WC_CANDIDATE_DELAY = 0.65
local LEGACY_VERSION = W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION
local BIND_TOKEN = {}

local WC = H.GetState("whisperconfirm")
WC.pending = WC.pending or {}
WC.candidates = WC.candidates or {}
WC.confirmations = WC.confirmations or {}
WC.probedAt = WC.probedAt or {}
WC.inviteIssuedAt = WC.inviteIssuedAt or {}
WC.startupSpamScheduled = WC.startupSpamScheduled and true or false
WC.startupSpamDelay = tonumber(WC.startupSpamDelay) or 0
WC.nextGuiRefreshAt = tonumber(WC.nextGuiRefreshAt) or 0

local OWN_CORE_WRAPPER = nil
local OWN_CORE_BASE = nil

local POSITIVE = {
    ["yes"] = true, ["yea"] = true, ["yeah"] = true, ["y"] = true,
    ["ye"] = true, ["yep"] = true, ["yup"] = true,
    ["ok"] = true, ["okay"] = true, ["sure"] = true,
    ["please"] = true, ["pls"] = true, ["plz"] = true,
    ["go"] = true, ["go ahead"] = true,
    ["yes please"] = true, ["yes pls"] = true, ["yes plz"] = true,
    ["yeah please"] = true, ["yeah pls"] = true, ["yeah plz"] = true,
    ["yea please"] = true, ["yea pls"] = true,
    ["sure please"] = true, ["sure pls"] = true,
    ["summon me"] = true, ["invite me"] = true, ["inv"] = true,
    ["123"] = true
}

local NEGATIVE = {
    ["no"] = true, ["n"] = true, ["nope"] = true, ["nah"] = true,
    ["no thanks"] = true, ["no thank you"] = true, ["no thx"] = true,
    ["cancel"] = true, ["stop"] = true
}

local CHATTER = {
    ["ty"] = true, ["tyvm"] = true, ["thanks"] = true, ["thank you"] = true,
    ["thx"] = true, ["cheers"] = true, ["np"] = true, ["nice"] = true,
    ["great"] = true, ["awesome"] = true, ["gg"] = true, ["lol"] = true,
    ["paid"] = true, ["sent"] = true, ["omw"] = true, ["on my way"] = true
}

local HARD_BLACKLIST = {
    ["hydraone"] = true,
    ["hydratwo"] = true,
    ["bolthyjal"] = true
}

local SERVICE_LABELS = {
    hyjal = "Mount Hyjal",
    hydraxian = "Hydraxian Waterlords",
    winterspring = "Winterspring",
    everlook = "Everlook",
    azshara = "Azshara"
}

local function wcNow()
    if GetTime then return GetTime() end
    return 0
end

local function wcTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function wcLower(s)
    return string.lower(s or "")
end

local function wcNormalize(s)
    s = wcLower(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return wcTrim(s)
end

local function wcPhraseHas(s, phrase)
    local p = wcNormalize(phrase)
    if p == "" then return false end
    return string.find(" " .. s .. " ", " " .. p .. " ", 1, true) ~= nil
end

local function wcChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. tostring(text or ""))
    end
end

local function wcKey(name)
    return wcLower(wcTrim(name or ""))
end

local function wcSamePlayer(a, b)
    return wcKey(a) ~= "" and wcKey(a) == wcKey(b)
end

local function wcInGroup(name)
    local i
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if wcSamePlayer(UnitName("party" .. i), name) then return true end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(i)
            if wcSamePlayer(raidName, name) then return true end
        end
    end
    return false
end

local function wcInviteBlacklisted(name)
    local key = wcKey(name)
    if key == "" or HARD_BLACKLIST[key] then return true end
    local list = SummonScoutDB and SummonScoutDB.inviteBlacklist
    return type(list) == "table" and list[key] ~= nil
end

local function wcCountSoulShards()
    local count = 0
    local bag
    if not GetContainerNumSlots or not GetContainerItemLink then return 999 end
    for bag = 0, 4 do
        local slot
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            if link and string.find(link, "item:6265:", 1, true) then
                local _, stack = GetContainerItemInfo(bag, slot)
                count = count + (tonumber(stack) or 1)
            end
        end
    end
    return count
end

local function wcShardBlocked()
    if not SummonScoutDB or not SummonScoutDB.shardGuardEnabled then return false end
    local threshold = math.floor(tonumber(SummonScoutDB.shardGuardMin) or 5)
    if threshold < 1 then threshold = 1 end
    return wcCountSoulShards() < threshold
end

local function wcServiceLabel()
    if not SummonScoutDB then return nil end
    local raw = wcLower(wcTrim(SummonScoutDB.service or ""))
    if raw == "" or raw == "all" then return nil end

    local labels = {}
    local startAt = 1
    while true do
        local commaAt = string.find(raw, ",", startAt, true)
        local part
        if commaAt then
            part = wcTrim(string.sub(raw, startAt, commaAt - 1))
        else
            part = wcTrim(string.sub(raw, startAt))
        end
        if part ~= "" then
            labels[table.getn(labels) + 1] = SERVICE_LABELS[part]
                or (string.upper(string.sub(part, 1, 1)) .. string.sub(part, 2))
        end
        if not commaAt then break end
        startAt = commaAt + 1
    end

    if table.getn(labels) == 0 then return nil end
    return table.concat(labels, " + ")
end

local function wcEligible(name)
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.whisperAutoInvite then
        return false
    end
    if wcTrim(name) == "" or wcSamePlayer(name, UnitName("player")) then return false end
    if wcInGroup(name) or wcInviteBlacklisted(name) or wcShardBlocked() then return false end
    return wcServiceLabel() ~= nil
end

local function wcAnswer(message)
    local raw = wcLower(wcTrim(message or ""))
    local normalized = wcNormalize(message)
    if raw == "+" or raw == "+1" or raw == "++" then return "yes" end
    if raw == "-" then return "no" end
    if POSITIVE[normalized] then return "yes" end
    if NEGATIVE[normalized] then return "no" end
    return nil
end

local function wcIsChatter(message)
    local s = wcNormalize(message)
    if s == "" or CHATTER[s] then return true end
    if string.sub(s, 1, 4) == "w112" then return true end
    if string.find(s, "summon ok", 1, true)
        or string.find(s, "summon start", 1, true)
        or string.find(s, "summon fail", 1, true)
        or string.find(s, "coord ", 1, true) then
        return true
    end
    return false
end

local function wcLooksLikeSeller(message)
    local s = wcNormalize(message)
    if string.find(s, "wts", 1, true)
        or string.find(s, "selling", 1, true)
        or string.find(s, "summon service", 1, true)
        or string.find(s, "summons available", 1, true)
        or string.find(s, "offering summon", 1, true) then
        return true
    end
    return false
end

local function wcServiceHas(service, id)
    local s = "," .. wcLower(wcTrim(service or "")) .. ","
    return string.find(s, "," .. id .. ",", 1, true) ~= nil
end

local function wcExtendedServiceForMessage(message)
    if not SummonScoutDB then return nil end

    local service = wcLower(wcTrim(SummonScoutDB.service or "all"))
    if service == "" or service == "all" then return nil end

    local servesWinterspring = wcServiceHas(service, "winterspring")
    local servesEverlook = wcServiceHas(service, "everlook")
    if not servesWinterspring and not servesEverlook then return nil end

    local s = wcNormalize(message or "")
    local mentionsWinterspring = wcPhraseHas(s, "winterspring")
    local mentionsEverlook = wcPhraseHas(s, "everlook")

    if mentionsEverlook and servesWinterspring and not servesEverlook then
        return SummonScoutDB.service .. ",everlook", "Everlook=>Winterspring"
    end
    if mentionsWinterspring and servesEverlook and not servesWinterspring then
        return SummonScoutDB.service .. ",winterspring", "Winterspring=>Everlook"
    end
    return nil
end

local function wcDebugGetUpvalue(fn, index)
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil, nil end
    if pcall then
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if ok then return name, value end
        return nil, nil
    end
    return debug.getupvalue(fn, index)
end

local function wcTryRestoreLegacyInviteWrapper()
    if type(InviteByName) ~= "function" then return false end
    local i
    for i = 1, 16 do
        local name, value = wcDebugGetUpvalue(InviteByName, i)
        if not name then break end
        if type(value) == "table" and type(value.originalInviteByName) == "function"
            and value.inviteWrapped then
            InviteByName = value.originalInviteByName
            WC.legacyInviteUnwrapped = true
            return true
        end
    end
    return false
end

local function wcTryRecoverLegacyCoreHandler(current)
    if type(current) ~= "function" then return nil end
    local i
    for i = 1, 16 do
        local name, value = wcDebugGetUpvalue(current, i)
        if not name then break end
        if name == "originalOnEvent" and type(value) == "function" then
            return value
        end
    end
    return nil
end

local function wcDisableLegacyFrame()
    local legacy = getglobal and getglobal("SummonScoutWhisperConfirmSpamFrame") or nil
    if not legacy then return end
    if legacy.UnregisterAllEvents then
        legacy:UnregisterAllEvents()
    else
        if legacy.UnregisterEvent then
            legacy:UnregisterEvent("PLAYER_LOGIN")
            legacy:UnregisterEvent("CHAT_MSG_WHISPER")
        end
    end
    if legacy.SetScript then
        legacy:SetScript("OnEvent", nil)
        legacy:SetScript("OnUpdate", nil)
    end
    if legacy.Hide then legacy:Hide() end
    WC.legacyFrameDisabled = true
end

local function wcDetachPreviousManagedCoreHook()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then return end
    if WC.coreWrapper and WC.coreOriginalOnEvent and frame:GetScript("OnEvent") == WC.coreWrapper then
        frame:SetScript("OnEvent", WC.coreOriginalOnEvent)
    end
end

local function wcAttachCoreAliasHook()
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript or not frame.SetScript then return false end

    wcDetachPreviousManagedCoreHook()

    local current = frame:GetScript("OnEvent")
    local recovered = wcTryRecoverLegacyCoreHandler(current)
    if recovered then
        current = recovered
        frame:SetScript("OnEvent", current)
        WC.legacyAliasUnwrapped = true
    end
    if type(current) ~= "function" then return false end

    OWN_CORE_BASE = current
    OWN_CORE_WRAPPER = function()
        local restoreService = nil
        local bridgeReason = nil

        if event == "CHAT_MSG_WHISPER" and H.IsManualChatLocked and H.IsManualChatLocked(arg2 or "") then
            if H.ManualChatLock then H.ManualChatLock(arg2 or "", true) end
            return
        end

        if event == "CHAT_MSG_CHANNEL" or event == "CHAT_MSG_WHISPER" then
            local extended, reason = wcExtendedServiceForMessage(arg1 or "")
            if extended then
                restoreService = SummonScoutDB.service
                SummonScoutDB.service = extended
                bridgeReason = reason
            end
        end

        local ok, err = true, nil
        if pcall then
            ok, err = pcall(OWN_CORE_BASE)
        else
            OWN_CORE_BASE()
        end

        if restoreService ~= nil then
            SummonScoutDB.service = restoreService
            if SummonScoutDB.debug then
                wcChat("Winterspring/Everlook alias: " .. tostring(bridgeReason or "matched"))
            end
        end

        if not ok then error(err) end
    end

    frame:SetScript("OnEvent", OWN_CORE_WRAPPER)
    WC.coreOriginalOnEvent = current
    WC.coreWrapper = OWN_CORE_WRAPPER
    return true
end

local function wcShutdownCoreAliasHook()
    local frame = SummonScoutFrame
    if frame and frame.GetScript and frame.SetScript
        and OWN_CORE_WRAPPER and OWN_CORE_BASE
        and frame:GetScript("OnEvent") == OWN_CORE_WRAPPER then
        frame:SetScript("OnEvent", OWN_CORE_BASE)
    end
    if WC.coreWrapper == OWN_CORE_WRAPPER then
        WC.coreWrapper = nil
        WC.coreOriginalOnEvent = nil
    end
end

local function wcSendProbe(sender)
    local label = wcServiceLabel()
    if not label or not SendChatMessage then return false end
    SendChatMessage("Do you need " .. label .. " summon?", "WHISPER", nil, sender)
    return true
end

local function wcQueueUnknownProbe(sender, message)
    if not wcEligible(sender) or wcIsChatter(message) or wcLooksLikeSeller(message) then return end
    local key = wcKey(sender)
    local t = wcNow()
    local lastProbe = WC.probedAt[key]
    if WC.pending[key] or WC.candidates[key] then return end
    if lastProbe and (t - lastProbe) < WC_PROBE_COOLDOWN then return end

    WC.candidates[key] = {
        sender = wcTrim(sender),
        seenAt = t,
        dueAt = t + WC_CANDIDATE_DELAY
    }
end

local function wcHandlePendingReply(sender, message)
    local key = wcKey(sender)
    local pending = WC.pending[key]
    if not pending then return false end

    local t = wcNow()
    if t > (pending.expiresAt or 0) then
        WC.pending[key] = nil
        return false
    end

    local answer = wcAnswer(message)
    if answer == "no" then
        WC.pending[key] = nil
        if SummonScoutDB.debug then wcChat("confirm NO -> " .. sender) end
        return true
    end
    if answer ~= "yes" then
        return true
    end

    WC.pending[key] = nil
    WC.confirmations[key] = {
        sender = wcTrim(sender),
        seenAt = t,
        dueAt = t + 0.15
    }
    return true
end

local function wcProcessCandidates()
    local t = wcNow()
    local key, item
    for key, item in pairs(WC.candidates) do
        if t >= (item.dueAt or 0) then
            WC.candidates[key] = nil
            local invitedAt = WC.inviteIssuedAt[key]
            local alreadyInvited = invitedAt and invitedAt >= ((item.seenAt or t) - 0.05)
            if not alreadyInvited and not wcInGroup(item.sender) and wcEligible(item.sender) then
                if wcSendProbe(item.sender) then
                    WC.probedAt[key] = t
                    WC.pending[key] = { expiresAt = t + WC_PENDING_SECONDS }
                    if SummonScoutDB.debug then
                        wcChat("unknown whisper -> asked " .. item.sender .. " about " .. tostring(wcServiceLabel()))
                    end
                end
            end
        end
    end
end

local function wcProcessConfirmations()
    local t = wcNow()
    local key, item
    for key, item in pairs(WC.confirmations) do
        if t >= (item.dueAt or 0) then
            WC.confirmations[key] = nil
            local invitedAt = WC.inviteIssuedAt[key]
            local coreAlreadyInvited = invitedAt and invitedAt >= ((item.seenAt or t) - 0.05)
            if not coreAlreadyInvited and wcEligible(item.sender) and InviteByName then
                WC.inviteIssuedAt[key] = t
                InviteByName(item.sender)
                if SummonScoutDB.debug then
                    wcChat("confirm YES -> invite " .. item.sender .. " [" .. tostring(wcServiceLabel()) .. "]")
                end
            end
        end
    end
end

local function wcExpirePending()
    local t = wcNow()
    local key, item
    for key, item in pairs(WC.pending) do
        if t > (item.expiresAt or 0) then WC.pending[key] = nil end
    end
end

local function wcNoteSystemInvite(line)
    line = wcTrim(line or "")
    local _, _, invitedName = string.find(line, "^You have invited (.+) to join your group%.?$")
    invitedName = wcTrim(invitedName or "")
    if invitedName ~= "" then
        WC.inviteIssuedAt[wcKey(invitedName)] = wcNow()
    end
end

local function wcClampSpamInterval(value)
    local seconds = math.floor(tonumber(value) or 120)
    if seconds < 30 then seconds = 30 end
    if seconds > 3600 then seconds = 3600 end
    return seconds
end

local function wcCoreSetSpamInterval(seconds)
    seconds = wcClampSpamInterval(seconds)
    local slash = SlashCmdList and SlashCmdList["SUMMONSCOUT"]
    if slash then
        slash("spamsec " .. tostring(seconds))
        return true
    end
    if SummonScoutDB then SummonScoutDB.spamInterval = seconds end
    return false
end

local function wcScheduleStartupSpam()
    if WC.startupSpamScheduled or not SummonScoutDB or not SummonScoutDB.spamEnabled then return end

    local recurring = wcClampSpamInterval(SummonScoutDB.spamInterval)
    SummonScoutDB.spamInterval = recurring
    local delay = math.random(WC_STARTUP_SPAM_MIN, WC_STARTUP_SPAM_MAX)

    if wcCoreSetSpamInterval(delay) then
        SummonScoutDB.spamInterval = recurring
        WC.startupSpamDelay = delay
        WC.startupSpamScheduled = true
        wcChat("first World advert in " .. tostring(delay) .. "s; recurring every " .. tostring(recurring) .. "s")
    end
end

local function wcSaveInterval()
    if not WC.intervalEdit then return end
    local seconds = tonumber(wcTrim(WC.intervalEdit:GetText() or ""))
    if not seconds or seconds < 30 or seconds > 3600 then
        wcChat("spam interval must be 30-3600 seconds")
        WC.intervalEdit:SetText(tostring(wcClampSpamInterval(SummonScoutDB and SummonScoutDB.spamInterval)))
        return
    end
    wcCoreSetSpamInterval(math.floor(seconds))
end

local function wcAttachGui()
    local parent = SummonScoutOptionsFrame
    if not parent or not parent.CreateFontString then return end
    if WC.guiBindToken == BIND_TOKEN and WC.intervalEdit then return end

    local edit = getglobal and getglobal("SummonScoutAdvertIntervalEdit") or nil
    local button = getglobal and getglobal("SummonScoutAdvertIntervalSet") or nil

    if not edit then
        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, -421)
        label:SetText("Advert every:")

        edit = CreateFrame("EditBox", "SummonScoutAdvertIntervalEdit", parent, "InputBoxTemplate")
        edit:SetPoint("TOPLEFT", parent, "TOPLEFT", 100, -413)
        edit:SetWidth(52)
        edit:SetHeight(22)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(4)

        local secondsLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        secondsLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 157, -421)
        secondsLabel:SetText("sec")
    end

    edit:SetText(tostring(wcClampSpamInterval(SummonScoutDB and SummonScoutDB.spamInterval)))
    edit.ssFocused = false
    edit:SetScript("OnEditFocusGained", function() edit.ssFocused = true end)
    edit:SetScript("OnEditFocusLost", function() edit.ssFocused = false end)
    edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function() wcSaveInterval(); edit:ClearFocus() end)

    if not button then
        button = CreateFrame("Button", "SummonScoutAdvertIntervalSet", parent, "UIPanelButtonTemplate")
        button:SetPoint("TOPLEFT", parent, "TOPLEFT", 184, -413)
        button:SetWidth(46)
        button:SetHeight(22)
        button:SetText("Set")
    end
    button:SetScript("OnClick", wcSaveInterval)

    WC.intervalEdit = edit
    WC.guiButton = button
    WC.guiBindToken = BIND_TOKEN
end

local function wcRefreshGui()
    if not WC.intervalEdit or WC.intervalEdit.ssFocused then return end
    WC.intervalEdit:SetText(tostring(wcClampSpamInterval(SummonScoutDB and SummonScoutDB.spamInterval)))
end

local function wcResetSessionState()
    WC.pending = {}
    WC.candidates = {}
    WC.confirmations = {}
    WC.inviteIssuedAt = {}
    WC.startupSpamScheduled = false
    WC.startupSpamDelay = 0
    WC.nextGuiRefreshAt = 0
end

local M = {}

function M.Init()
    wcDisableLegacyFrame()
    wcTryRestoreLegacyInviteWrapper()
    wcAttachCoreAliasHook()

    -- A live hot migration from v1 inherits the core's already scheduled first
    -- advert. Do not schedule a second 300-400s startup advert in that session.
    if LEGACY_VERSION and LEGACY_VERSION ~= WC_VERSION and not WC.moduleVersion then
        WC.startupSpamScheduled = true
    end

    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_WHISPER")
    H.RegisterEvent("CHAT_MSG_SYSTEM")
    H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")

    wcAttachGui()
    WC.moduleVersion = WC_VERSION
    W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION = WC_VERSION
    W112_SUMMONSCOUT_COREHOT_VERSION = WC_VERSION
    W112_SUMMONSCOUT_WINTERSPRING_EVERLOOK_BRIDGE = "integrated-" .. WC_VERSION
end

function M.Shutdown()
    wcShutdownCoreAliasHook()
end

function M.OnEvent(ev, a1, a2)
    if ev == "PLAYER_LOGIN" then
        wcResetSessionState()
        wcAttachCoreAliasHook()
        WC.moduleVersion = WC_VERSION
        W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION = WC_VERSION
        W112_SUMMONSCOUT_COREHOT_VERSION = WC_VERSION
        W112_SUMMONSCOUT_WINTERSPRING_EVERLOOK_BRIDGE = "integrated-" .. WC_VERSION
        return
    end

    if ev == "CHAT_MSG_WHISPER_INFORM" then
        if H.ManualChatObserveOutgoing then
            H.ManualChatObserveOutgoing(a1 or "", a2 or "")
        end
        return
    end

    if ev == "CHAT_MSG_SYSTEM" then
        wcNoteSystemInvite(a1 or "")
        return
    end

    if ev == "CHAT_MSG_WHISPER" then
        local message = a1 or ""
        local sender = wcTrim(a2 or "")
        if sender == "" then return end

        if H.IsManualChatLocked and H.IsManualChatLocked(sender) then
            if H.ManualChatLock then H.ManualChatLock(sender, true) end
            return
        end

        if not wcEligible(sender) then return end
        if wcHandlePendingReply(sender, message) then return end
        wcQueueUnknownProbe(sender, message)
    end
end

function M.OnUpdate()
    if H.ManualChatSweep then H.ManualChatSweep() end

    wcScheduleStartupSpam()
    wcProcessCandidates()
    wcProcessConfirmations()
    wcExpirePending()
    wcAttachGui()

    local t = wcNow()
    if t >= (WC.nextGuiRefreshAt or 0) then
        WC.nextGuiRefreshAt = t + 0.50
        wcRefreshGui()
    end
end

-- Safe manual-conversation lock. It deliberately avoids wrapping the HotHost
-- frame, SendChatMessage, InviteByName or OnUpdate. The previous v1 overlay did
-- so and could stack wrappers across hot reloads. This migration peels those
-- legacy wrappers before registering the new module.
local MC = H.GetState("manualchat")
local MC_LOCK_SECONDS = 300
MC.lockedUntil = MC.lockedUntil or {}

local function mcKey(name)
    return wcLower(wcTrim(name or ""))
end

local function mcUnwrapNamed(fn, nameA, nameB)
    local current = fn
    local depth = 0
    while type(current) == "function" and depth < 32 do
        local nextFn = nil
        local i
        for i = 1, 24 do
            local upName, upValue = wcDebugGetUpvalue(current, i)
            if not upName then break end
            if (upName == nameA or (nameB and upName == nameB))
                and type(upValue) == "function" then
                nextFn = upValue
                break
            end
        end
        if not nextFn or nextFn == current then break end
        current = nextFn
        depth = depth + 1
    end
    return current
end

local function mcCleanupLegacyWrappers()
    if H.frame and H.frame.GetScript and H.frame.SetScript then
        local hostEvent = H.frame:GetScript("OnEvent")
        local cleanHostEvent = mcUnwrapNamed(hostEvent, "hostOriginalOnEvent")
        if cleanHostEvent ~= hostEvent then
            H.frame:SetScript("OnEvent", cleanHostEvent)
        elseif MC.hostEventWrapper and MC.hostOriginalOnEvent
            and hostEvent == MC.hostEventWrapper then
            H.frame:SetScript("OnEvent", MC.hostOriginalOnEvent)
        end

        local hostUpdate = H.frame:GetScript("OnUpdate")
        local cleanHostUpdate = mcUnwrapNamed(hostUpdate, "hostOriginalOnUpdate")
        if cleanHostUpdate ~= hostUpdate then
            H.frame:SetScript("OnUpdate", cleanHostUpdate)
        elseif MC.hostUpdateWrapper and MC.hostOriginalOnUpdate
            and hostUpdate == MC.hostUpdateWrapper then
            H.frame:SetScript("OnUpdate", MC.hostOriginalOnUpdate)
        end
    end

    local core = SummonScoutFrame
    if core and core.GetScript and core.SetScript then
        local coreEvent = core:GetScript("OnEvent")
        local cleanCoreEvent = mcUnwrapNamed(coreEvent, "originalOnEvent", "OWN_CORE_BASE")
        if cleanCoreEvent ~= coreEvent then
            core:SetScript("OnEvent", cleanCoreEvent)
        elseif MC.coreEventWrapper and MC.coreOriginalOnEvent
            and coreEvent == MC.coreEventWrapper then
            core:SetScript("OnEvent", MC.coreOriginalOnEvent)
        end

        local coreUpdate = core:GetScript("OnUpdate")
        local cleanCoreUpdate = mcUnwrapNamed(coreUpdate, "coreOriginalOnUpdate")
        if cleanCoreUpdate ~= coreUpdate then
            core:SetScript("OnUpdate", cleanCoreUpdate)
        elseif MC.coreUpdateWrapper and MC.coreOriginalOnUpdate
            and coreUpdate == MC.coreUpdateWrapper then
            core:SetScript("OnUpdate", MC.coreOriginalOnUpdate)
        end
    end

    MC.hostEventWrapper = nil
    MC.hostOriginalOnEvent = nil
    MC.hostUpdateWrapper = nil
    MC.hostOriginalOnUpdate = nil
    MC.coreEventWrapper = nil
    MC.coreOriginalOnEvent = nil
    MC.coreUpdateWrapper = nil
    MC.coreOriginalOnUpdate = nil
end

local function mcIsLocked(name)
    local key = mcKey(name)
    if key == "" then return false end
    local untilAt = tonumber(MC.lockedUntil[key]) or 0
    if untilAt <= wcNow() then
        MC.lockedUntil[key] = nil
        return false
    end
    return true
end

local function mcCancelPending(name)
    local key = mcKey(name)
    if key == "" then return end

    WC.pending[key] = nil
    WC.candidates[key] = nil
    WC.confirmations[key] = nil

    local pp = H.GetState("postpay")
    if type(pp) == "table" then
        if type(pp.directInvitePending) == "table" then
            pp.directInvitePending[key] = nil
        end
        if type(pp.directInviteRecent) == "table" then
            pp.directInviteRecent[key] = wcNow()
        end
        if type(pp.pending) == "table" then
            local i
            for i = table.getn(pp.pending), 1, -1 do
                local item = pp.pending[i]
                if type(item) == "table" and mcKey(item.name) == key then
                    table.remove(pp.pending, i)
                end
            end
        end
    end
end

local function mcLock(name, quiet)
    local key = mcKey(name)
    if key == "" or wcSamePlayer(name, UnitName("player")) then return false end
    MC.lockedUntil[key] = wcNow() + MC_LOCK_SECONDS
    mcCancelPending(name)
    if not quiet and SummonScoutDB and SummonScoutDB.debug then
        wcChat("manual whisper conversation -> automation muted for " .. wcTrim(name) .. " (5m)")
    end
    return true
end

local function mcLooksAutomatic(message)
    local raw = wcTrim(message or "")
    local s = wcLower(raw)
    if raw == "" then return false end

    if string.sub(raw, 1, 5) == "[SSI " then return true end
    if string.sub(raw, 1, 17) == "Summoning you to " then return true end
    if string.sub(raw, 1, 12) == "Do you need "
        and string.len(raw) >= 8
        and string.sub(raw, -8) == " summon?" then
        return true
    end
    if raw == "You are already grouped. Leave your group and whisper me again for an invite." then
        return true
    end

    local thankLead = string.sub(s, 1, 6) == "thank "
        or string.sub(s, 1, 7) == "thanks "
        or string.sub(s, 1, 11) == "many thanks"
        or string.sub(s, 1, 16) == "much appreciated"
        or string.sub(s, 1, 7) == "cheers,"
    if thankLead
        and string.find(s, "hyjal", 1, true)
        and string.find(s, "hydraxis", 1, true)
        and string.find(s, "winterspring", 1, true) then
        return true
    end
    return false
end

local function mcObserveOutgoing(message, target)
    target = wcTrim(target or "")
    if target == "" or wcSamePlayer(target, UnitName("player")) then return end
    if mcLooksAutomatic(message) then return end
    mcLock(target, false)
end

local function mcSweep()
    local key
    for key in pairs(MC.lockedUntil) do
        if mcIsLocked(key) then
            mcCancelPending(key)
        end
    end
end

mcCleanupLegacyWrappers()
H.IsManualChatLocked = mcIsLocked
H.ManualChatLock = mcLock
H.ManualChatObserveOutgoing = mcObserveOutgoing
H.ManualChatSweep = mcSweep
H.ManualChatLockSeconds = MC_LOCK_SECONDS
W112_SUMMONSCOUT_MANUAL_CHAT_LOCK_VERSION = "2-safe"

H.Register("whisperconfirm", M, WC_VERSION)
if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout PING]|r manual-chat safe hotfix loaded")
end
