-- AuxVmangos 0.8 WATCH GUI for WoW 1.12.1.
-- Presentation only: all scanner/purchase state transitions remain owned by AuxVmangos.lua.

AVM_WATCH_UI = AVM_WATCH_UI or {}

local API = AVM_WATCH_API
if not API then
	return
end

local SLOT_COUNT = API.Init() or 16
local rows = {}
local panel
local launcher
local statusText
local scanButton
local liveButton
local lastStatusAt = 0

local function compact_money(copper)
	copper = tonumber(copper) or 0
	if copper <= 0 then return "0" end
	local g = math.floor(copper / 10000)
	local s = math.floor((copper - g * 10000) / 100)
	local c = mod(copper, 100)
	local out = ""
	if g > 0 then out = out .. tostring(g) .. "g" end
	if s > 0 then out = out .. tostring(s) .. "s" end
	if c > 0 then out = out .. tostring(c) .. "c" end
	return out
end

local function new_label(parent, text, x, y, width)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	fs:SetWidth(width or 80)
	fs:SetJustifyH("LEFT")
	fs:SetText(text or "")
	return fs
end

local function new_edit(parent, name, x, y, width)
	local e = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
	e:SetWidth(width)
	e:SetHeight(20)
	e:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	e:SetAutoFocus(false)
	e:SetMaxLetters(60)
	return e
end

local function row_from_db(index)
	local r = API.GetRule(index)
	if not r then return end
	local ui = rows[index]
	if not ui then return end
	ui.enabled:SetChecked(r.enabled == true)
	ui.item:SetText(r.name or "")
	ui.partial:SetChecked(r.partial == true)
	ui.unit:SetText(compact_money(r.maxUnit or 0))
	ui.total:SetText(compact_money(r.maxTotal or 0))
	ui.minStack:SetText(tostring(r.minStack or 1))
	ui.maxStack:SetText(tostring(r.maxStack or 0))
end

local function commit_row(index)
	local ui = rows[index]
	local old = API.GetRule(index)
	if not ui or not old then return end
	local maxUnit = API.ParseMoney(ui.unit:GetText() or "")
	local maxTotal = API.ParseMoney(ui.total:GetText() or "")
	local minStack = tonumber(ui.minStack:GetText() or "")
	local maxStack = tonumber(ui.maxStack:GetText() or "")
	if maxUnit == nil then maxUnit = old.maxUnit or 0 end
	if maxTotal == nil then maxTotal = old.maxTotal or 0 end
	if not minStack or minStack < 1 then minStack = old.minStack or 1 end
	if not maxStack or maxStack < 0 then maxStack = old.maxStack or 0 end

	API.SetRule(index, {
		enabled = ui.enabled:GetChecked() and true or false,
		name = ui.item:GetText() or "",
		partial = ui.partial:GetChecked() and true or false,
		maxUnit = maxUnit,
		maxTotal = maxTotal,
		minStack = minStack,
		maxStack = maxStack,
	})
	row_from_db(index)
end

local function refresh_rows()
	for i = 1, SLOT_COUNT do row_from_db(i) end
end

local function refresh_status()
	if not statusText then return end
	local s = API.GetState()
	if not s then return end
	if scanButton then
		scanButton:SetText(s.enabled and "Scanner: ON" or "Scanner: OFF")
	end
	if liveButton then
		liveButton:SetText(s.live and "LIVE: ON" or "LIVE: OFF")
	end
	local best = "none"
	if (s.bestUnit or 0) > 0 then best = compact_money(s.bestUnit) .. "/ea" end
	statusText:SetText(
		"phase=" .. tostring(s.phase) ..
		" | active=" .. tostring(s.activeRules) ..
		" | slot=" .. tostring(s.ruleIndex) ..
		" " .. tostring(s.ruleName or "") ..
		" | page=" .. tostring(s.scanPage) ..
		" | scanned=" .. tostring(s.scannedPages) ..
		" | best=" .. best ..
		" | buys=" .. tostring(s.sessionBuys) .. "/" .. tostring(s.maxSessionBuys) ..
		" | spent=" .. compact_money(s.sessionSpend)
	)
end

