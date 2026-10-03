-- Native AUX item blacklist for WoW 1.12.1.
-- The blacklist is account-wide (AVM_DB SavedVariables), exact-name and case-insensitive.
-- Blacklisted rows still feed DE material pricing, but are made ineligible for
-- AUX_ARB vendor/DE/flip/stack/bid candidate creation.

local aux = require 'aux'
local gui = require 'aux.gui'

AVM_AUX_BLACKLIST = AVM_AUX_BLACKLIST or {}

local ROWS_PER_PAGE = 14
local frame
local panel
local input
local status
local rows = {}
local page = 1

local function trim(text)
	text = tostring(text or '')
	text = string.gsub(text, '^%s+', '')
	text = string.gsub(text, '%s+$', '')
	return text
end

local function clean_name(text)
	text = trim(text)
	if string.find(text, '|Hitem:', 1, true) then
		local _,_,linked = string.find(text, '%[(.-)%]')
		if linked and linked ~= '' then text = linked end
	end
	return trim(text)
end

local function blacklist_key(name)
	name = clean_name(name)
	if name == '' then return '' end
	return string.lower(name)
end

local function ensure_db()
	if not AVM_DB then AVM_DB = {} end
	if type(AVM_DB.blacklist) ~= 'table' then AVM_DB.blacklist = {} end
	if tonumber(AVM_DB.blacklistSchema) ~= 1 then
		local normalized = {}
		for k,v in pairs(AVM_DB.blacklist) do
			local name
			if type(k) == 'number' then
				name = clean_name(v)
			elseif v == true then
				name = clean_name(k)
			else
				name = clean_name(v)
				if name == '' then name = clean_name(k) end
			end
			local key = blacklist_key(name)
			if key ~= '' then normalized[key] = name end
		end
		AVM_DB.blacklist = normalized
		AVM_DB.blacklistSchema = 1
	end
	return AVM_DB.blacklist
end

function AVM_IsBlacklistedItem(name)
	local key = blacklist_key(name)
	if key == '' then return false end
	return ensure_db()[key] ~= nil
end

local function runtime_same_name(row, key)
	return row and blacklist_key(row.name) == key
end

local function filter_runtime_list(list, key)
	local out = {}
	for i = 1, table.getn(list or {}) do
		local row = list[i]
		if not runtime_same_name(row, key) then table.insert(out, row) end
	end
	return out
end

local function purge_not_yet_committed(name)
	local key = blacklist_key(name)
	if key == '' or not AVM or not AVM.auxArb then return end
	local a = AVM.auxArb

	local fields = {
		'pageBest','bestSeen','deReadyPageBest','deBest','flipBest','stackBest',
		'bidVendorBest','bidBest','postscanCandidate'
	}
	for i = 1, table.getn(fields) do
		local field = fields[i]
		if runtime_same_name(a[field], key) then a[field] = nil end
	end
	a.deRawCandidates = filter_runtime_list(a.deRawCandidates, key)
	a.dePageRawCandidates = filter_runtime_list(a.dePageRawCandidates, key)
	a.bidDeRawCandidates = filter_runtime_list(a.bidDeRawCandidates, key)
	for bookKey,row in pairs(a.flipBook or {}) do
		if runtime_same_name(row, key) then a.flipBook[bookKey] = nil end
	end

	-- Never mutate a purchase/bid already sent to the server. For all candidates
	-- still only accumulated in the scan, removal above makes the blacklist take
	-- effect immediately and the next evaluation cannot select them again.
end

local function add_item(name)
	name = clean_name(name)
	local key = blacklist_key(name)
	if key == '' then return false end
	local db = ensure_db()
	db[key] = name
	purge_not_yet_committed(name)
	if AVM then AVM.uiGeneration = (tonumber(AVM.uiGeneration) or 0) + 1 end
	return true
end

local function remove_item(name)
	local key = blacklist_key(name)
	if key == '' then return false end
	local db = ensure_db()
	if db[key] == nil then return false end
	db[key] = nil
	if AVM then AVM.uiGeneration = (tonumber(AVM.uiGeneration) or 0) + 1 end
	return true
end

local function sorted_items()
	local out = {}
	for _,name in pairs(ensure_db()) do table.insert(out, tostring(name)) end
	table.sort(out, function(a,b) return string.lower(a) < string.lower(b) end)
	return out
end

AVM_AUX_BLACKLIST.Add = add_item
AVM_AUX_BLACKLIST.Remove = remove_item
AVM_AUX_BLACKLIST.Contains = AVM_IsBlacklistedItem
AVM_AUX_BLACKLIST.Items = sorted_items

