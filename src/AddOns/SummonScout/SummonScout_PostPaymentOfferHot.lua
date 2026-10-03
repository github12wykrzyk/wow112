-- Hot-swappable SummonScout post-payment module.
-- Loaded once by TOC and later re-executed by the native hot-Lua watcher.
-- Runtime state lives in W112_SUMMONSCOUT_HOT and survives code replacement.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local POSTPAY_VERSION = "4-hot1"
local PP = H.GetState("postpay")
PP.pending = PP.pending or {}
PP.lastMessageIndex = tonumber(PP.lastMessageIndex) or 0
PP.nextPollAt = tonumber(PP.nextPollAt) or 0
PP.recentClosedAt = tonumber(PP.recentClosedAt) or 0

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

local function ppValidName(name)
    name = ppTrim(name)
    return name ~= "" and string.upper(name) ~= "UNKNOWN"
end

local function ppChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. tostring(text or ""))
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

local function ppSend(name)
    name = ppTrim(name)
    if not ppValidName(name) or not ppEnabled() or not SendChatMessage then
        return false
    end

    local message = ppChooseMessage()
    if not message then return false end

    if pcall then
        local ok = pcall(SendChatMessage, message, "WHISPER", nil, name)
        if not ok then
            if SummonScoutDB.debug then ppChat("post-payment whisper failed -> " .. name) end
            return false
        end
    else
        SendChatMessage(message, "WHISPER", nil, name)
    end

    if SummonScoutDB.debug then
        ppChat("post-payment thank-you -> " .. name)
    end
    return true
end

local function ppQueueName(name)
    if not ppEnabled() or not ppValidName(name) then return false end
    PP.pending[table.getn(PP.pending) + 1] = {
        name = ppTrim(name),
        dueAt = ppNow() + 0.35 + (table.getn(PP.pending) * 0.35)
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
    local item = PP.pending[1]
    if ppNow() < (item.dueAt or 0) then return end
    table.remove(PP.pending, 1)
    if ppEnabled() then ppSend(item.name) end
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
    if PP.lastPaymentCount == nil then
        PP.lastPaymentCount = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
    end
    PP.initialized = true
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("TRADE_REQUEST")
    H.RegisterEvent("TRADE_SHOW")
    H.RegisterEvent("TRADE_MONEY_CHANGED")
    H.RegisterEvent("TRADE_ACCEPT_UPDATE")
    H.RegisterEvent("TRADE_CLOSED")
    ppAttachGuiToggle()
    W112_SUMMONSCOUT_POSTPAY_OFFER_VERSION = POSTPAY_VERSION
end

function M.OnEvent(ev, a1)
    if ev == "PLAYER_LOGIN" then
        ppSetDefaults()
        if PP.lastPaymentCount == nil then
            PP.lastPaymentCount = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
        end
        PP.initialized = true
        W112_SUMMONSCOUT_POSTPAY_OFFER_VERSION = POSTPAY_VERSION
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
