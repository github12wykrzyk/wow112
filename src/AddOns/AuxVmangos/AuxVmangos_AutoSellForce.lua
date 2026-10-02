-- Manual AutoSell price sweep/decision controller for WoW 1.12.1 / AUX.
-- Intentionally requires Auto Loop OFF. It serializes exact item probes, applies
-- the existing AutoSell trigger/floor policy, and queues safe cancellations.

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local gui = require 'aux.gui'
local scan = require 'aux.core.scan'
local scan_util = require 'aux.util.scan'
local history = require 'aux.core.history'

AVM_AUTOSELL_FORCE = AVM_AUTOSELL_FORCE or {}
local F = AVM_AUTOSELL_FORCE
local AS = AVM_AUTOSELL
local bridge = AVM_OWNER_SCAN_BRIDGE
local baseAuxFastIsBusy = AUXFAST_IsBusy

F.owner = F.owner or {}
F.ownerAt = tonumber(F.ownerAt) or 0
F.busy = false
F.waitOwner = false
F.waitOwnerAt = 0
F.phase = 'idle'
F.queue = {}
F.index = 0
F.candidates = {}
F.cancelIndex = 0
F.results = {}
F.checked = 0
F.undercut = 0
F.floorBlocked = 0
F.cancelled = 0
F.failed = 0
F.message = 'Ready'

local function epoch()
	if type(time) == 'function' then return time() end
	return 0
end

local function ensure_db()
	AVM_DB = AVM_DB or {}
	AVM_DB.autoSellPending = AVM_DB.autoSellPending or {}
	AVM_DB.autoSellStats = AVM_DB.autoSellStats or { cancels = 0, reposts = 0, probes = 0 }
	AVM_DB.autoSellForceResults = AVM_DB.autoSellForceResults or {}
end

local function auction_open()
	return AuctionFrame and AuctionFrame.IsVisible and AuctionFrame:IsVisible()
end

local function loop_enabled()
	return AVM_DB and AVM_DB.auxLoopEnabled and true or false
end

local function base_auxfast_busy()
	if not baseAuxFastIsBusy then return false end
	local ok, busy = pcall(baseAuxFastIsBusy)
	return ok and busy and true or false
end

-- AutoSell already respects AUXFAST_IsBusy. Extend that contract only while the
-- explicit manual sweep owns the shared AUX scanner; no scheduler/preemption is added.
if not F._busyHookInstalled then
	AUXFAST_IsBusy = function()
		if F.busy then return true end
		return base_auxfast_busy()
	end
	F._busyHookInstalled = true
end

local function set_message(text)
	F.message = tostring(text or '')
end

local function copy_owner_record(record, page, index)
	return {
		item_id = tonumber(record and record.item_id) or 0,
		item_key = tostring(record and record.item_key or ''),
		name = tostring(record and record.name or ''),
		aux_quantity = tonumber(record and record.aux_quantity) or tonumber(record and record.count) or 0,
		buyout_price = tonumber(record and record.buyout_price) or 0,
		unit_buyout_price = tonumber(record and record.unit_buyout_price) or 0,
		start_price = tonumber(record and record.start_price) or 0,
		high_bid = tonumber(record and record.high_bid) or 0,
		high_bidder = record and record.high_bidder,
		duration = tonumber(record and record.duration) or 0,
		search_signature = tostring(record and record.search_signature or ''),
		page = tonumber(page) or tonumber(record and record.page) or 0,
		index = tonumber(index) or tonumber(record and record.index) or 0,
		query_type = 'owner',
		blizzard_query = { first_page = tonumber(page) or tonumber(record and record.page) or 0,
			last_page = tonumber(page) or tonumber(record and record.page) or 0 },
	}
end

local start_sweep

local function capture_owner_records(records)
	local rows = {}
	if records then
		for i = 1, table.getn(records) do
			local record = records[i]
			if record then table.insert(rows, copy_owner_record(record, record.page, record.index or i)) end
		end
	end
	F.owner = rows
	F.ownerAt = GetTime()
	if F.waitOwner then
		F.waitOwner = false
		F.waitOwnerAt = 0
		start_sweep()
	end
