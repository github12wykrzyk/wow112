-- Hot-swappable SummonScout post-payment module.
-- Loaded once by TOC and later re-executed by the native hot-Lua watcher.
-- Runtime state lives in W112_SUMMONSCOUT_HOT and survives code replacement.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local POSTPAY_VERSION = "5-postpay-confirm1"
local PP = H.GetState("postpay")
PP.pending = PP.pending or {}
PP.lastMessageIndex = tonumber(PP.lastMessageIndex) or 0
PP.nextPollAt = tonumber(PP.nextPollAt) or 0
PP.recentClosedAt = tonumber(PP.recentClosedAt) or 0
PP.groupedNoticeRecent = PP.groupedNoticeRecent or {}
PP.directInvitePending = PP.directInvitePending or {}
PP.directInviteRecent = PP.directInviteRecent or {}

-- Direct-whisper roots intentionally use token-prefix matching. This keeps the
-- parser tolerant of shorthand / suffix typos such as invv, invvv, portt,
-- taxii, buying or wtbb without changing the broader World/seller dictionaries.
local DIRECT_INVITE_ROOTS = {
    "inv", "port", "taxi", "buy", "wtb"
}

local DIRECT_INVITE_DELAY = 0.65
local DIRECT_INVITE_DEDUPE = 2.0
local POSTPAY_RETRY_DELAY = 1.25
local POSTPAY_MAX_ATTEMPTS = 2

local DIRECT_INVITE_HARD_BLACKLIST = {
    ["hydraone"] = true,
    ["hydratwo"] = true,
    ["bolthyjal"] = true
}

local POSTPAY_MESSAGES = {
    "Thank you! I also offer summons to Hyjal, Hydraxis and Winterspring.",
    "Thanks a lot! Summons also available to Hyjal, Hydraxis and Winterspring.",
    "Thank you for the payment! I also summon to Hyjal, Hydraxis and Winterspring.",
    "Many thanks! I can summon you to Hyjal, Hydraxis or Winterspring too.",
    "Thanks! Need another summon? Hyjal, Hydraxis and Winterspring are available.",
    "Thank you! Other destinations: Hyjal, Hydraxis and Winterspring.",
    "Much appreciated! I also run summons to Hyjal, Hydraxis and Winterspring.",
    "Thanks for using my summon! Hyjal, Hydraxis and Winterspring are available too.",
    "Thank you very much! I also offer Hyjal, Hydraxis and Winterspring summons.",
    "Thanks! I can also get you to Hyjal, Hydraxis or Winterspring.",
    "Thank you! Summon service also covers Hyjal, Hydraxis and Winterspring.",
    "Cheers, thank you! I also summon to Hyjal, Hydraxis and Winterspring.",
    "Thanks a ton! Hyjal, Hydraxis and Winterspring summons are available too.",
    "Thank you for the gold! I also offer Hyjal, Hydraxis and Winterspring.",
    "Many thanks for the payment! Hyjal, Hydraxis and Winterspring also available.",
    "Thank you! If you need more, I summon to Hyjal, Hydraxis and Winterspring.",
    "Thanks! My other summon spots are Hyjal, Hydraxis and Winterspring.",
    "Much appreciated! I can also summon to Hyjal, Hydraxis and Winterspring.",
    "Thank you! Hyjal, Hydraxis and Winterspring are also on my summon list.",
    "Thanks for the support! I also offer summons to Hyjal, Hydraxis and Winterspring."
}

local function ppNow()
    if GetTime then return GetTime() end
    return 0
end

local function ppTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function ppNormalize(s)
    s = string.lower(s or "")
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return ppTrim(s)
end

local function ppValidName(name)
    name = ppTrim(name)
    return name ~= "" and string.upper(name) ~= "UNKNOWN"
end

local function ppSamePlayer(a, b)
    a = string.lower(ppTrim(a or ""))
    b = string.lower(ppTrim(b or ""))
    return a ~= "" and a == b
end

local function ppInGroup(name)
    local i
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if ppSamePlayer(UnitName("party" .. i), name) then return true end
    end
    if GetNumRaidMembers and GetRaidRosterInfo then
        for i = 1, GetNumRaidMembers() do
            local raidName = GetRaidRosterInfo(i)
            if ppSamePlayer(raidName, name) then return true end
        end
    end
    return false