local function create_panel()
	if panel then return end

	panel = CreateFrame("Frame", "AuxVmangosWatchPanel", UIParent)
	panel:SetWidth(760)
	panel:SetHeight(454)
	panel:SetPoint("CENTER", UIParent, "CENTER", 0, 10)
	panel:SetFrameStrata("DIALOG")
	panel:EnableMouse(true)
	panel:SetMovable(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function() this:StartMoving() end)
	panel:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	panel:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 24,
		insets = { left = 8, right = 8, top = 8, bottom = 8 }
	})
	panel:Hide()

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -16)
	title:SetText("AuxVmangos WATCH - best price per unit")

	scanButton = CreateFrame("Button", "AuxVmangosWatchScanButton", panel, "GameMenuButtonTemplate")
	scanButton:SetWidth(105)
	scanButton:SetHeight(24)
	scanButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 330, -12)
	scanButton:SetScript("OnClick", function()
		local s = API.GetState()
		API.SetScanner(not (s and s.enabled))
		refresh_status()
	end)

	liveButton = CreateFrame("Button", "AuxVmangosWatchLiveButton", panel, "GameMenuButtonTemplate")
	liveButton:SetWidth(95)
	liveButton:SetHeight(24)
	liveButton:SetPoint("LEFT", scanButton, "RIGHT", 8, 0)
	liveButton:SetScript("OnClick", function()
		local s = API.GetState()
		local want = not (s and s.live)
		local ok = API.SetLive(want)
		if want and not ok then
			DEFAULT_CHAT_FRAME:AddMessage("|cff60ff00[AVM]|r LIVE blocked: open AH, stop MARKET and configure at least one active rule.", 1, 0.4, 0.2)
		end
		refresh_status()
	end)

	local refreshButton = CreateFrame("Button", "AuxVmangosWatchRefreshButton", panel, "GameMenuButtonTemplate")
	refreshButton:SetWidth(80)
	refreshButton:SetHeight(24)
	refreshButton:SetPoint("LEFT", liveButton, "RIGHT", 8, 0)
	refreshButton:SetText("Refresh")
	refreshButton:SetScript("OnClick", function() refresh_rows(); refresh_status() end)

	local closeButton = CreateFrame("Button", "AuxVmangosWatchCloseButton", panel, "GameMenuButtonTemplate")
	closeButton:SetWidth(70)
	closeButton:SetHeight(24)
	closeButton:SetPoint("LEFT", refreshButton, "RIGHT", 8, 0)
	closeButton:SetText("Close")
	closeButton:SetScript("OnClick", function() panel:Hide() end)

	new_label(panel, "#", 14, -52, 20)
	new_label(panel, "ON", 34, -52, 30)
	new_label(panel, "Item", 72, -52, 205)
	new_label(panel, "Partial", 288, -52, 46)
	new_label(panel, "Max/unit *", 350, -52, 80)
	new_label(panel, "Max total", 444, -52, 78)
	new_label(panel, "Min", 540, -52, 42)
	new_label(panel, "Max", 602, -52, 42)

	for i = 1, SLOT_COUNT do
		local y = -70 - ((i - 1) * 21)
		local ui = {}
		rows[i] = ui

		ui.number = new_label(panel, tostring(i), 14, y - 3, 20)

		ui.enabled = CreateFrame("CheckButton", "AuxVmangosWatchEnabled" .. i, panel, "OptionsCheckButtonTemplate")
		ui.enabled:SetWidth(22)
		ui.enabled:SetHeight(22)
		ui.enabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, y + 1)

		ui.item = new_edit(panel, "AuxVmangosWatchItem" .. i, 72, y, 205)

		ui.partial = CreateFrame("CheckButton", "AuxVmangosWatchPartial" .. i, panel, "OptionsCheckButtonTemplate")
		ui.partial:SetWidth(22)
		ui.partial:SetHeight(22)
		ui.partial:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, y + 1)

		ui.unit = new_edit(panel, "AuxVmangosWatchUnit" .. i, 350, y, 78)
		ui.total = new_edit(panel, "AuxVmangosWatchTotal" .. i, 444, y, 78)
		ui.minStack = new_edit(panel, "AuxVmangosWatchMin" .. i, 540, y, 42)
		ui.maxStack = new_edit(panel, "AuxVmangosWatchMax" .. i, 602, y, 42)

		ui.enabled:SetScript("OnClick", function() commit_row(i) end)
		ui.partial:SetScript("OnClick", function() commit_row(i) end)

		local function bind_edit(edit)
			edit:SetScript("OnEnterPressed", function() this:ClearFocus(); commit_row(i) end)
			edit:SetScript("OnEditFocusLost", function() commit_row(i) end)
		end
		bind_edit(ui.item)
		bind_edit(ui.unit)
		bind_edit(ui.total)
		bind_edit(ui.minStack)
		bind_edit(ui.maxStack)
	end

	local help = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	help:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 35)
	help:SetWidth(720)
	help:SetJustifyH("LEFT")
	help:SetText("Max/unit is required. Money: 4g50s, 18s, 25c. Max total=0 and Max=0 mean unlimited. Any rule edit disarms LIVE.")

	statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statusText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 18)
	statusText:SetWidth(720)
	statusText:SetJustifyH("LEFT")
	statusText:SetText("")

	panel:SetScript("OnUpdate", function()
		if GetTime() - lastStatusAt >= 0.25 then
			lastStatusAt = GetTime()
			refresh_status()
		end
	end)

	refresh_rows()
	refresh_status()
end

local function create_launcher()
	if launcher then return end
	launcher = CreateFrame("Button", "AuxVmangosWatchLauncher", UIParent, "GameMenuButtonTemplate")
	launcher:SetWidth(92)
	launcher:SetHeight(24)
	launcher:SetText("AVM WATCH")
	launcher:SetFrameStrata("DIALOG")
	launcher:SetScript("OnClick", function() AVM_WATCH_UI.Toggle() end)
	launcher:Hide()
end

function AVM_WATCH_UI.Toggle()
	create_panel()
	if panel:IsShown() then
		panel:Hide()
	else
		refresh_rows()
		refresh_status()
		panel:Show()
	end
end

local eventFrame = CreateFrame("Frame", "AuxVmangosWatchUIEvent")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:SetScript("OnEvent", function()
	if event == "AUCTION_HOUSE_SHOW" then
		create_launcher()
		launcher:ClearAllPoints()
		if AuctionFrame then
			launcher:SetPoint("TOPRIGHT", AuctionFrame, "TOPRIGHT", -70, -38)
		else
			launcher:SetPoint("TOP", UIParent, "TOP", 0, -70)
		end
		launcher:Show()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		if launcher then launcher:Hide() end
		if panel then panel:Hide() end
	end
end)
