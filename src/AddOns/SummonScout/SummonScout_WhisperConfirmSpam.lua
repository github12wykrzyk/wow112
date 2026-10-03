-- SummonScout unknown-whisper confirmation + advert interval companion.
-- WoW 1.12.1 / Lua 5.0 compatible; keeps the existing core invite/summon flow intact.

local WC_VERSION = "1"
local WC_PENDING_SECONDS = 60
local WC_PROBE_COOLDOWN = 120
local WC_STARTUP_SPAM_MIN = 300
local WC_STARTUP_SPAM_MAX = 400

local WC = {
    pending = {},
    candidates = {},
    confirmations = {},
    probedAt = {},
    inviteIssuedAt = {},
    inviteWrapped = false,
    originalInviteByName = nil,
    startupSpamScheduled = false,
    startupSpamDelay = 0,
    guiAttached = false,
    intervalEdit = nil,
    nextGuiRefreshAt = 0
}

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

local function wcInstallInviteObserver()
    if WC.inviteWrapped or type(InviteByName) ~= "function" then return end
    WC.originalInviteByName = InviteByName
    InviteByName = function(name)
        local key = wcKey(name)
        if key ~= "" then WC.inviteIssuedAt[key] = wcNow() end
        return WC.originalInviteByName(name)
    end
    WC.inviteWrapped = true
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
    if WC.pending[key] then return end
    if lastProbe and (t - lastProbe) < WC_PROBE_COOLDOWN then return end

    WC.candidates[key] = {
        sender = wcTrim(sender),
        seenAt = t,
        dueAt = t + 0.20
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
        -- Keep the one outstanding question alive until timeout, but never spam it again.
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
            if not alreadyInvited and wcEligible(item.sender) then
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
    SummonScoutDB.spamInterval = seconds
    return false
end

local function wcScheduleStartupSpam()
    if WC.startupSpamScheduled or not SummonScoutDB or not SummonScoutDB.spamEnabled then return end

    local recurring = wcClampSpamInterval(SummonScoutDB.spamInterval)
    SummonScoutDB.spamInterval = recurring
    local delay = math.random(WC_STARTUP_SPAM_MIN, WC_STARTUP_SPAM_MAX)

    -- Reuse the core slash handler because it owns SS.nextSpamAt. Then restore
    -- the recurring interval in SavedVariables: only the first post-login advert
    -- gets the randomized 300-400s delay; later adverts use the GUI interval.
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
        WC.intervalEdit:SetText(tostring(wcClampSpamInterval(SummonScoutDB.spamInterval)))
        return
    end
    wcCoreSetSpamInterval(math.floor(seconds))
end

local function wcAttachGui()
    if WC.guiAttached or not SummonScoutOptionsFrame or not SummonScoutOptionsFrame.CreateFontString then return end
    local parent = SummonScoutOptionsFrame

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, -421)
    label:SetText("Advert every:")

    local edit = CreateFrame("EditBox", "SummonScoutAdvertIntervalEdit", parent, "InputBoxTemplate")
    edit:SetPoint("TOPLEFT", parent, "TOPLEFT", 100, -413)
    edit:SetWidth(52)
    edit:SetHeight(22)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(4)
    edit:SetText(tostring(wcClampSpamInterval(SummonScoutDB.spamInterval)))
    edit.ssFocused = false
    edit:SetScript("OnEditFocusGained", function() edit.ssFocused = true end)
    edit:SetScript("OnEditFocusLost", function() edit.ssFocused = false end)
    edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function() wcSaveInterval(); edit:ClearFocus() end)

    local secondsLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    secondsLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 157, -421)
    secondsLabel:SetText("sec")

    local button = CreateFrame("Button", "SummonScoutAdvertIntervalSet", parent, "UIPanelButtonTemplate")
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", 184, -413)
    button:SetWidth(46)
    button:SetHeight(22)
    button:SetText("Set")
    button:SetScript("OnClick", wcSaveInterval)

    WC.intervalEdit = edit
    WC.guiAttached = true
end

local function wcRefreshGui()
    if not WC.guiAttached or not WC.intervalEdit or WC.intervalEdit.ssFocused then return end
    WC.intervalEdit:SetText(tostring(wcClampSpamInterval(SummonScoutDB.spamInterval)))
end

local frame = CreateFrame("Frame", "SummonScoutWhisperConfirmSpamFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        wcInstallInviteObserver()
        W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION = WC_VERSION
        return
    end

    if event == "CHAT_MSG_WHISPER" then
        local message = arg1 or ""
        local sender = wcTrim(arg2 or "")
        if sender == "" or not wcEligible(sender) then return end

        if wcHandlePendingReply(sender, message) then return end
        wcQueueUnknownProbe(sender, message)
    end
end)

frame:SetScript("OnUpdate", function()
    wcInstallInviteObserver()
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
end)