end

local function ppInviteBlacklisted(name)
    local key = string.lower(ppTrim(name or ""))
    if key == "" or DIRECT_INVITE_HARD_BLACKLIST[key] then return true end
    local list = SummonScoutDB and SummonScoutDB.inviteBlacklist
    return type(list) == "table" and list[key] ~= nil
end

local function ppCountSoulShards()
    local total = 0
    local bag, slot
    if not GetContainerNumSlots or not GetContainerItemLink then return -1 end
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            if link and string.find(link, "item:6265:", 1, true) then
                local _, count = GetContainerItemInfo(bag, slot)
                total = total + (tonumber(count) or 1)
            end
        end
    end
    return total
end

local function ppShardBlocked()
    if not SummonScoutDB or not SummonScoutDB.shardGuardEnabled then return false end
    local shards = ppCountSoulShards()
    if shards < 0 then return false end
    local threshold = math.floor(tonumber(SummonScoutDB.shardGuardMin) or 5)
    if threshold < 1 then threshold = 1 end
    return shards < threshold
end

local function ppChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. tostring(text or ""))
    end
end

local function ppHasDirectInviteRoot(message)
    local s = ppNormalize(message)
    local token, i
    if s == "" then return false, nil end

    for token in string.gfind(s, "%S+") do
        for i = 1, table.getn(DIRECT_INVITE_ROOTS) do
            local root = DIRECT_INVITE_ROOTS[i]
            if string.len(token) >= string.len(root)
                and string.sub(token, 1, string.len(root)) == root then
                return true, root
            end
        end
    end
    return false, nil
end

local function ppDirectInviteEligible(name)
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.whisperAutoInvite then
        return false
    end
    if not ppValidName(name) or ppSamePlayer(name, UnitName("player")) then return false end
    if ppInGroup(name) or ppInviteBlacklisted(name) or ppShardBlocked() then return false end
    return true
end

local function ppQueueDirectInvite(sender, message)
    local matched, root = ppHasDirectInviteRoot(message)
    if not matched or not ppDirectInviteEligible(sender) then return false end

    local name = ppTrim(sender)
    local key = string.lower(name)
    local t = ppNow()
    local recent = tonumber(PP.directInviteRecent[key]) or -100000
    if (t - recent) < DIRECT_INVITE_DEDUPE then return true end

    PP.directInvitePending[key] = {
        sender = name,
        root = root,
        dueAt = t + DIRECT_INVITE_DELAY
    }
    if SummonScoutDB.debug then
        ppChat("direct prefix " .. tostring(root) .. "* -> pending " .. name)
    end
    return true
end

local function ppNoteInviteSuccess(line)
    line = ppTrim(line or "")
    local _, _, name = string.find(line, "^You have invited (.+) to join your group%.?$")
    name = ppTrim(name or "")
    if not ppValidName(name) then return false end

    local key = string.lower(name)
    PP.directInviteRecent[key] = ppNow()
    PP.directInvitePending[key] = nil
    return true
end

local function ppGroupedName(line)
    line = ppTrim(line or "")
    local _, _, name = string.find(line, "^(.+) is already in a group%.?$")
    if not name then
        _, _, name = string.find(line, "^(.+) is already grouped%.?$")
    end
    if not name then
        _, _, name = string.find(line, "^(.+) is already in group%.?$")
    end
    name = ppTrim(name or "")
    if ppValidName(name) then return name end
    return nil
end

local function ppNotifyGrouped(line)
    local name = ppGroupedName(line)
    if not name or not SendChatMessage then return false end

    local key = string.lower(name)
    local t = ppNow()
    PP.directInvitePending[key] = nil
    PP.directInviteRecent[key] = t

    local last = tonumber(PP.groupedNoticeRecent[key]) or -100000
    if (t - last) < 5 then return true end
    PP.groupedNoticeRecent[key] = t

    local message = "You are already grouped. Leave your group and whisper me again for an invite."
    if pcall then
        local ok = pcall(SendChatMessage, message, "WHISPER", nil, name)
        if not ok then return false end
    else
        SendChatMessage(message, "WHISPER", nil, name)
    end

    if SummonScoutDB and SummonScoutDB.debug then
        ppChat("already-grouped whisper -> " .. name)
    end
    return true