end

if bridge and bridge.FeedAutoSellOwnerRecords and not F._ownerHookInstalled then
	local oldFeed = bridge.FeedAutoSellOwnerRecords
	bridge.FeedAutoSellOwnerRecords = function(records)
		capture_owner_records(records)
		return oldFeed(records)
	end
	F._ownerHookInstalled = true
end

local function capture_current_owner_page()
	if not auction_open() then return false end
	local page = aux.current_owner_page and tonumber(aux.current_owner_page()) or 0
	local count, total = GetNumAuctionItems('owner')
	count = tonumber(count) or 0
	total = tonumber(total) or count
	if page ~= 0 or total > 50 then return false end
	local rows = {}
	for i = 1, count do
		local record = info.auction(i, 'owner')
		if record then
			table.insert(rows, copy_owner_record(record, 0, i))
			T.release(record)
		end
	end
	F.owner = rows
	F.ownerAt = GetTime()
	return true
end

local function purchase_match(h, key, itemId)
	if not h then return false end
	local hk = tostring(h.itemKey or '')
	if hk ~= '' and key ~= '' then return hk == key end
	return tonumber(h.itemId) == tonumber(itemId)
end

local function purchase_route_managed(h)
	local route = tostring(h and h.route or '')
	return route == 'flip' or route == 'stack'
end

local function is_managed(row)
	ensure_db()
	if AVM_DB.autoSellManageAll then return true end
	local rows = AVM_DB.purchaseHistory or {}
	for i = 1, table.getn(rows) do
		local h = rows[i]
		if purchase_route_managed(h) and purchase_match(h, tostring(row.item_key or ''), row.item_id) then return true end
	end
	return false
end

local function cost_unit_for(key, itemId)
	local rows = AVM_DB and AVM_DB.purchaseHistory or {}
	local best = 0
	for i = 1, table.getn(rows) do
		local h = rows[i]
		if purchase_route_managed(h) and purchase_match(h, key, itemId) then
			local count = tonumber(h.count) or 0
			local buyout = tonumber(h.buyout) or 0
			if count > 0 and buyout > 0 then
				local unit = buyout / count
				if unit > best then best = unit end
			end
		end
	end
	return best
end

local function historical_value(key)
	if not key or key == '' or not history or not history.value then return 0 end
	local ok, value = pcall(history.value, key)
	if not ok then return 0 end
	return tonumber(value) or 0
end

local function floor_unit(row)
	ensure_db()
	local key = tostring(row.item_key or '')
	local itemId = tonumber(row.item_id) or 0
	local floor = 0
	local cost = cost_unit_for(key, itemId)
	if cost > 0 then
		local cut = tonumber(AVM_DB.flipAhCutPct) or 5
		if cut < 0 then cut = 0 elseif cut > 30 then cut = 30 end
		local keep = 100 - cut
		if keep < 1 then keep = 1 end
		local costFloor = math.ceil(cost * 100 / keep) + 1
		if costFloor > floor then floor = costFloor end
	end
	local hv = historical_value(key)
	if hv > 0 and (tonumber(AVM_DB.autoSellMinHistPct) or 70) > 0 then
		local histFloor = math.floor(hv * (tonumber(AVM_DB.autoSellMinHistPct) or 70) / 100)
		if histFloor > floor then floor = histFloor end
	end
	return floor, cost, hv
end

local function own_unit(row)
	local unit = tonumber(row.unit_buyout_price) or 0
	local qty = tonumber(row.aux_quantity) or 0
	if unit <= 0 and qty > 0 then unit = (tonumber(row.buyout_price) or 0) / qty end
	return unit
end

