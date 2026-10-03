-- AuxVmangos automatic purchase blacklist for WoW 1.12.1 / AUX.
-- Account-wide AVM SavedVariables; manual AUX purchases are intentionally untouched.

local aux = require 'aux'
local gui = require 'aux.gui'

AVM_BUY_BLACKLIST = AVM_BUY_BLACKLIST or {}
local BL = AVM_BUY_BLACKLIST
local SLOT_COUNT = 16
local rows = {}
local frame
local status
local syncing = false
local blockedRows = 0
local blockedTransactions = 0

local function trim(v)
	v = tostring(v or '')
	v = string.gsub(v, '^%s+', '')
	v = string.gsub(v, '%s+$', '')
	return v
end

local function normalize(v)
	return string.lower(trim(v))
end

local function ensure_db()
	AVM_DB = AVM_DB or {}
	if type(AVM_DB.buyBlacklist) ~= 'table' then AVM_DB.buyBlacklist = {} end
	return AVM_DB.buyBlacklist
end

local function record_item_id(record)
	if not record then return nil end
	local id = tonumber(record.itemId or record.item_id)
	if id then return id end
	local key = tostring(record.itemKey or record.item_key or record.itemstring or '')
	local _,_,text = string.find(key, 'item:(%d+)')
	return tonumber(text)
end

local function row_item_id(listType, index)
	if not GetAuctionItemLink then return nil end
	local link = GetAuctionItemLink(listType, index)
	local _,_,text = string.find(tostring(link or ''), 'item:(%d+)')
	return tonumber(text)
end

local function entry_matches(entry, name, itemId)
	entry = trim(entry)
	if entry == '' then return false end
	local id = tonumber(entry)
	if id then return itemId and tonumber(itemId) == id end
	return normalize(entry) == normalize(name)
end

local function is_blocked(record)
	if not record then return false end
	local db = ensure_db()
	local name = tostring(record.name or '')
	local itemId = record_item_id(record)
	for i = 1, SLOT_COUNT do
		if entry_matches(db[i], name, itemId) then return true, i end
	end
	return false
end

local function count_entries()
	local db = ensure_db()
	local n = 0
	for i = 1, SLOT_COUNT do if trim(db[i]) ~= '' then n = n + 1 end end
	return n
end

local function print_block(kind, name, itemId, slot)
	blockedTransactions = blockedTransactions + 1
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage('|cff60ff00[AVM]|r BLACKLIST BLOCK '..tostring(kind or 'BUY')..' '..tostring(name or '?')..' item='..tostring(itemId or '?')..' slot='..tostring(slot or '?'), 1, .35, .2)
	end
end

function BL.IsBlocked(record)
	return is_blocked(record)
end

function BL.Get(index)
	return ensure_db()[index]
end

function BL.Set(index, value)
	index = tonumber(index)
	if not index or index < 1 or index > SLOT_COUNT then return false end
	ensure_db()[index] = trim(value)
	return true
end

function BL.Count()
	return count_entries()
end

-- Filter AUX_ARB before any candidate is created. This is the normal path.
if AVM_AuxArbAuction and not BL._auctionFilterInstalled then
	local oldAuction = AVM_AuxArbAuction
	AVM_AuxArbAuction = function(record)
		local blocked = is_blocked(record)
		if blocked then
			blockedRows = blockedRows + 1
			return
		end
		return oldAuction(record)
	end
	BL._auctionFilterInstalled = true
end

-- Final transaction guard. A blacklist edit made after candidate selection must
-- still win. We only block when the live auction row matches AVM's automatic
-- candidate, so ordinary manual AUX purchases remain unaffected.
if PlaceAuctionBid and not BL._transactionGuardInstalled then
	local oldPlaceAuctionBid = PlaceAuctionBid
	PlaceAuctionBid = function(listType, index, amount)
		if listType == 'list' and AVM then
			local candidate = AVM.bidCandidate or AVM.candidate
			if candidate then
				local name = GetAuctionItemInfo and GetAuctionItemInfo(listType, index) or nil
				local itemId = row_item_id(listType, index)
				local candidateId = record_item_id(candidate)
				local same = false
				if candidateId and itemId then
					same = candidateId == itemId
				elseif name and candidate.name then
					same = normalize(name) == normalize(candidate.name)
				end
				if same then
					local blocked, slot = is_blocked(candidate)
					if blocked then
						print_block(candidate.mode == 'auxarb_bid' and 'BID' or 'BUY', candidate.name or name, candidateId or itemId, slot)
						return false
					end
				end
			end
		end
		return oldPlaceAuctionBid(listType, index, amount)
	end
	BL._transactionGuardInstalled = true
