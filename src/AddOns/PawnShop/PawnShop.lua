-- PawnShop v0.1 for WoW 1.12.1 / build 5875.
-- Read-only appraisal over AuxVmangos/AUX economics. No automatic trade actions.

local PS_VERSION = "0.1-pawnshop"
local PS_WARM_MAX_AGE = 900
local PS_WHISPER_COOLDOWN = 3

local okInfo, auxInfo = pcall(require, "aux.util.info")
local okDe, auxDe = pcall(require, "aux.core.disenchant")
local okHistory, auxHistory = pcall(require, "aux.core.history")

local defaults = {
    enabled = true,
    advertise = false,
    adInterval = 300,
    sellerSharePct = 25,
    minOverVendorPct = 20,
    maxDePct = 80,
    tradeHaircutPct = 25,
    minHistorySamples = 3,
    adText = "Buying BoE greens & trade goods - whisper me an item link for an instant offer.",
}

local lastWhisper = {}
local nextAdIn = 5
local gui = nil
local fields = {}
local adButton = nil

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function round_silver(copper)
    copper = tonumber(copper) or 0
    if copper <= 0 then return 0 end
    return math.floor(copper / 100) * 100
end

local function money(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < 0 then copper = 0 end
    local g = math.floor(copper / 10000)
    local s = math.floor(math.mod(copper, 10000) / 100)
    local c = math.mod(copper, 100)
    if g > 0 then
        if c > 0 then return tostring(g) .. "g " .. tostring(s) .. "s " .. tostring(c) .. "c" end
        return tostring(g) .. "g " .. tostring(s) .. "s"
    end
    if s > 0 then
        if c > 0 then return tostring(s) .. "s " .. tostring(c) .. "c" end
        return tostring(s) .. "s"
    end
    return tostring(c) .. "c"
end

local function db_init()
    if type(PawnShopDB) ~= "table" then PawnShopDB = {} end
    for k,v in pairs(defaults) do
        if PawnShopDB[k] == nil then PawnShopDB[k] = v end
    end
    PawnShopDB.sellerSharePct = clamp(PawnShopDB.sellerSharePct, 0, 100)
    PawnShopDB.minOverVendorPct = clamp(PawnShopDB.minOverVendorPct, 0, 500)
    PawnShopDB.maxDePct = clamp(PawnShopDB.maxDePct, 1, 100)
    PawnShopDB.tradeHaircutPct = clamp(PawnShopDB.tradeHaircutPct, 0, 95)
    PawnShopDB.minHistorySamples = math.floor(clamp(PawnShopDB.minHistorySamples, 1, 11))
    PawnShopDB.adInterval = math.floor(clamp(PawnShopDB.adInterval, 60, 3600))
end

local function item_link_from_message(msg)
    msg = tostring(msg or "")
    local _,_,link = string.find(msg, "(|c%x%x%x%x%x%x%x%x|Hitem:[^|]+|h%[[^%]]+%]|h|r)")
    return link
end

local function parse_item_id(link)
    if okInfo and auxInfo and auxInfo.parse_link then
        local ok, a = pcall(auxInfo.parse_link, link)
        if ok and type(a) == "table" then
            return tonumber(a.item_id or a.itemId or a.id)
        elseif ok and tonumber(a) then
            return tonumber(a)
        end
    end
    local _,_,id = string.find(tostring(link or ""), "|Hitem:(%d+):")
    if not id then _,_,id = string.find(tostring(link or ""), "|Hitem:(%d+)|") end
    return tonumber(id)
end

local function item_key(link)
    if okInfo and auxInfo and auxInfo.item_key then
        local ok, key = pcall(auxInfo.item_key, link)
        if ok and key then return tostring(key) end
    end
    local id = parse_item_id(link)
    if id then return tostring(id) .. ":0" end
    return nil
end

local function is_boe(link)
    if not okInfo or not auxInfo or not auxInfo.tooltip or not auxInfo.tooltip_match then return false end
    local ok, tooltip = pcall(auxInfo.tooltip, "link", link)
    if not ok or type(tooltip) ~= "table" then return false end
    local bindText = ITEM_BIND_ON_EQUIP or "Binds when equipped"
    local okMatch, match = pcall(auxInfo.tooltip_match, bindText, tooltip)
    return okMatch and match and true or false
end

local function vendor_value(itemId)
    itemId = tonumber(itemId)
    if not itemId then return nil, "no-item-id" end
    local learned = 0
    if aux and aux.account_data and aux.account_data.merchant_sell then
        learned = tonumber(aux.account_data.merchant_sell[itemId]) or 0
    end
    if learned > 0 then return learned, "aux-learned" end
    local static = AVM_VENDOR_VALUES and tonumber(AVM_VENDOR_VALUES[itemId]) or 0
    if static > 0 then return static, "turtle-db" end
    return nil, "no-vendor-value"
end

local function de_distribution(itemId, equipLoc, quality, itemLevel)
    itemId = tonumber(itemId)
    if not itemId then return nil, "no-item-id" end
    if AVM_TURTLE_DISENCHANT_BLOCK and AVM_TURTLE_DISENCHANT_BLOCK[itemId] then
        return nil, "not-disenchantable"
    end
    if AVM_TURTLE_DISENCHANT_IDS then
        local deId = tonumber(AVM_TURTLE_DISENCHANT_IDS[itemId])
        if deId and deId > 0 then
            local dist = AVM_TURTLE_DISENCHANT_LOOT and AVM_TURTLE_DISENCHANT_LOOT[deId]
            if type(dist) == "table" and table.getn(dist) > 0 then return dist, "turtle-db" end
            return nil, "missing-turtle-loot"
        end
    end
    if not okDe or not auxDe or not auxDe.distribution then return nil, "de-module-unavailable" end
    local ok, dist = pcall(auxDe.distribution, equipLoc, quality, itemLevel or 0, itemId)
    if not ok or type(dist) ~= "table" or table.getn(dist) == 0 then return nil, "no-distribution" end
    return dist, "aux-fallback"
end

local function warm_material_floor(itemId)
    if type(AVM_DB) ~= "table" or type(AVM_DB.deWarmMaterialBook) ~= "table" then return nil end
    local row = AVM_DB.deWarmMaterialBook[tonumber(itemId)]
    if type(row) ~= "table" then return nil end
    local floor = tonumber(row.floor) or 0
    local seenAt = tonumber(row.seenAt) or 0
    local expectedDepth = tonumber(AVM_DB.deDepthUnits) or 3
    local rowDepth = tonumber(row.depth) or 0
    local now = type(time) == "function" and tonumber(time()) or 0
    if floor <= 0 or seenAt <= 0 or now <= 0 then return nil end
    if rowDepth ~= expectedDepth then return nil end
    local age = now - seenAt
    if age < 0 or age > PS_WARM_MAX_AGE then return nil end
    return floor
end

local function expected_de_value(itemId, equipLoc, quality, itemLevel)
    local dist, source = de_distribution(itemId, equipLoc, quality, itemLevel)
    if not dist then return nil, source end
    local cutPct = clamp(type(AVM_DB) == "table" and AVM_DB.deAhCutPct or 5, 0, 30)
    local expected = 0
    for i = 1, table.getn(dist) do
        local e = dist[i]
        local matId = tonumber(e and e.item_id)
        local floor = warm_material_floor(matId)
        if not floor then return nil, "material-price-missing:" .. tostring(matId or 0) end
        local probability = tonumber(e.probability) or 0
        local minQty = tonumber(e.min_quantity) or 0
        local maxQty = tonumber(e.max_quantity) or minQty
        local avgQty = (minQty + maxQty) / 2
        local netUnit = math.floor(floor * (100 - cutPct) / 100)
        expected = expected + probability * avgQty * netUnit
    end
    expected = math.floor(expected)
    if expected <= 0 then return nil, "no-de-value" end
    return expected, source
end

local function equipment_offer(link)
    local name, _, quality, itemLevel, _, itemType, _, _, equipLoc = GetItemInfo(link)
    if not name then return nil, "item-not-cached" end
    if tonumber(quality) ~= 2 then return nil, "not-green" end
    if not equipLoc or equipLoc == "" then return nil, "not-equipment" end
    if not is_boe(link) then return nil, "not-boe" end
    local id = parse_item_id(link)
    local vendor = vendor_value(id)
    if not vendor or vendor <= 0 then return nil, "vendor-missing" end
    local deValue, deSource = expected_de_value(id, equipLoc, quality, itemLevel)
    if not deValue then return nil, deSource end
    if deValue <= vendor then return nil, "de-not-above-vendor" end

    local share = vendor + math.floor((deValue - vendor) * PawnShopDB.sellerSharePct / 100)
    local vendorFloor = math.floor(vendor * (100 + PawnShopDB.minOverVendorPct) / 100)
    local cap = math.floor(deValue * PawnShopDB.maxDePct / 100)
    local offer = math.max(share, vendorFloor)
    if offer > cap then offer = cap end
    offer = round_silver(offer)
    if offer <= vendor or offer <= 0 then return nil, "offer-too-low" end
    return {
        kind = "equipment", name = name, offer = offer,
        deValue = deValue, vendor = vendor, deSource = deSource,
    }
end

local function trade_offer(link)
    local name, _, _, _, _, itemType = GetItemInfo(link)
    if not name then return nil, "item-not-cached" end
    if itemType ~= "Trade Goods" then return nil, "not-trade-goods" end
    if not okHistory or not auxHistory or not auxHistory.value or not auxHistory.data_points then
        return nil, "history-unavailable"
    end
    local key = item_key(link)
    if not key then return nil, "no-item-key" end
    local okPoints, points = pcall(auxHistory.data_points, key)
    if not okPoints or type(points) ~= "table" then return nil, "history-points-unavailable" end
    local samples = table.getn(points)
    if samples < PawnShopDB.minHistorySamples then return nil, "history-too-short" end
    local okValue, hist = pcall(auxHistory.value, key)
    hist = okValue and tonumber(hist) or nil
    if not hist or hist <= 0 then return nil, "history-no-value" end
    local offer = round_silver(math.floor(hist * (100 - PawnShopDB.tradeHaircutPct) / 100))
    if offer <= 0 then return nil, "offer-too-low" end
    return {
        kind = "trade", name = name, offer = offer,
        history = math.floor(hist), samples = samples,
    }
end

local function appraise(link)
    local trade, tradeReason = trade_offer(link)
    if trade then return trade end
    local equip, equipReason = equipment_offer(link)
    if equip then return equip end
    return nil, tostring(tradeReason or "") .. "/" .. tostring(equipReason or "")
end

local function whisper(target, text)
    if target and target ~= "" then SendChatMessage(text, "WHISPER", nil, target) end
end

local function handle_whisper(msg, sender)
    if not PawnShopDB or not PawnShopDB.enabled then return end
    local link = item_link_from_message(msg)
    if not link then return end
    sender = tostring(sender or "")
    if sender == "" then return end
    local now = tonumber(GetTime()) or 0
    local last = tonumber(lastWhisper[sender]) or -1000
    if now - last < PS_WHISPER_COOLDOWN then return end
    lastWhisper[sender] = now

    local result = appraise(link)
    if not result then
        whisper(sender, "PawnShop: I don't have reliable AUX data for that item yet.")
        return
    end
    if result.kind == "trade" then
        whisper(sender, "PawnShop: " .. link .. " history ~" .. money(result.history) .. "/ea (" .. tostring(result.samples) .. " samples); my offer " .. money(result.offer) .. "/ea. Tell me quantity if interested.")
    else
        whisper(sender, "PawnShop offer: " .. link .. " " .. money(result.offer) .. " (AUX DE " .. money(result.deValue) .. ", vendor " .. money(result.vendor) .. "). Trade me if interested.")
    end
end

local function world_channel_id()
    local id = GetChannelName("world")
    if tonumber(id) and tonumber(id) > 0 then return tonumber(id) end
    id = GetChannelName("World")
    if tonumber(id) and tonumber(id) > 0 then return tonumber(id) end
    return nil
end

local function send_ad()
    if not PawnShopDB or not PawnShopDB.advertise then return false end
    local id = world_channel_id()
    if not id then return false end
    SendChatMessage(tostring(PawnShopDB.adText or defaults.adText), "CHANNEL", nil, id)
    return true
end

local function label(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function make_field(parent, key, title, y, width)
    label(parent, title, 18, y)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetWidth(width or 70)
    e:SetHeight(20)
    e:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, y + 5)
    e:SetAutoFocus(false)
    fields[key] = e
    return e
end

local function gui_refresh()
    if not gui or not PawnShopDB then return end
    for key,e in pairs(fields) do
        e:SetText(tostring(PawnShopDB[key] or ""))
    end
    if adButton then
        adButton:SetText(PawnShopDB.advertise and "Advertising: ON" or "Advertising: OFF")
    end
end

local function gui_save()
    PawnShopDB.sellerSharePct = clamp(fields.sellerSharePct:GetText(), 0, 100)
    PawnShopDB.minOverVendorPct = clamp(fields.minOverVendorPct:GetText(), 0, 500)
    PawnShopDB.maxDePct = clamp(fields.maxDePct:GetText(), 1, 100)
    PawnShopDB.tradeHaircutPct = clamp(fields.tradeHaircutPct:GetText(), 0, 95)
    PawnShopDB.minHistorySamples = math.floor(clamp(fields.minHistorySamples:GetText(), 1, 11))
    PawnShopDB.adInterval = math.floor(clamp(fields.adInterval:GetText(), 60, 3600))
    nextAdIn = math.min(nextAdIn or PawnShopDB.adInterval, PawnShopDB.adInterval)
    gui_refresh()
    DEFAULT_CHAT_FRAME:AddMessage("PawnShop: settings saved.")
end

local function gui_create()
    if gui then return end
    gui = CreateFrame("Frame", "PawnShopFrame", UIParent)
    gui:SetWidth(360)
    gui:SetHeight(300)
    gui:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    gui:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    gui:SetMovable(true)
    gui:EnableMouse(true)
    gui:RegisterForDrag("LeftButton")
    gui:SetScript("OnDragStart", function() gui:StartMoving() end)
    gui:SetScript("OnDragStop", function() gui:StopMovingOrSizing() end)

    local title = gui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", gui, "TOP", 0, -16)
    title:SetText("PawnShop")
    local sub = gui:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("AUX-backed appraisal / no auto-trade")

    make_field(gui, "sellerSharePct", "Seller share of DE edge %", -65, 80)
    make_field(gui, "minOverVendorPct", "Minimum over vendor %", -95, 80)
    make_field(gui, "maxDePct", "Maximum of DE value %", -125, 80)
    make_field(gui, "tradeHaircutPct", "Trade Goods haircut %", -155, 80)
    make_field(gui, "minHistorySamples", "Min history samples", -185, 80)
    make_field(gui, "adInterval", "World ad interval (sec)", -215, 80)

    adButton = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
    adButton:SetWidth(125)
    adButton:SetHeight(22)
    adButton:SetPoint("BOTTOMLEFT", gui, "BOTTOMLEFT", 18, 18)
    adButton:SetScript("OnClick", function()
        PawnShopDB.advertise = not PawnShopDB.advertise
        nextAdIn = 2
        gui_refresh()
    end)

    local save = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
    save:SetWidth(80)
    save:SetHeight(22)
    save:SetPoint("BOTTOM", gui, "BOTTOM", 24, 18)
    save:SetText("Save")
    save:SetScript("OnClick", gui_save)

    local close = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
    close:SetWidth(70)
    close:SetHeight(22)
    close:SetPoint("BOTTOMRIGHT", gui, "BOTTOMRIGHT", -18, 18)
    close:SetText("Close")
    close:SetScript("OnClick", function() gui:Hide() end)

    gui:Hide()
end

local function gui_toggle()
    db_init()
    gui_create()
    gui_refresh()
    if gui:IsShown() then gui:Hide() else gui:Show() end
end

SLASH_PAWNSHOP1 = "/pawn"
SlashCmdList["PAWNSHOP"] = function(msg)
    msg = string.lower(tostring(msg or ""))
    if msg == "ad" then
        PawnShopDB.advertise = not PawnShopDB.advertise
        nextAdIn = 2
        DEFAULT_CHAT_FRAME:AddMessage("PawnShop advertising: " .. (PawnShopDB.advertise and "ON" or "OFF"))
        if gui then gui_refresh() end
        return
    end
    gui_toggle()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "PawnShop" then
        db_init()
        gui_create()
    elseif event == "PLAYER_LOGIN" then
        db_init()
        nextAdIn = 5
        DEFAULT_CHAT_FRAME:AddMessage("PawnShop " .. PS_VERSION .. " loaded. /pawn")
    elseif event == "CHAT_MSG_WHISPER" then
        handle_whisper(arg1, arg2)
    end
end)
frame:SetScript("OnUpdate", function()
    if not PawnShopDB or not PawnShopDB.advertise then return end
    local elapsed = tonumber(arg1) or 0
    nextAdIn = (tonumber(nextAdIn) or PawnShopDB.adInterval) - elapsed
    if nextAdIn <= 0 then
        send_ad()
        nextAdIn = PawnShopDB.adInterval
    end
end)