local function owner_same_count(row)
	local n = 0
	for i = 1, table.getn(F.owner or {}) do
		local r = F.owner[i]
		if tostring(r.item_key or '') == tostring(row.item_key or '') and
		   tonumber(r.aux_quantity or 0) == tonumber(row.aux_quantity or 0) and
		   tonumber(r.buyout_price or 0) == tonumber(row.buyout_price or 0) then n = n + 1 end
	end
	return n
end

local function persist_result(key, row, state, marketUnit, gap, floor, target)
	ensure_db()
	AVM_DB.autoSellForceResults[key] = {
		at = epoch(), item = tostring(row and row.name or key), state = tostring(state or ''),
		ownUnit = own_unit(row or {}), marketUnit = tonumber(marketUnit) or 0,
		gapPct = tonumber(gap) or 0, floorUnit = tonumber(floor) or 0,
		targetUnit = tonumber(target) or 0,
	}
	F.results[key] = AVM_DB.autoSellForceResults[key]
end

local function evaluate_key(entry, marketUnit)
	local key = tostring(entry.key or '')
	local trigger = tonumber(AVM_DB.autoSellTriggerPct) or 1
	local undercutCopper = tonumber(AVM_DB.autoSellUndercutCopper) or 1
	local chosen = nil
	local chosenGap = -1
	local resultState = 'OK'
	local representative = entry.row

	for i = 1, table.getn(F.owner or {}) do
		local row = F.owner[i]
		if tostring(row.item_key or '') == key and is_managed(row) then
			representative = row
			if row.high_bidder or (tonumber(row.high_bid) or 0) > 0 then
				resultState = 'HAS BID'
			else
				local own = own_unit(row)
				if own <= 0 then
					resultState = 'NO BUYOUT'
				elseif not marketUnit or marketUnit <= 0 or marketUnit >= own then
					if resultState == 'OK' then resultState = marketUnit and marketUnit > 0 and 'OK' or 'NO MARKET' end
				else
					local gap = (own - marketUnit) * 100 / own
					if gap >= trigger then
						local floor, cost, hv = floor_unit(row)
						local target = math.floor(marketUnit - undercutCopper)
						if target < 1 then target = 1 end
						if floor <= 0 then
							resultState = 'NO FLOOR'
							persist_result(key, row, resultState, marketUnit, gap, floor, target)
						elseif target < floor then
							resultState = 'FLOOR'
							F.floorBlocked = F.floorBlocked + 1
							persist_result(key, row, resultState, marketUnit, gap, floor, target)
						elseif gap > chosenGap and not AVM_DB.autoSellPending[key] then
							chosenGap = gap
							resultState = 'UNDERCUT'
							chosen = {
								row = row, key = key, marketUnit = marketUnit, gapPct = gap,
								targetUnit = target, floorUnit = floor, costUnit = cost, historyUnit = hv,
							}
							persist_result(key, row, resultState, marketUnit, gap, floor, target)
						end
					end
				end
			end
		end
	end
	if chosen then
		F.undercut = F.undercut + 1
		table.insert(F.candidates, chosen)
	elseif not F.results[key] then
		persist_result(key, representative, resultState, marketUnit, 0, floor_unit(representative or {}), 0)
	end
end

local run_probe_next

local function probe_entry(entry)
	local query = scan_util.item_query(tonumber(entry.itemId) or 0)
	if not query then
		F.failed = F.failed + 1
		F.index = F.index + 1
		return run_probe_next()
	end
	local best = nil
	set_message('Checking ' .. tostring(F.index) .. '/' .. tostring(table.getn(F.queue)) .. ': ' .. tostring(entry.name or entry.key))
	AVM_DB.autoSellStats.probes = (tonumber(AVM_DB.autoSellStats.probes) or 0) + 1
	local done = false
	local function finish(value)
		if done then return end
		done = true
		F.checked = F.checked + 1
		evaluate_key(entry, value)
		F.index = F.index + 1
		run_probe_next()
	end
	scan.start{
		type = 'list',
		ignore_owner = true,
		queries = T.list(query),
		on_auction = function(record)
			if record and tostring(record.item_key or '') == tostring(entry.key or '') then
				local unit = tonumber(record.unit_buyout_price) or 0
				if unit > 0 and (not best or unit < best) then best = unit end
			end
		end,
		on_complete = function() finish(best) end,
		on_abort = function() F.failed = F.failed + 1; finish(nil) end,
	}