end

local function ppProcessDirectInvites()
    local t = ppNow()
    local key, item
    for key, item in pairs(PP.directInvitePending) do
        if t >= (item.dueAt or 0) then
            PP.directInvitePending[key] = nil
            local recent = tonumber(PP.directInviteRecent[key]) or -100000
            if (t - recent) >= DIRECT_INVITE_DEDUPE
                and ppDirectInviteEligible(item.sender)
                and InviteByName then
                PP.directInviteRecent[key] = t
                InviteByName(item.sender)
                if SummonScoutDB.debug then
                    ppChat("direct prefix " .. tostring(item.root or "?") .. "* -> invite " .. item.sender)
                end
            end
        end
    end
end

local function ppEnabled()
    return SummonScoutDB and SummonScoutDB.postPaymentOfferEnabled == true
end

local function ppSetDefaults()
    SummonScoutDB = SummonScoutDB or {}
    if SummonScoutDB.postPaymentOfferEnabled == nil then
        SummonScoutDB.postPaymentOfferEnabled = false
    end
end

local function ppResetSessionCursor()
    local current = math.floor(tonumber(SummonScoutDB and SummonScoutDB.paymentCount) or 0)
    PP.lastPaymentCount = current
    PP.pending = {}
    PP.tradeRequestedBy = nil
    PP.tradePartner = nil
    PP.recentClosedPartner = nil
    PP.recentClosedAt = 0
    PP.nextPollAt = 0
    PP.groupedNoticeRecent = {}
    PP.directInvitePending = {}
    PP.directInviteRecent = {}
end

local function ppLiveTradePartner()
    local name
    if UnitName then
        name = UnitName("NPC")
        if ppValidName(name) then return ppTrim(name) end
    end
    if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        name = TradeFrameRecipientNameText:GetText()
        if ppValidName(name) then return ppTrim(name) end
    end
    return nil
end

local function ppRefreshTradePartner()
    local name = ppLiveTradePartner()
    if not ppValidName(name) and ppValidName(PP.tradeRequestedBy) then
        name = PP.tradeRequestedBy
    end
    if ppValidName(name) then
        PP.tradePartner = ppTrim(name)
        return PP.tradePartner
    end
    return nil
end

local function ppResolvePaymentName(payment)
    if type(payment) ~= "table" then return nil end

    local name = ppTrim(payment.player or "")
    if ppValidName(name) then return name end

    if ppValidName(PP.recentClosedPartner)
        and (ppNow() - (PP.recentClosedAt or 0)) <= 5.0 then
        name = PP.recentClosedPartner
    end

    if ppValidName(name) then
        name = ppTrim(name)
        payment.player = name
        if SummonScoutDB and SummonScoutDB.debug then
            ppChat("post-payment payer recovered -> " .. name)
        end
        return name
    end
    return nil
end

local function ppChooseMessage()
    local count = table.getn(POSTPAY_MESSAGES)
    if count <= 0 then return nil end

    local index = 1
    if math and math.random then
        index = math.random(count)
    else
        index = math.mod(math.floor(ppNow() * 1000), count) + 1
    end

    if count > 1 and index == PP.lastMessageIndex then
        index = math.mod(index, count) + 1
    end
    PP.lastMessageIndex = index
    return POSTPAY_MESSAGES[index]
end

local function ppSendItem(item)
    if type(item) ~= "table" then return false end
    local name = ppTrim(item.name or "")
    if not ppValidName(name) or not ppEnabled() or not SendChatMessage then
        return false
    end

    if not item.message or item.message == "" then
        item.message = ppChooseMessage()
    end
    if not item.message then return false end

    item.attempts = (tonumber(item.attempts) or 0) + 1
    item.sentAt = ppNow()
    item.retryAt = item.sentAt + POSTPAY_RETRY_DELAY
    item.awaitingAck = true

    if pcall then
        local ok = pcall(SendChatMessage, item.message, "WHISPER", nil, name)
        if not ok then
            item.awaitingAck = false
            item.retryAt = ppNow() + 0.35
            if SummonScoutDB.debug then
                ppChat("post-payment whisper call failed -> " .. name)
            end
            return false
        end
    else
        SendChatMessage(item.message, "WHISPER", nil, name)
    end

    if SummonScoutDB.debug then
        ppChat("post-payment whisper attempt " .. tostring(item.attempts) .. " -> " .. name)
    end
    return true
