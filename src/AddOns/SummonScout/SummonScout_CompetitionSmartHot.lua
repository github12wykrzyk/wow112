-- Smart competitor classifier + rate-limit GUI bridge for SummonScout.
-- WoW 1.12.1 / Lua 5.0 compatible. This module does not replace the core
-- counter scheduler; it only recognizes additional high-confidence seller ads
-- and hands them to the existing scheduleCounter path, preserving its scope,
-- delay, dedupe and counterCooldown authority.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-smart-score-cooldown-gui"
local S = H.GetState("competitionsmart")
local MAX_UPVALUES = 64
local MAX_DEPTH = 12

local function csNow()
    if GetTime then return GetTime() end
    return 0
end

local function csTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function csNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return csTrim(s)
end

local function csPhrase(s, p)
    return string.find(" " .. s .. " ", " " .. p .. " ", 1, true) ~= nil
end

local function csTokenSignals(s)
    local travel = false
    local token
    for token in string.gfind(s, "%S+") do
        if token == "sum" or token == "tp" or token == "taxi"
            or string.sub(token, 1, 4) == "summ"
            or string.sub(token, 1, 4) == "port"
            or string.sub(token, 1, 4) == "tele" then
            travel = true
            break
        end
    end
    if not travel and string.find(s, "t%s+a%s+x%s+i") then travel = true end
    if not travel and string.find(s, "s%s+u%s+m%s+m") then travel = true end
    return travel
end

local function csSellerSignal(s)
    return csPhrase(s, "wts")
        or csPhrase(s, "selling")
        or csPhrase(s, "sell")
        or csPhrase(s, "service")
        or csPhrase(s, "available")
        or csPhrase(s, "offering")
        or csPhrase(s, "for sale")
        or csPhrase(s, "pst")
        or csPhrase(s, "whisper me")
        or csPhrase(s, "dm me")
        or csPhrase(s, "msg me")
end

local function csPriceSignal(s)
    return string.find(s, "%d+%s*g") ~= nil
        or csPhrase(s, "gold")
        or csPhrase(s, "tip")
        or csPhrase(s, "tips")
        or csPhrase(s, "fee")
        or csPhrase(s, "price")
        or csPhrase(s, "each")
end

local function csBuyerSignal(s)
    return csPhrase(s, "wtb")
        or csPhrase(s, "lf summon")
        or csPhrase(s, "lf summ")
        or csPhrase(s, "looking for")
        or csPhrase(s, "i need")
        or csPhrase(s, "need summon")
        or csPhrase(s, "need summ")
        or csPhrase(s, "can u")
        or csPhrase(s, "can you")
        or csPhrase(s, "could u")
        or csPhrase(s, "could you")
        or csPhrase(s, "where u")
        or csPhrase(s, "where can")
        or csPhrase(s, "how much")
        or csPhrase(s, "invite me")
        or csPhrase(s, "inv me")
end

local function csFallbackLocationCount(s)
    local cues = {
        "hyjal", "hydraxian", "waterlords", "waterlord", "azshara", "azsh",
        "winterspring", "everlook", "tanaris", "telabim", "tel abim",
    }
    local count = 0
    local seen = {}
    local i
    for i = 1, table.getn(cues) do
        local cue = cues[i]
        if not seen[cue] and csPhrase(s, cue) then
            seen[cue] = true
            count = count + 1
        end
    end
    return count
end

local function csFindNestedFunction(root, wanted, depth, seen)
    if type(root) ~= "function" or depth > MAX_DEPTH then return nil end
    if not debug or type(debug.getupvalue) ~= "function" then return nil end
    seen = seen or {}
    if seen[root] then return nil end
    seen[root] = true

    local i
    for i = 1, MAX_UPVALUES do
        local name, value = debug.getupvalue(root, i)
        if not name then break end
        if name == wanted and type(value) == "function" then return value end
    end
    for i = 1, MAX_UPVALUES do
        local name, value = debug.getupvalue(root, i)
        if not name then break end
        if type(value) == "function" then
            local found = csFindNestedFunction(value, wanted, depth + 1, seen)
            if found then return found end
        end
    end
    return nil