end

local run_cancel_next

local function cancel_candidate(candidate)
	local row = candidate.row
	local key = tostring(candidate.key or '')
	if key == '' or AVM_DB.autoSellPending[key] then
		F.cancelIndex = F.cancelIndex + 1
		return run_cancel_next()
	end
	local p = {
		state = 'CANCELING', itemKey = key, itemId = tonumber(row.item_id) or 0,
		name = tostring(row.name or ''), count = tonumber(row.aux_quantity) or 0,
		originalBuyout = tonumber(row.buyout_price) or 0, originalUnit = own_unit(row),
		marketUnit = tonumber(candidate.marketUnit) or 0, targetUnit = tonumber(candidate.targetUnit) or 0,
		floorUnit = tonumber(candidate.floorUnit) or 0, costUnit = tonumber(candidate.costUnit) or 0,
		historyUnit = tonumber(candidate.historyUnit) or 0, sameCountBefore = owner_same_count(row),
		ownerGone = false, cancelAt = GetTime(), createdAt = epoch(),
	}
	AVM_DB.autoSellPending[key] = p
	set_message('Cancel ' .. tostring(F.cancelIndex) .. '/' .. tostring(table.getn(F.candidates)) .. ': ' .. tostring(row.name or key))
	local dummy = {}
	function dummy:update_status() end
	function dummy:set_text() end
	local function fail_cancel()
		AVM_DB.autoSellPending[key] = nil
		F.failed = F.failed + 1
		F.cancelIndex = F.cancelIndex + 1
		run_cancel_next()
	end
	scan_util.find(
		row,
		dummy,
		fail_cancel,
		fail_cancel,
		function(index)
			p.state = 'CANCEL_SENT'
			p.cancelAt = GetTime()
			aux.cancel_auction(index, function()
				p.state = 'WAIT_MAIL'
				p.cancelAt = GetTime()
				AVM_DB.autoSellStats.cancels = (tonumber(AVM_DB.autoSellStats.cancels) or 0) + 1
				F.cancelled = F.cancelled + 1
				F.cancelIndex = F.cancelIndex + 1
				run_cancel_next()
			end)
		end
	)
end

local function finish_run()
	F.busy = false
	F.phase = 'idle'
	local text = 'Checked ' .. tostring(F.checked) .. ' | undercut ' .. tostring(F.undercut) ..
		' | canceled ' .. tostring(F.cancelled) .. ' | floor ' .. tostring(F.floorBlocked)
	if F.failed > 0 then text = text .. ' | failed ' .. tostring(F.failed) end
	set_message(text)
	if F.cancelled > 0 and AS and AS.RequestOwnerRefresh then AS.RequestOwnerRefresh('manual-check-decide') end
	DEFAULT_CHAT_FRAME:AddMessage('|cff60ff00[AutoSell]|r ' .. text)
end

run_cancel_next = function()
	if not F.busy then return end
	if not auction_open() then return finish_run() end
	if F.cancelIndex > table.getn(F.candidates) then return finish_run() end
	cancel_candidate(F.candidates[F.cancelIndex])
end

run_probe_next = function()
	if not F.busy then return end
	if not auction_open() then return finish_run() end
	if F.index > table.getn(F.queue) then
		if AVM_DB.autoSellEnabled and table.getn(F.candidates) > 0 then
			F.phase = 'cancel'
			F.cancelIndex = 1
			return run_cancel_next()
		end
		return finish_run()
	end
	probe_entry(F.queue[F.index])
end