end

local function ppConfirmOutgoing(message, name)
    message = message or ""
    name = ppTrim(name or "")
    if message == "" or not ppValidName(name) then return false end

    local i
    for i = 1, table.getn(PP.pending) do
        local item = PP.pending[i]
        if item and item.awaitingAck
            and ppSamePlayer(item.name, name)
            and item.message == message then
            item.confirmed = true
            item.awaitingAck = false
            if SummonScoutDB and SummonScoutDB.debug then
                ppChat("post-payment confirmed -> " .. name)
            end
            return true
        end
    end
    return false
end

local function ppQueueName(name)
    if not ppEnabled() or not ppValidName(name) then return false end
    PP.pending[table.getn(PP.pending) + 1] = {
        name = ppTrim(name),
        dueAt = ppNow() + 0.35 + (table.getn(PP.pending) * 0.35),
        attempts = 0,
        awaitingAck = false,
        confirmed = false
    }
    return true
end

local function ppQueuePayment(payment)
    if not ppEnabled() or type(payment) ~= "table" then return end
    local name = ppResolvePaymentName(payment)
    if ppValidName(name) then
        ppQueueName(name)
        return
    end
    if SummonScoutDB.debug then
        ppChat("post-payment skipped -> unresolved payer")
    end
end

local function ppObserveLedger()
    if not SummonScoutDB then return end

    local current = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
    local log = SummonScoutDB.paymentLog

    if PP.lastPaymentCount == nil then
        PP.lastPaymentCount = current
        return
    end

    if current < PP.lastPaymentCount then
        PP.lastPaymentCount = current
        PP.pending = {}
        return
    end

    if current == PP.lastPaymentCount then return end

    local delta = current - PP.lastPaymentCount
    PP.lastPaymentCount = current
    if not ppEnabled() or type(log) ~= "table" then return end

    local logCount = table.getn(log)
    local first = logCount - delta + 1
    if first < 1 then first = 1 end

    local i
    for i = first, logCount do
        ppQueuePayment(log[i])
    end
end

local function ppProcessPending()
    if table.getn(PP.pending) == 0 then return end
    if not ppEnabled() then
        PP.pending = {}
        return
    end

    local item = PP.pending[1]
    local t = ppNow()

    if item.confirmed then
        table.remove(PP.pending, 1)
        return
    end

    if item.awaitingAck then
        if t < (item.retryAt or 0) then return end
        item.awaitingAck = false
        if (tonumber(item.attempts) or 0) >= POSTPAY_MAX_ATTEMPTS then
            if SummonScoutDB.debug then
                ppChat("post-payment unconfirmed after retry -> " .. tostring(item.name or "?"))
            end
            table.remove(PP.pending, 1)
            return
        end
        item.dueAt = t
    end

    if t < (item.dueAt or 0) then return end

    local sent = ppSendItem(item)
    if not sent then
        if (tonumber(item.attempts) or 0) >= POSTPAY_MAX_ATTEMPTS then
            table.remove(PP.pending, 1)
        else
            item.dueAt = t + 0.35
        end
    end
end