end

local function csResolveCoreHelpers()
    local root = W112_SUMMONSCOUT_CORE_BASE_ON_EVENT
    if type(root) ~= "function" and SummonScoutFrame and SummonScoutFrame.GetScript then
        root = SummonScoutFrame:GetScript("OnEvent")
    end
    if type(root) ~= "function" then return false end

    S.scheduleCounter = csFindNestedFunction(root, "scheduleCounter", 0, {})
    S.findLocations = csFindNestedFunction(root, "findLocationsInMessage", 0, {})
    S.helpersResolvedAt = csNow()
    return type(S.scheduleCounter) == "function"
end

local function csLocationCount(s)
    if type(S.findLocations) == "function" then
        local ok, result
        if pcall then
            ok, result = pcall(S.findLocations, s)
            if ok and type(result) == "table" then return table.getn(result) end
        else
            result = S.findLocations(s)
            if type(result) == "table" then return table.getn(result) end
        end
    end
    return csFallbackLocationCount(s)
end

local function csClassify(message)
    local raw = tostring(message or "")
    local s = csNormalize(raw)
    if s == "" then return false, 0, "empty" end

    local travel = csTokenSignals(s)
    local seller = csSellerSignal(s)
    local price = csPriceSignal(s)
    local buyer = csBuyerSignal(s)
    local locationCount = csLocationCount(s)
    local score = 0
    local reasons = {}

    if travel then score = score + 3; reasons[table.getn(reasons) + 1] = "travel" end
    if seller then score = score + 4; reasons[table.getn(reasons) + 1] = "seller" end
    if price then score = score + 3; reasons[table.getn(reasons) + 1] = "price" end
    if locationCount > 0 then score = score + 2; reasons[table.getn(reasons) + 1] = "dest" .. tostring(locationCount) end
    if locationCount > 1 then score = score + 1 end

    -- Buyer-like wording is rejected unless the same line contains an explicit
    -- seller/CTA marker. This keeps "can u summon me?" and "need Hyjal" out,
    -- while still accepting ads such as "Need a summon? 5g, PST".
    if buyer and not seller then return false, score, "buyer" end

    local qualified = false
    if seller and travel then qualified = true end
    if seller and locationCount > 0 then qualified = true end
    if price and travel and locationCount > 0 then qualified = true end
    if price and travel and score >= 6 and not buyer then qualified = true end
    if locationCount >= 2 and (seller or travel or price) then qualified = true end

    if not qualified or score < 6 then
        return false, score, table.concat(reasons, "+")
    end
    return true, score, table.concat(reasons, "+")
end

local function csSameAsOwnAdvert(message)
    local own = csNormalize(SummonScoutDB and SummonScoutDB.spamMessage or "")
    return own ~= "" and csNormalize(message) == own
end

local function csSetCooldownFromEdit()
    if not S.cooldownEdit then return end
    local seconds = tonumber(csTrim(S.cooldownEdit:GetText() or ""))
    if not seconds or seconds < 15 or seconds > 3600 then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r counter interval must be 15-3600 seconds")
        end
        S.cooldownEdit:SetText(tostring((SummonScoutDB and SummonScoutDB.counterCooldown) or 60))
        return
    end
    SummonScoutDB.counterCooldown = math.floor(seconds)
    S.cooldownEdit:SetText(tostring(SummonScoutDB.counterCooldown))
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r competitor response min interval -> "
            .. tostring(SummonScoutDB.counterCooldown) .. "s")
    end
end