start_sweep = function()
	ensure_db()
	if F.busy then return false end
	if loop_enabled() then set_message('Stop Auto Loop first'); return false end
	if not auction_open() then set_message('Open Auction House'); return false end
	if AS and AS.IsBusy and AS.IsBusy() then set_message('AutoSell busy - wait'); return false end
	if base_auxfast_busy() then set_message('AUX busy - wait'); return false end

	local seen = {}
	local queue = {}
	for i = 1, table.getn(F.owner or {}) do
		local row = F.owner[i]
		local key = tostring(row.item_key or '')
		if key ~= '' and is_managed(row) and not seen[key] and tonumber(row.buyout_price or 0) > 0 then
			seen[key] = true
			table.insert(queue, { key = key, itemId = tonumber(row.item_id) or 0, name = tostring(row.name or key), row = row })
		end
	end
	F.queue = queue
	F.index = 1
	F.candidates = {}
	F.cancelIndex = 0
	F.results = {}
	F.checked = 0
	F.undercut = 0
	F.floorBlocked = 0
	F.cancelled = 0
	F.failed = 0
	if table.getn(queue) == 0 then set_message('No managed own auctions'); return false end
	F.busy = true
	F.phase = 'price'
	set_message('Checking 1/' .. tostring(table.getn(queue)))
	run_probe_next()
	return true
end

local function request_manual_run()
	ensure_db()
	if F.busy or F.waitOwner then return end
	if loop_enabled() then set_message('Stop Auto Loop first'); return end
	if not auction_open() then set_message('Open Auction House'); return end
	if AS and AS.IsBusy and AS.IsBusy() then set_message('AutoSell busy - wait'); return end

	-- Prefer the already loaded Auctions page when it is complete. This keeps the
	-- proven Stop -> Auctions Refresh -> AutoSell path instant and avoids another owner query.
	if capture_current_owner_page() then return start_sweep() end

	if bridge and bridge.RequestOwnerSnapshot then
		F.waitOwner = true
		F.waitOwnerAt = GetTime()
		set_message('Refreshing own auctions...')
		local ok, started = pcall(bridge.RequestOwnerSnapshot, 'manual-price-check')
		if ok and started then return end
		F.waitOwner = false
		F.waitOwnerAt = 0
	end
	set_message('Refresh Auctions first')
end

local button = gui.button(aux.frame)
button:SetWidth(128)
button:SetPoint('TOPRIGHT', aux.frame, 'TOPRIGHT', -12, -13)
button:SetText('Check + decide')
button:SetScript('OnClick', request_manual_run)
button:Hide()

local label = gui.label(aux.frame, gui.font_size.small)
label:SetPoint('TOPRIGHT', button, 'BOTTOMRIGHT', 0, -3)
label:SetWidth(210)
label:SetJustifyH('RIGHT')
label:SetText('')
label:Hide()

local controller = CreateFrame('Frame')
controller:SetScript('OnUpdate', function()
	local tab = aux.get_tab and aux.get_tab()
	local visible = tab and tostring(tab.name or '') == 'AutoSell'
	if visible then
		button:Show()
		label:Show()
		if F.busy or F.waitOwner then button:Disable() else button:Enable() end
		if loop_enabled() and not F.busy then label:SetText('Stop Auto Loop first') else label:SetText(F.message or '') end
	else
		button:Hide()
		label:Hide()
	end
	if F.waitOwner and GetTime() - (tonumber(F.waitOwnerAt) or 0) > 15 then
		F.waitOwner = false
		F.waitOwnerAt = 0
		if capture_current_owner_page() then start_sweep() else set_message('Owner refresh timeout') end
	end
end)

local closeFrame = CreateFrame('Frame')
closeFrame:RegisterEvent('AUCTION_HOUSE_CLOSED')
closeFrame:SetScript('OnEvent', function()
	F.busy = false
	F.waitOwner = false
	F.phase = 'idle'
	F.queue = {}
	F.candidates = {}
	set_message('Ready')
end)

ensure_db()