end

local tab = aux.tab 'Blacklist'
frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints()
frame:Hide()

local panel = gui.panel(frame)
panel:SetPoint('TOPLEFT', aux.frame.content, 'TOPLEFT', 0, 0)
panel:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

local title = panel:CreateFontString(nil, 'OVERLAY', 'GameFontNormalLarge')
title:SetPoint('TOPLEFT', panel, 'TOPLEFT', 16, -14)
title:SetText('Automatic Buy Blacklist')

local help = panel:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
help:SetPoint('TOPLEFT', panel, 'TOPLEFT', 16, -40)
help:SetWidth(690)
help:SetJustifyH('LEFT')
help:SetText('Exact item name or numeric item ID, one per row. Account-wide for every character. Blocks only AVM automatic BUY/BID; manual AUX purchases remain available.')

local function refresh_status()
	if not status then return end
	status:set_text('Blocked entries '..tostring(count_entries())..'/'..tostring(SLOT_COUNT)..' | filtered rows this session '..tostring(blockedRows)..' | transaction guards '..tostring(blockedTransactions))
end

local function refresh_rows()
	syncing = true
	local db = ensure_db()
	for i = 1, SLOT_COUNT do
		if rows[i] then rows[i]:SetText(tostring(db[i] or '')) end
	end
	syncing = false
	refresh_status()
end

local function save_row(index)
	if syncing or not rows[index] then return end
	BL.Set(index, rows[index]:GetText() or '')
	refresh_status()
end

for i = 1, SLOT_COUNT do
	local y = -72 - ((i - 1) * 22)
	local label = panel:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
	label:SetPoint('TOPLEFT', panel, 'TOPLEFT', 18, y - 3)
	label:SetWidth(22)
	label:SetJustifyH('RIGHT')
	label:SetText(tostring(i))

	local edit = CreateFrame('EditBox', 'AuxVmangosBuyBlacklistRow'..i, panel, 'InputBoxTemplate')
	edit:SetWidth(360)
	edit:SetHeight(20)
	edit:SetPoint('TOPLEFT', panel, 'TOPLEFT', 50, y)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(80)
	rows[i] = edit
	local rowIndex = i
	edit:SetScript('OnEnterPressed', function() save_row(rowIndex); this:ClearFocus() end)
	edit:SetScript('OnEditFocusLost', function() save_row(rowIndex) end)
end

local clear = gui.button(frame)
clear:SetWidth(90)
clear:SetHeight(24)
clear:SetPoint('TOPLEFT', panel, 'TOPLEFT', 435, -72)
clear:SetText('Clear all')
clear:SetScript('OnClick', function()
	local db = ensure_db()
	for i = 1, SLOT_COUNT do db[i] = '' end
	refresh_rows()
end)

local refresh = gui.button(frame)
refresh:SetWidth(90)
refresh:SetHeight(24)
refresh:SetPoint('TOPLEFT', panel, 'TOPLEFT', 435, -102)
refresh:SetText('Refresh')
refresh:SetScript('OnClick', function() refresh_rows() end)

local note = panel:CreateFontString(nil, 'OVERLAY', 'GameFontDisableSmall')
note:SetPoint('TOPLEFT', panel, 'TOPLEFT', 435, -142)
note:SetWidth(250)
note:SetJustifyH('LEFT')
note:SetText('Changes take effect immediately. If an auction was already selected for purchase, the final transaction guard still blocks it.')

status = gui.status_bar(frame)
status:SetWidth(690)
status:SetHeight(25)
status:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -6)
status:update_status(1, 1)
status:set_text('')

function tab.OPEN()
	refresh_rows()
	frame:Show()
end

function tab.CLOSE()
	frame:Hide()
end

refresh_rows()