local function csAttachGui()
    if S.guiAttached then return true end
    local f = getglobal and getglobal("SummonScoutOptionsFrame") or nil
    if not f then return false end

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", f, "TOPLEFT", 190, -226)
    label:SetText("Min interval:")

    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetWidth(42)
    edit:SetHeight(20)
    edit:SetPoint("TOPLEFT", f, "TOPLEFT", 260, -219)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(4)
    edit:SetText(tostring((SummonScoutDB and SummonScoutDB.counterCooldown) or 60))
    edit:SetScript("OnEnterPressed", function() csSetCooldownFromEdit(); edit:ClearFocus() end)
    edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)

    local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    button:SetWidth(42)
    button:SetHeight(20)
    button:SetPoint("TOPLEFT", f, "TOPLEFT", 306, -219)
    button:SetText("Set")
    button:SetScript("OnClick", csSetCooldownFromEdit)

    S.cooldownLabel = label
    S.cooldownEdit = edit
    S.cooldownButton = button
    S.guiAttached = true
    return true
end

local M = {}

function M.Init()
    SummonScoutDB = SummonScoutDB or {}
    if SummonScoutDB.counterCooldown == nil then SummonScoutDB.counterCooldown = 60 end
    S.nextHelperProbe = 0
    S.nextGuiProbe = 0
    csResolveCoreHelpers()
    csAttachGui()
    H.RegisterEvent("CHAT_MSG_CHANNEL")
    H.RegisterEvent("CHAT_MSG_YELL")
    H.RegisterEvent("CHAT_MSG_SAY")
end

function M.OnEvent(evt, message, sender)
    if evt ~= "CHAT_MSG_CHANNEL" and evt ~= "CHAT_MSG_YELL" and evt ~= "CHAT_MSG_SAY" then return end
    if not SummonScoutDB or not SummonScoutDB.counterEnabled then return end
    if csTrim(SummonScoutDB.spamMessage or "") == "" then return end
    if csSameAsOwnAdvert(message) then return end

    local me = UnitName and UnitName("player") or ""
    if me ~= "" and string.lower(tostring(sender or "")) == string.lower(me) then return end

    local qualified, score, reasons = csClassify(message)
    S.lastScore = score
    S.lastReasons = reasons
    S.lastMessage = tostring(message or "")
    S.lastSender = tostring(sender or "")
    if not qualified then return end

    S.detections = (tonumber(S.detections) or 0) + 1
    if type(S.scheduleCounter) ~= "function" and not csResolveCoreHelpers() then
        S.lastStatus = "scheduler-unavailable"
        return
    end

    local ok, err = true, nil
    if pcall then
        ok, err = pcall(S.scheduleCounter, sender, message, nil, false)
    else
        S.scheduleCounter(sender, message, nil, false)
    end
    if ok then
        S.lastStatus = "scheduled-or-deduped"
        S.lastQualifiedAt = csNow()
    else
        S.lastStatus = "scheduler-error: " .. tostring(err or "?")
    end
end

function M.OnUpdate(elapsed)
    local t = csNow()
    if (tonumber(S.nextHelperProbe) or 0) <= t and type(S.scheduleCounter) ~= "function" then
        S.nextHelperProbe = t + 3
        csResolveCoreHelpers()
    end
    if not S.guiAttached and (tonumber(S.nextGuiProbe) or 0) <= t then
        S.nextGuiProbe = t + 1
        csAttachGui()
    end
end

function M.Shutdown()
    -- Controls are owned by the stable options frame. Hide old generation
    -- controls before the replacement generation attaches fresh closures.
    if S.cooldownLabel then S.cooldownLabel:Hide() end
    if S.cooldownEdit then S.cooldownEdit:Hide() end
    if S.cooldownButton then S.cooldownButton:Hide() end
    S.cooldownLabel = nil
    S.cooldownEdit = nil
    S.cooldownButton = nil
    S.guiAttached = false
end

H.Register("competitionsmart", M, VERSION)
W112_SUMMONSCOUT_COMPETITION_SMART_VERSION = VERSION