local function ppAttachGuiToggle()
    local parent = SummonScoutOptionsFrame
    if not parent or not parent.CreateFontString then return end

    local check = PP.guiCheck
    if not check and getglobal then check = getglobal("SummonScoutPostPaymentOfferCheck") end
    if not check then
        check = CreateFrame("CheckButton", "SummonScoutPostPaymentOfferCheck", parent, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", parent, "TOPLEFT", 368, -474)
        check:SetWidth(20)
        check:SetHeight(20)
    end
    check:SetChecked(ppEnabled() and 1 or nil)
    check:SetScript("OnClick", function()
        SummonScoutDB.postPaymentOfferEnabled = check:GetChecked() and true or false
        if not SummonScoutDB.postPaymentOfferEnabled then PP.pending = {} end
        ppChat("post-payment thank-you + offer -> "
            .. (SummonScoutDB.postPaymentOfferEnabled and "ON" or "OFF"))
    end)
    PP.guiCheck = check

    local label
    if getglobal then label = getglobal("SummonScoutPostPaymentOfferLabel") end
    if not label then
        label = parent:CreateFontString("SummonScoutPostPaymentOfferLabel", "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", check, "RIGHT", 2, -1)
    end
    label:SetText("Thank + offer after payment")
end

local M = {}

function M.Init()
    ppSetDefaults()
    if PP.moduleVersion ~= POSTPAY_VERSION then
        ppResetSessionCursor()
        PP.moduleVersion = POSTPAY_VERSION
    elseif PP.lastPaymentCount == nil then
        PP.lastPaymentCount = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
    end
    PP.initialized = true
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("TRADE_REQUEST")
    H.RegisterEvent("TRADE_SHOW")
    H.RegisterEvent("TRADE_MONEY_CHANGED")
    H.RegisterEvent("TRADE_ACCEPT_UPDATE")
    H.RegisterEvent("TRADE_CLOSED")
    H.RegisterEvent("CHAT_MSG_SYSTEM")
    H.RegisterEvent("CHAT_MSG_WHISPER")
    H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    ppAttachGuiToggle()
    W112_SUMMONSCOUT_POSTPAY_OFFER_VERSION = POSTPAY_VERSION
    W112_SUMMONSCOUT_GROUPED_NOTICE_VERSION = "1"
    W112_SUMMONSCOUT_DIRECT_PREFIX_VERSION = "1"
end

function M.OnEvent(ev, a1, a2)
    if ev == "PLAYER_LOGIN" then
        ppSetDefaults()
        ppResetSessionCursor()
        PP.moduleVersion = POSTPAY_VERSION
        PP.initialized = true
        W112_SUMMONSCOUT_POSTPAY_OFFER_VERSION = POSTPAY_VERSION
        W112_SUMMONSCOUT_GROUPED_NOTICE_VERSION = "1"
        W112_SUMMONSCOUT_DIRECT_PREFIX_VERSION = "1"
        return
    end

    if ev == "CHAT_MSG_SYSTEM" then
        ppNoteInviteSuccess(a1 or "")
        ppNotifyGrouped(a1 or "")
        return
    end

    if ev == "CHAT_MSG_WHISPER" then
        ppQueueDirectInvite(a2 or "", a1 or "")
        return
    end

    if ev == "CHAT_MSG_WHISPER_INFORM" then
        ppConfirmOutgoing(a1 or "", a2 or "")
        return
    end

    if ev == "TRADE_REQUEST" then
        local name = ppTrim(a1 or "")
        PP.tradeRequestedBy = ppValidName(name) and name or nil
        return
    end

    if ev == "TRADE_SHOW" then
        PP.tradePartner = nil
        ppRefreshTradePartner()
        return
    end

    if ev == "TRADE_MONEY_CHANGED" or ev == "TRADE_ACCEPT_UPDATE" then
        ppRefreshTradePartner()
        return
    end

    if ev == "TRADE_CLOSED" then
        local name = ppRefreshTradePartner()
        if not ppValidName(name) and ppValidName(PP.tradePartner) then
            name = PP.tradePartner
        end
        if ppValidName(name) then
            PP.recentClosedPartner = ppTrim(name)
            PP.recentClosedAt = ppNow()
        else
            PP.recentClosedPartner = nil
            PP.recentClosedAt = ppNow()
        end
        PP.tradeRequestedBy = nil
        PP.tradePartner = nil
    end
end

function M.OnUpdate()
    local t = ppNow()
    ppProcessDirectInvites()
    if t < (PP.nextPollAt or 0) then
        ppProcessPending()
        return
    end
    PP.nextPollAt = t + 0.20
    ppAttachGuiToggle()
    ppObserveLedger()
    ppProcessPending()
end

H.Register("postpay", M, POSTPAY_VERSION)
if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout PING]|r direct-prefix hot-test received")
end