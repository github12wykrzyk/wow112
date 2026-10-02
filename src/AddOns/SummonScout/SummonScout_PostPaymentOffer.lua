-- SummonScout post-payment customer follow-up for WoW 1.12.1 (5875).
--
-- This companion deliberately observes only SummonScout's trusted payment
-- ledger. The core records a payment after a real positive wallet delta, so
-- cancelled/zero trades cannot trigger a customer thank-you message here.

local POSTPAY_VERSION = "1"

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

local PP = {
    initialized = false,
    lastPaymentCount = nil,
    lastMessageIndex = 0,
    nextPollAt = 0,
    pending = {},
    guiCheck = nil
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

local function ppChooseMessage()
    local count = table.getn(POSTPAY_MESSAGES)
    if count <= 0 then return nil end

    local index = 1
    if math and math.random then
        index = math.random(count)
    else
        index = math.mod(math.floor(ppNow() * 1000), count) + 1
    end

    -- Preserve randomness while avoiding the visibly repetitive case where
    -- two consecutive customers get the exact same line.
    if count > 1 and index == PP.lastMessageIndex then
        index = math.mod(index, count) + 1
    end
    PP.lastMessageIndex = index
    return POSTPAY_MESSAGES[index]
end

local function ppSend(name)
    name = ppTrim(name)
    if name == "" or name == "UNKNOWN" or not ppEnabled() or not SendChatMessage then
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

local function ppQueuePayment(payment)
    if not ppEnabled() or type(payment) ~= "table" then return end
    local name = ppTrim(payment.player or "")
    if name == "" or name == "UNKNOWN" then return end

    PP.pending[table.getn(PP.pending) + 1] = {
        name = name,
        dueAt = ppNow() + 0.35 + (table.getn(PP.pending) * 0.35)
    }
end

local function ppObserveLedger()
    if not SummonScoutDB then return end

    local current = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
    local log = SummonScoutDB.paymentLog

    if PP.lastPaymentCount == nil then
        -- Never replay historical payments after login/reload.
        PP.lastPaymentCount = current
        return
    end

    if current < PP.lastPaymentCount then
        -- Trusted ledger was cleared/reset.
        PP.lastPaymentCount = current
        PP.pending = {}
        return
    end

    if current == PP.lastPaymentCount then return end

    local delta = current - PP.lastPaymentCount
    PP.lastPaymentCount = current

    -- Advance the cursor even while the toggle is OFF, so enabling the feature
    -- never sends stale marketing whispers for old payments.
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
    if ppEnabled() then
        ppSend(item.name)
    end
end

local function ppAttachGuiToggle()
    if PP.guiCheck then return end
    if not SummonScoutOptionsFrame or not SummonScoutOptionsFrame.CreateFontString then return end

    local parent = SummonScoutOptionsFrame
    local check = CreateFrame("CheckButton", "SummonScoutPostPaymentOfferCheck", parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", 368, -474)
    check:SetWidth(20)
    check:SetHeight(20)
    check:SetChecked(ppEnabled() and 1 or nil)
    check:SetScript("OnClick", function()
        SummonScoutDB.postPaymentOfferEnabled = check:GetChecked() and true or false
        if not SummonScoutDB.postPaymentOfferEnabled then
            PP.pending = {}
        end
        ppChat("post-payment thank-you + offer -> "
            .. (SummonScoutDB.postPaymentOfferEnabled and "ON" or "OFF"))
    end)

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", check, "RIGHT", 2, -1)
    label:SetText("Thank + offer after payment")

    PP.guiCheck = check
end

local frame = CreateFrame("Frame", "SummonScoutPostPaymentOfferFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        ppSetDefaults()
        PP.lastPaymentCount = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
        PP.initialized = true
        W112_SUMMONSCOUT_POSTPAY_OFFER_VERSION = POSTPAY_VERSION
    end
end)

frame:SetScript("OnUpdate", function()
    local t = ppNow()
    if t < (PP.nextPollAt or 0) then
        ppProcessPending()
        return
    end
    PP.nextPollAt = t + 0.20

    if not PP.initialized then
        ppSetDefaults()
        PP.lastPaymentCount = math.floor(tonumber(SummonScoutDB.paymentCount) or 0)
        PP.initialized = true
        W112_SUMMONSCOUT_POSTPAY_OFFER_VERSION = POSTPAY_VERSION
    end

    ppAttachGuiToggle()
    ppObserveLedger()
    ppProcessPending()
end)