-- Keep DE material price discovery intact: pass the row to the existing engine,
-- but shadow purchase-relevant identity fields so every AUX_ARB purchase route
-- rejects the row. This avoids duplicating the core valuation pipeline here.
if AVM_AuxArbAuction and not AVM_AUX_BLACKLIST.auctionHookInstalled then
	local oldAuxArbAuction = AVM_AuxArbAuction
	AVM_AuxArbAuction = function(record)
		if record and AVM_IsBlacklistedItem(record.name) then
			local shadow = {}
			for k,v in pairs(record) do shadow[k] = v end
			shadow.quality = 0
			shadow.owner = UnitName('player')
			return oldAuxArbAuction(shadow)
		end
		return oldAuxArbAuction(record)
	end
	AVM_AUX_BLACKLIST.auctionHookInstalled = true
end

local function make_label(parent, text, x, y, width)
	local fs = parent:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
	fs:SetPoint('TOPLEFT', parent, 'TOPLEFT', x, y)
	fs:SetWidth(width)
	fs:SetJustifyH('LEFT')
	fs:SetText(text or '')
	return fs
end

local function refresh()
	if not frame then return end
	local items = sorted_items()
	local count = table.getn(items)
	local pages = math.max(1, math.ceil(count / ROWS_PER_PAGE))
	if page > pages then page = pages end
	if page < 1 then page = 1 end
	local first = ((page - 1) * ROWS_PER_PAGE) + 1

	for i = 1, ROWS_PER_PAGE do
		local row = rows[i]
		local name = items[first + i - 1]
		row.name = name
		if name then
			row.label:SetText(name)
			row.remove:Show()
		else
			row.label:SetText('')
			row.remove:Hide()
		end
	end
	status:SetText('Blacklisted '..tostring(count)..' | page '..tostring(page)..'/'..tostring(pages)..' | exact item names, case-insensitive')
end

local tab = aux.tab 'Blacklist'
frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints()
frame:Hide()

panel = gui.panel(frame)
panel:SetPoint('TOP', frame, 'TOP', 0, -8)
panel:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
panel:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

make_label(panel, 'Never auto-buy these items (Vendor / DE / Flip / Stack / Bid)', 18, -18, 560)

input = CreateFrame('EditBox', nil, panel, 'InputBoxTemplate')
input:SetWidth(360)
input:SetHeight(20)
input:SetPoint('TOPLEFT', panel, 'TOPLEFT', 20, -48)
input:SetAutoFocus(false)
input:SetMaxLetters(120)

local add = gui.button(panel)
add:SetWidth(70)
add:SetHeight(22)
add:SetPoint('LEFT', input, 'RIGHT', 8, 0)
add:SetText('Add')

local function add_from_input()
	if add_item(input:GetText()) then
		input:SetText('')
		page = 1
		refresh()
	end
	input:ClearFocus()
end

add:SetScript('OnClick', add_from_input)
input:SetScript('OnEnterPressed', add_from_input)
input:SetScript('OnEscapePressed', function() input:ClearFocus() end)

make_label(panel, 'Item', 20, -82, 500)
for i = 1, ROWS_PER_PAGE do
	local y = -102 - ((i - 1) * 23)
	local row = {}
	rows[i] = row
	row.label = make_label(panel, '', 20, y, 470)
	row.remove = gui.button(panel)
	row.remove:SetWidth(75)
	row.remove:SetHeight(20)
	row.remove:SetPoint('TOPLEFT', panel, 'TOPLEFT', 510, y + 4)
	row.remove:SetText('Remove')
	row.remove:SetScript('OnClick', function()
		if row.name then remove_item(row.name) end
		refresh()
	end)
	row.remove:Hide()
end

local prev = gui.button(panel)
prev:SetWidth(60)
prev:SetHeight(22)
prev:SetPoint('BOTTOMLEFT', panel, 'BOTTOMLEFT', 20, 12)
prev:SetText('Prev')
prev:SetScript('OnClick', function()
	if page > 1 then page = page - 1 end
	refresh()
end)

local next = gui.button(panel)
next:SetWidth(60)
next:SetHeight(22)
next:SetPoint('LEFT', prev, 'RIGHT', 6, 0)
next:SetText('Next')
next:SetScript('OnClick', function()
	page = page + 1
	refresh()
end)

status = panel:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
status:SetPoint('LEFT', next, 'RIGHT', 12, 0)
status:SetWidth(520)
status:SetJustifyH('LEFT')
status:SetText('')

function tab.OPEN()
	frame:Show()
	refresh()
end

function tab.CLOSE()
	frame:Hide()
end

ensure_db()
