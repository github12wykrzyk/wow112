-- AuxVmangos AutoSell/Repricing V1 for WoW 1.12.1 / AUX.
-- Scope: manage AVM flip/stack purchases by default; optional all-own-auctions mode.
-- Detects meaningful undercuts, exact-revalidates the live market, cancels one
-- auction at a time, waits for manual mailbox retrieval, then reposts at the
-- current floor - configured copper undercut while respecting cost/history floors.

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local money = require 'aux.util.money'
local gui = require 'aux.gui'
local listing_lib = require 'aux.gui.listing'
local scan = require 'aux.core.scan'
local scan_util = require 'aux.util.scan'
local history = require 'aux.core.history'
local post = require 'aux.core.post'

AVM_AUTOSELL = AVM_AUTOSELL or {}
local AS = AVM_AUTOSELL

local R = {
	market = {},
	marketAt = {},
	marketBuild = {},
	marketBuilding = false,
	marketSeq = 0,
	owner = {},
	ownerBuild = nil,
	ownerSeen = {},
	ownerExpected = 0,
	ownerAt = 0,
	ownerCapturePending = false,
	ownerCaptureAt = 0,
	candidate = nil,
	action = nil,
	lastProbeAt = {},
	lastDecision = {},
	dbNormalized = false,
	nextUi = 0,
}

local function now_epoch()
	if type(time) == 'function' then return time() end
	return 0
end

local function ensure_db()
	AVM_DB = AVM_DB or {}
	if AVM_DB.autoSellSchema == nil then
		-- Zero-config policy: enabled, but only for AVM purchases whose intended
		-- exit route is AH resale (flip/stack). Existing unrelated player auctions
		-- are untouched unless Manage All is explicitly enabled.
		AVM_DB.autoSellEnabled = true
		AVM_DB.autoSellManageAll = false
		AVM_DB.autoSellTriggerPct = 1
		AVM_DB.autoSellUndercutCopper = 1
		AVM_DB.autoSellMinHistPct = 70
		AVM_DB.autoSellDurationMinutes = 1440
		AVM_DB.autoSellPending = AVM_DB.autoSellPending or {}
		AVM_DB.autoSellStats = AVM_DB.autoSellStats or { cancels = 0, reposts = 0, probes = 0 }
		AVM_DB.autoSellHistory = AVM_DB.autoSellHistory or {}
		AVM_DB.autoSellSchema = 1
	end
	if AVM_DB.autoSellEnabled == nil then AVM_DB.autoSellEnabled = true end
	if AVM_DB.autoSellManageAll == nil then AVM_DB.autoSellManageAll = false end
	if AVM_DB.autoSellTriggerPct == nil then AVM_DB.autoSellTriggerPct = 1 end
	if AVM_DB.autoSellUndercutCopper == nil then AVM_DB.autoSellUndercutCopper = 1 end
	if AVM_DB.autoSellMinHistPct == nil then AVM_DB.autoSellMinHistPct = 70 end
	if AVM_DB.autoSellDurationMinutes == nil then AVM_DB.autoSellDurationMinutes = 1440 end
	AVM_DB.autoSellPending = AVM_DB.autoSellPending or {}
	AVM_DB.autoSellStats = AVM_DB.autoSellStats or { cancels = 0, reposts = 0, probes = 0 }
	AVM_DB.autoSellHistory = AVM_DB.autoSellHistory or {}

	local trigger = tonumber(AVM_DB.autoSellTriggerPct) or 1
	if trigger < 0.1 then trigger = 0.1 elseif trigger > 50 then trigger = 50 end
	AVM_DB.autoSellTriggerPct = trigger
	local undercut = math.floor(tonumber(AVM_DB.autoSellUndercutCopper) or 1)
	if undercut < 1 then undercut = 1 elseif undercut > 10000 then undercut = 10000 end
	AVM_DB.autoSellUndercutCopper = undercut
	local histPct = math.floor(tonumber(AVM_DB.autoSellMinHistPct) or 70)
	if histPct < 0 then histPct = 0 elseif histPct > 200 then histPct = 200 end
	AVM_DB.autoSellMinHistPct = histPct

	if not R.dbNormalized then
		-- Runtime market sequence restarts after /reload. Persisted WAIT_MAIL rows
		-- must simply receive one new exact probe before reposting.
		for _, p in pairs(AVM_DB.autoSellPending) do
			if type(p) == 'table' then
				p.repostVerifiedUnit = nil
				p.repostTargetUnit = nil
				p.retryAt = 0
			end
		end
		R.dbNormalized = true
	end
end

local function diag_snapshot()
	ensure_db()
	AVM_DB.diag = AVM_DB.diag or { seq = 0, events = {}, state = {} }
	local pendingCount = 0
	for _ in pairs(AVM_DB.autoSellPending) do pendingCount = pendingCount + 1 end
	AVM_DB.diag.autoSell = {
		enabled = AVM_DB.autoSellEnabled and true or false,
		manageAll = AVM_DB.autoSellManageAll and true or false,
		triggerPct = AVM_DB.autoSellTriggerPct,
		undercutCopper = AVM_DB.autoSellUndercutCopper,
		minHistPct = AVM_DB.autoSellMinHistPct,
		marketSeq = R.marketSeq,
		ownerRows = table.getn(R.owner or {}),
		pending = pendingCount,
		action = R.action and tostring(R.action.kind or '') or '',
		candidate = R.candidate and tostring(R.candidate.name or '') or '',
		lastDecision = R.lastDecision,
		stats = AVM_DB.autoSellStats,
		history = AVM_DB.autoSellHistory,
	}
end

local function log_event(kind, row, detail)
	ensure_db()
	local e = {
		at = now_epoch(),
		kind = tostring(kind or ''),
		item = tostring(row and row.name or ''),
		itemKey = tostring(row and row.item_key or row and row.itemKey or ''),
		ownUnit = tonumber(row and row.ownUnit) or 0,
		marketUnit = tonumber(row and row.marketUnit) or 0,
		targetUnit = tonumber(row and row.targetUnit) or 0,
		floorUnit = tonumber(row and row.floorUnit) or 0,
		detail = tostring(detail or ''),
	}
	table.insert(AVM_DB.autoSellHistory, e)
	while table.getn(AVM_DB.autoSellHistory) > 100 do table.remove(AVM_DB.autoSellHistory, 1) end
	R.lastDecision = e
	diag_snapshot()
end

local function auction_open()
	return AuctionFrame and AuctionFrame.IsVisible and AuctionFrame:IsVisible()
end

local function current_tab_name()
	if not aux.get_tab then return '' end
	local t = aux.get_tab()
	return t and tostring(t.name or '') or ''
end

local function safe_idle()
	if not auction_open() then return false end
	if AVM and AVM.hardStop then return false end
	if current_tab_name() == 'Post' then return false end
	if AVM then
		if AVM.pending or AVM.unknown or AVM.queryInFlight or AVM.candidate or AVM.bidPending or AVM.bidCandidate then return false end
		if AVM.market and (AVM.market.active or AVM.market.requested) then return false end
		if AVM.vendor and (AVM.vendor.active or AVM.vendor.requested) then return false end
		if AVM.auxArb and (AVM.auxArb.active or AVM.auxArb.paused or AVM.auxArb.pausePending or AVM.auxArb.resumePending) then return false end
	end
	if AUXFAST_IsBusy then
		local ok, busy = pcall(AUXFAST_IsBusy)
		if ok and busy then return false end
	end
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

local function is_managed(row)
	ensure_db()
	if AVM_DB.autoSellManageAll then return true end
	local rows = AVM_DB.purchaseHistory or {}
	for i = 1, table.getn(rows) do
		local h = rows[i]
		if purchase_route_managed(h) and purchase_match(h, tostring(row.item_key or ''), row.item_id) then
			return true
		end
	end
	return false
end

local function historical_value(key)
	if not key or key == '' or not history or not history.value then return 0 end
	local ok, value = pcall(history.value, key)
	if not ok then return 0 end
	return tonumber(value) or 0
end

local function floor_unit(row)
	ensure_db()
	local key = tostring(row.item_key or row.itemKey or '')
	local itemId = tonumber(row.item_id or row.itemId) or 0
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
	if hv > 0 and (tonumber(AVM_DB.autoSellMinHistPct) or 0) > 0 then
		local histFloor = math.floor(hv * (tonumber(AVM_DB.autoSellMinHistPct) or 0) / 100)
		if histFloor > floor then floor = histFloor end
	end
	return floor, cost, hv
end

local function pending_for(key)
	ensure_db()
	return AVM_DB.autoSellPending[tostring(key or '')]
end

local function owner_same_count(row)
	local n = 0
	for i = 1, table.getn(R.owner or {}) do
		local r = R.owner[i]
		if tostring(r.item_key or '') == tostring(row.item_key or '') and
		   tonumber(r.aux_quantity or 0) == tonumber(row.aux_quantity or 0) and
		   tonumber(r.buyout_price or 0) == tonumber(row.buyout_price or 0) then
			n = n + 1
		end
	end
	return n
end

local function bag_quantity(key)
	local total = 0
	for slot in info.inventory() do
		local ii = info.container_item(unpack(slot))
		if ii then
			if tostring(ii.item_key or '') == tostring(key or '') then
				total = total + (tonumber(ii.aux_quantity) or tonumber(ii.count) or 0)
			end
			T.release(ii)
		end
	end
	return total
end

local function owner_copy(record, page, index)
	return {
		item_id = tonumber(record.item_id) or 0,
		item_key = tostring(record.item_key or ''),
		name = tostring(record.name or ''),
		aux_quantity = tonumber(record.aux_quantity) or tonumber(record.count) or 0,
		buyout_price = tonumber(record.buyout_price) or 0,
		unit_buyout_price = tonumber(record.unit_buyout_price) or 0,
		start_price = tonumber(record.start_price) or 0,
		high_bid = tonumber(record.high_bid) or 0,
		high_bidder = record.high_bidder,
		duration = tonumber(record.duration) or 0,
		search_signature = tostring(record.search_signature or ''),
		page = tonumber(page) or 0,
		index = tonumber(index) or 0,
		query_type = 'owner',
		blizzard_query = { first_page = tonumber(page) or 0, last_page = tonumber(page) or 0 },
	}
end

local function publish_owner_snapshot(rows)
	R.owner = rows or {}
	R.ownerAt = GetTime()
	-- Confirm that a cancellation actually removed one matching own auction.
	for key, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' and (p.state == 'CANCEL_SENT' or p.state == 'WAIT_MAIL') then
			local same = 0
			for i = 1, table.getn(R.owner) do
				local r = R.owner[i]
				if tostring(r.item_key or '') == tostring(key) and
				   tonumber(r.aux_quantity or 0) == tonumber(p.count or 0) and
				   tonumber(r.buyout_price or 0) == tonumber(p.originalBuyout or 0) then
					same = same + 1
				end
			end
			if same < (tonumber(p.sameCountBefore) or 1) then
				p.ownerGone = true
				p.state = 'WAIT_MAIL'
			elseif (tonumber(p.cancelAt) or 0) > 0 and GetTime() - tonumber(p.cancelAt) > 8 then
				-- AUX cancel callback can fire on its timeout path as well. If the
				-- exact own-auction multiplicity did not decrease, treat it as a
				-- failed cancel and allow a clean retry instead of inventing a repost.
				AVM_DB.autoSellPending[key] = nil
				log_event('CANCEL_NOT_CONFIRMED', p, 'owner snapshot still contains auction')
			end
		end
	end
	diag_snapshot()
end

local function capture_owner_page()
	R.ownerCapturePending = false
	if not auction_open() or not aux.current_owner_page then return end
	local page = aux.current_owner_page()
	if page == nil then return end
	page = tonumber(page)
	if not page then return end
	local _, total = GetNumAuctionItems('owner')
	total = tonumber(total) or 0
	local lastPage = total > 0 and math.floor((total - 1) / 50) or 0

	if page == 0 then
		R.ownerBuild = {}
		R.ownerSeen = {}
		R.ownerExpected = 0
	end
	if not R.ownerBuild then return end
	if R.ownerSeen[page] then return end
	if page ~= R.ownerExpected then return end

	R.ownerSeen[page] = true
	for i = 1, 50 do
		local record = info.auction(i, 'owner')
		if record then
			table.insert(R.ownerBuild, owner_copy(record, page, i))
			T.release(record)
		end
	end
	R.ownerExpected = page + 1
	if page >= lastPage then
		local rows = R.ownerBuild
		R.ownerBuild = nil
		R.ownerSeen = {}
		R.ownerExpected = 0
		publish_owner_snapshot(rows)
	end
end

local function market_begin(resume)
	if resume then return end
	R.marketBuild = {}
	R.marketBuilding = true
end

local function market_record(record)
	if not R.marketBuilding or not record then return end
	local key = tostring(record.item_key or '')
	local buyout = tonumber(record.buyout_price) or 0
	local qty = tonumber(record.aux_quantity) or tonumber(record.count) or 0
	local unit = tonumber(record.unit_buyout_price) or 0
	if unit <= 0 and buyout > 0 and qty > 0 then unit = buyout / qty end
	if key ~= '' and unit > 0 then
		local old = tonumber(R.marketBuild[key]) or 0
		if old <= 0 or unit < old then R.marketBuild[key] = unit end
	end
end

local function market_done()
	if not R.marketBuilding then return end
	R.market = R.marketBuild or {}
	R.marketBuild = {}
	R.marketBuilding = false
	R.marketSeq = R.marketSeq + 1
	local t = GetTime()
	for key in pairs(R.market) do R.marketAt[key] = t end
	diag_snapshot()
end

local function install_market_hooks()
	if AS._marketHooksInstalled then return end
	if not AVM_AuxArbScanStart or not AVM_AuxArbAuction or not AVM_AuxArbScanDone then return end
	local oldStart = AVM_AuxArbScanStart
	local oldAuction = AVM_AuxArbAuction
	local oldDone = AVM_AuxArbScanDone

	AVM_AuxArbScanStart = function(resume, filterString)
		market_begin(resume)
		return oldStart(resume, filterString)
	end
	AVM_AuxArbAuction = function(record)
		market_record(record)
		return oldAuction(record)
	end
	AVM_AuxArbScanDone = function()
		local result = oldDone()
		market_done()
		return result
	end
	AS._marketHooksInstalled = true
end

local function best_owner_for_key(key, marketUnit)
	local trigger = tonumber(AVM_DB.autoSellTriggerPct) or 1
	local best, bestGap = nil, -1
	for i = 1, table.getn(R.owner or {}) do
		local row = R.owner[i]
		if tostring(row.item_key or '') == tostring(key or '') and is_managed(row) and
		   not pending_for(row.item_key) and tonumber(row.buyout_price or 0) > 0 and
		   not row.high_bidder and (tonumber(row.high_bid) or 0) <= 0 then
			local qty = tonumber(row.aux_quantity) or 0
			local own = tonumber(row.unit_buyout_price) or 0
			if own <= 0 and qty > 0 then own = (tonumber(row.buyout_price) or 0) / qty end
			if own > 0 and marketUnit and marketUnit > 0 and marketUnit < own then
				local gap = (own - marketUnit) * 100 / own
				if gap >= trigger and gap > bestGap then
					best = row
					bestGap = gap
				end
			end
		end
	end
	return best, bestGap
end

local function choose_candidate()
	ensure_db()
	if not AVM_DB.autoSellEnabled or R.action or R.candidate then return end
	local now = GetTime()
	local best, bestGap, bestMarket = nil, -1, 0
	local probeRow, probeAge = nil, -1

	for i = 1, table.getn(R.owner or {}) do
		local row = R.owner[i]
		if is_managed(row) and not pending_for(row.item_key) and tonumber(row.buyout_price or 0) > 0 and
		   not row.high_bidder and (tonumber(row.high_bid) or 0) <= 0 then
			local key = tostring(row.item_key or '')
			local marketUnit = tonumber(R.market[key]) or 0
			local marketAge = now - (tonumber(R.marketAt[key]) or 0)
			local qty = tonumber(row.aux_quantity) or 0
			local own = tonumber(row.unit_buyout_price) or 0
			if own <= 0 and qty > 0 then own = (tonumber(row.buyout_price) or 0) / qty end
			if marketUnit > 0 and marketAge <= 180 and marketUnit < own then
				local gap = (own - marketUnit) * 100 / own
				if gap >= (tonumber(AVM_DB.autoSellTriggerPct) or 1) and gap > bestGap then
					best, bestGap, bestMarket = row, gap, marketUnit
				end
			end
			local age = now - (tonumber(R.lastProbeAt[key]) or 0)
			if age > probeAge then probeRow, probeAge = row, age end
		end
	end

	if best then
		R.candidate = { row = best, name = best.name, item_key = best.item_key, item_id = best.item_id,
			stage = 'VERIFY_PRICE', marketUnit = bestMarket, gapPct = bestGap }
	elseif probeRow and probeAge >= 15 then
		-- If the active Search filter did not expose this item, rotate one exact
		-- live probe per idle cycle. This keeps AutoSell useful without turning
		-- every owned auction into a competing full-market scanner.
		R.candidate = { row = probeRow, name = probeRow.name, item_key = probeRow.item_key,
			item_id = probeRow.item_id, stage = 'DISCOVER_PRICE' }
	end
	diag_snapshot()
end

local function probe_price(key, itemId, callback)
	local query = scan_util.item_query(tonumber(itemId) or 0)
	if not query then callback(nil, 'query-unavailable'); return false end
	local best = nil
	R.action = { kind = 'PRICE_PROBE', item_key = key, name = tostring(key or '') }
	AVM_DB.autoSellStats.probes = (tonumber(AVM_DB.autoSellStats.probes) or 0) + 1
	R.lastProbeAt[key] = GetTime()
	local done = false
	local function finish(value, reason)
		if done then return end
		done = true
		R.action = nil
		if value and value > 0 then
			R.market[key] = value
			R.marketAt[key] = GetTime()
		end
		callback(value, reason)
		diag_snapshot()
	end
	scan.start{
		type = 'list',
		ignore_owner = true,
		queries = T.list(query),
		on_auction = function(record)
			if record and tostring(record.item_key or '') == tostring(key or '') then
				local unit = tonumber(record.unit_buyout_price) or 0
				if unit > 0 and (not best or unit < best) then best = unit end
			end
		end,
		on_complete = function() finish(best, 'complete') end,
		on_abort = function() finish(nil, 'aborted') end,
	}
	return true
end

local function cancel_failed(key, why)
	AVM_DB.autoSellPending[key] = nil
	R.action = nil
	R.candidate = nil
	R.lastProbeAt[key] = GetTime()
	log_event('CANCEL_FAILED', { item_key = key }, why)
end

local function start_cancel(candidate)
	local row = candidate and candidate.row
	if not row then R.candidate = nil; return false end
	local key = tostring(row.item_key or '')
	if key == '' or pending_for(key) then R.candidate = nil; return false end

	local floor, cost, hv = floor_unit(row)
	local marketUnit = tonumber(candidate.verifiedUnit) or tonumber(candidate.marketUnit) or 0
	if marketUnit <= 0 then R.candidate = nil; return false end
	local undercut = tonumber(AVM_DB.autoSellUndercutCopper) or 1
	local target = math.floor(marketUnit - undercut)
	if target < 1 then target = 1 end
	local ownUnit = tonumber(row.unit_buyout_price) or 0
	if ownUnit <= 0 and tonumber(row.aux_quantity) > 0 then ownUnit = tonumber(row.buyout_price) / tonumber(row.aux_quantity) end
	local gap = ownUnit > 0 and ((ownUnit - marketUnit) * 100 / ownUnit) or 0
	if gap < (tonumber(AVM_DB.autoSellTriggerPct) or 1) or target >= ownUnit then
		R.candidate = nil
		return false
	end
	if floor <= 0 or target < floor then
		R.lastDecision = {
			kind = 'FLOOR_BLOCK', item = row.name, itemKey = key,
			ownUnit = ownUnit, marketUnit = marketUnit, targetUnit = target, floorUnit = floor,
		}
		R.candidate = nil
		diag_snapshot()
		return false
	end

	local p = {
		state = 'CANCELING',
		itemKey = key,
		itemId = tonumber(row.item_id) or 0,
		name = tostring(row.name or ''),
		count = tonumber(row.aux_quantity) or 0,
		originalBuyout = tonumber(row.buyout_price) or 0,
		originalUnit = ownUnit,
		marketUnit = marketUnit,
		targetUnit = target,
		floorUnit = floor,
		costUnit = cost,
		historyUnit = hv,
		sameCountBefore = owner_same_count(row),
		ownerGone = false,
		cancelAt = GetTime(),
		createdAt = now_epoch(),
	}
	AVM_DB.autoSellPending[key] = p
	R.action = { kind = 'CANCEL_FIND', item_key = key, name = row.name }
	log_event('CANCEL_FIND', {
		name = row.name, item_key = key, ownUnit = ownUnit, marketUnit = marketUnit,
		targetUnit = target, floorUnit = floor,
	}, 'exact owner revalidation')

	local status = {}
	function status:update_status() end
	function status:set_text() end

	local function not_found(reason)
		cancel_failed(key, reason)
	end
	scan_util.find(
		row,
		status,
		function() not_found('owner-find-aborted') end,
		function() not_found('auction-not-found') end,
		function(index)
			R.action = { kind = 'CANCEL_SENT', item_key = key, name = row.name }
			p.state = 'CANCEL_SENT'
			p.cancelAt = GetTime()
			aux.cancel_auction(index, function()
				p.state = 'WAIT_MAIL'
				R.action = nil
				R.candidate = nil
				AVM_DB.autoSellStats.cancels = (tonumber(AVM_DB.autoSellStats.cancels) or 0) + 1
				log_event('CANCEL_CALLBACK', {
					name = row.name, item_key = key, ownUnit = ownUnit, marketUnit = marketUnit,
					targetUnit = target, floorUnit = floor,
				}, 'await owner snapshot + manual mailbox retrieval')
			end)
		end
	)
	return true
end

local function verify_candidate(candidate)
	local row = candidate and candidate.row
	if not row then R.candidate = nil; return false end
	local key = tostring(row.item_key or '')
	return probe_price(key, row.item_id, function(best, why)
		if not best or best <= 0 then
			R.candidate = nil
			log_event('PRICE_PROBE_NONE', row, why)
			return
		end
		local freshRow, gap = best_owner_for_key(key, best)
		if not freshRow then
			R.candidate = nil
			return
		end
		R.candidate = {
			row = freshRow, name = freshRow.name, item_key = key, item_id = freshRow.item_id,
			stage = 'CANCEL_READY', verifiedUnit = best, gapPct = gap,
		}
	end)
end

local function repost_probe(p)
	local key = tostring(p.itemKey or '')
	p.state = 'REPRICE'
	return probe_price(key, p.itemId, function(best, why)
		if not AVM_DB.autoSellPending[key] then return end
		local floor = tonumber(p.floorUnit) or 0
		local target
		if best and best > 0 then
			target = math.floor(best - (tonumber(AVM_DB.autoSellUndercutCopper) or 1))
		else
			-- No competing auction exists now. Restore the original unit price
			-- rather than inventing a lower price from stale data.
			target = math.floor(tonumber(p.originalUnit) or 0)
		end
		if target < 1 then target = 1 end
		if floor <= 0 or target < floor then
			p.state = 'FLOOR'
			p.repostVerifiedUnit = best or 0
			p.repostTargetUnit = target
			log_event('REPOST_FLOOR_BLOCK', {
				name = p.name, item_key = key, marketUnit = best or 0,
				targetUnit = target, floorUnit = floor,
			}, why)
			return
		end
		p.repostVerifiedUnit = best or 0
		p.repostTargetUnit = target
		p.state = 'POST_READY'
	end)
end

local function start_repost(p)
	local key = tostring(p.itemKey or '')
	local target = math.floor(tonumber(p.repostTargetUnit) or 0)
	local floor = math.floor(tonumber(p.floorUnit) or 0)
	local count = math.floor(tonumber(p.count) or 0)
	if key == '' or target <= 0 or count <= 0 then return false end
	local startUnit = math.floor(target * .95)
	if startUnit < floor then startUnit = floor end
	if startUnit > target then startUnit = target end
	local duration = tonumber(AVM_DB.autoSellDurationMinutes) or 1440
	R.action = { kind = 'POST', item_key = key, name = p.name }
	p.state = 'POSTING'
	log_event('POST_SENT', {
		name = p.name, item_key = key, marketUnit = p.repostVerifiedUnit or 0,
		targetUnit = target, floorUnit = floor,
	}, 'stack=' .. tostring(count))
	post.start(key, count, duration, startUnit, target, 1, function(posted)
		R.action = nil
		if (tonumber(posted) or 0) > 0 then
			AVM_DB.autoSellStats.reposts = (tonumber(AVM_DB.autoSellStats.reposts) or 0) + 1
			log_event('POST_CONFIRMED', {
				name = p.name, item_key = key, marketUnit = p.repostVerifiedUnit or 0,
				targetUnit = target, floorUnit = floor,
			}, 'posted=' .. tostring(posted))
			AVM_DB.autoSellPending[key] = nil
		else
			p.state = 'WAIT_MAIL'
			p.retryAt = GetTime() + 5
			log_event('POST_FAILED', { name = p.name, item_key = key, targetUnit = target, floorUnit = floor }, 'posted=0')
		end
		diag_snapshot()
	end)
	return true
end

function AS.Tick(now)
	ensure_db()
	install_market_hooks()
	if not AVM_DB.autoSellEnabled then return false end
	if R.action then return true end
	if not safe_idle() then return false end
	now = tonumber(now) or GetTime()

	-- Repost work has priority once the user manually collected canceled mail.
	for key, p in pairs(AVM_DB.autoSellPending) do
		if type(p) == 'table' and p.ownerGone then
			local retryAt = tonumber(p.retryAt) or 0
			if now >= retryAt and bag_quantity(key) >= (tonumber(p.count) or 0) then
				if p.state == 'POST_READY' and tonumber(p.repostTargetUnit) and tonumber(p.repostTargetUnit) > 0 then
					return start_repost(p)
				end
				if p.state ~= 'REPRICE' and p.state ~= 'POSTING' then
					return repost_probe(p)
				end
			end
		end
	end

	if not R.candidate then choose_candidate() end
	if R.candidate then
		if R.candidate.stage == 'VERIFY_PRICE' or R.candidate.stage == 'DISCOVER_PRICE' then
			return verify_candidate(R.candidate)
		elseif R.candidate.stage == 'CANCEL_READY' then
			return start_cancel(R.candidate)
		end
	end
	return false
end

function AS.IsBusy()
	return R.action and true or false
end

function AS.Status()
	ensure_db()
	local pendingCount = 0
	for _ in pairs(AVM_DB.autoSellPending) do pendingCount = pendingCount + 1 end
	return {
		enabled = AVM_DB.autoSellEnabled and true or false,
		manageAll = AVM_DB.autoSellManageAll and true or false,
		owner = table.getn(R.owner or {}),
		pending = pendingCount,
		action = R.action and tostring(R.action.kind or '') or '',
		candidate = R.candidate and tostring(R.candidate.name or '') or '',
		marketSeq = R.marketSeq,
	}
end

-- Capture complete owner snapshots from any sequential owner scan (native
-- Auctions tab or AVM DE-exposure scan) without issuing another competing
-- GetOwnerAuctionItems stream.
local eventFrame = CreateFrame('Frame', 'AuxVmangosAutoSellEvents')
eventFrame:RegisterEvent('AUCTION_OWNED_LIST_UPDATE')
eventFrame:RegisterEvent('AUCTION_HOUSE_CLOSED')
eventFrame:SetScript('OnEvent', function()
	if event == 'AUCTION_OWNED_LIST_UPDATE' then
		R.ownerCapturePending = true
		R.ownerCaptureAt = GetTime() + .01
	elseif event == 'AUCTION_HOUSE_CLOSED' then
		R.action = nil
		R.candidate = nil
		R.ownerBuild = nil
		R.ownerCapturePending = false
	end
end)
eventFrame:SetScript('OnUpdate', function()
	if R.ownerCapturePending and GetTime() >= R.ownerCaptureAt then capture_owner_page() end
	-- If the user disabled the continuous AUX loop, AutoSell may still finish
	-- already discovered work from a manually refreshed Auctions snapshot.
	if AVM_DB and AVM_DB.autoSellEnabled and AVM_DB.auxLoopEnabled == false and GetTime() >= (R._standaloneTick or 0) then
		R._standaloneTick = GetTime() + .20
		AS.Tick(GetTime())
	end
end)

-- Native AUX tab.
local tab = aux.tab 'AutoSell'
local frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints()
frame:Hide()

local controls = gui.panel(frame)
controls:SetHeight(86)
controls:SetPoint('TOPLEFT', frame, 'TOPLEFT', 0, -8)
controls:SetPoint('TOPRIGHT', frame, 'TOPRIGHT', 0, -8)

local listPanel = gui.panel(frame)
listPanel:SetPoint('TOPLEFT', controls, 'BOTTOMLEFT', 0, -3)
listPanel:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

local listing = listing_lib.new(listPanel)
listing:SetColInfo{
	{name='Item',width=.31,align='LEFT'},
	{name='Own/ea',width=.13,align='RIGHT'},
	{name='Market/ea',width=.13,align='RIGHT'},
	{name='Gap',width=.09,align='RIGHT'},
	{name='Floor/ea',width=.13,align='RIGHT'},
	{name='State',width=.21,align='LEFT'},
}

local status = gui.status_bar(frame)
status:SetWidth(440)
status:SetHeight(25)
status:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -6)
status:update_status(1,1)
status:set_text('')

local enabledBox = gui.checkbox(controls)
enabledBox:SetPoint('TOPLEFT', 12, -12)
local enabledLabel = gui.label(enabledBox, gui.font_size.small)
enabledLabel:SetPoint('LEFT', enabledBox, 'RIGHT', 4, 1)
enabledLabel:SetText('AutoSell ON')

local allBox = gui.checkbox(controls)
allBox:SetPoint('TOPLEFT', 160, -12)
local allLabel = gui.label(allBox, gui.font_size.small)
allLabel:SetPoint('LEFT', allBox, 'RIGHT', 4, 1)
allLabel:SetText('Manage all own auctions')

local triggerBox = gui.editbox(controls)
triggerBox:SetPoint('TOPLEFT', 12, -52)
triggerBox:SetWidth(58)
triggerBox:SetHeight(20)
triggerBox:SetNumeric(true)
local triggerLabel = gui.label(triggerBox, gui.font_size.small)
triggerLabel:SetPoint('BOTTOMLEFT', triggerBox, 'TOPLEFT', 0, 2)
triggerLabel:SetText('Reprice trigger %')

local histBox = gui.editbox(controls)
histBox:SetPoint('TOPLEFT', 135, -52)
histBox:SetWidth(58)
histBox:SetHeight(20)
histBox:SetNumeric(true)
local histLabel = gui.label(histBox, gui.font_size.small)
histLabel:SetPoint('BOTTOMLEFT', histBox, 'TOPLEFT', 0, 2)
histLabel:SetText('Min history %')

local undercutBox = gui.editbox(controls)
undercutBox:SetPoint('TOPLEFT', 258, -52)
undercutBox:SetWidth(58)
undercutBox:SetHeight(20)
undercutBox:SetNumeric(true)
local undercutLabel = gui.label(undercutBox, gui.font_size.small)
undercutLabel:SetPoint('BOTTOMLEFT', undercutBox, 'TOPLEFT', 0, 2)
undercutLabel:SetText('Undercut copper')

local function commit_controls()
	ensure_db()
	AVM_DB.autoSellEnabled = enabledBox:GetChecked() and true or false
	AVM_DB.autoSellManageAll = allBox:GetChecked() and true or false
	local v = tonumber(triggerBox:GetText())
	if v then AVM_DB.autoSellTriggerPct = v end
	v = tonumber(histBox:GetText())
	if v then AVM_DB.autoSellMinHistPct = v end
	v = tonumber(undercutBox:GetText())
	if v then AVM_DB.autoSellUndercutCopper = v end
	ensure_db()
	triggerBox:SetText(tostring(AVM_DB.autoSellTriggerPct))
	histBox:SetText(tostring(AVM_DB.autoSellMinHistPct))
	undercutBox:SetText(tostring(AVM_DB.autoSellUndercutCopper))
	R.candidate = nil
	diag_snapshot()
end

enabledBox:SetScript('OnClick', commit_controls)
allBox:SetScript('OnClick', commit_controls)
triggerBox.focus_loss = commit_controls
triggerBox.enter = function() this:ClearFocus(); commit_controls() end
histBox.focus_loss = commit_controls
histBox.enter = function() this:ClearFocus(); commit_controls() end
undercutBox.focus_loss = commit_controls
undercutBox.enter = function() this:ClearFocus(); commit_controls() end

local function money_text(v)
	v = tonumber(v) or 0
	if v <= 0 then return '' end
	return money.to_string(math.floor(v + .5), true, true)
end

local function ui_state(row)
	local key = tostring(row.item_key or '')
	local p = pending_for(key)
	if p then
		if p.ownerGone and bag_quantity(key) >= (tonumber(p.count) or 0) then
			if p.state == 'FLOOR' then return 'READY / FLOOR' end
			return tostring(p.state or 'READY')
		end
		return tostring(p.state or 'WAIT_MAIL')
	end
	if row.high_bidder or (tonumber(row.high_bid) or 0) > 0 then return 'HAS BID' end
	if not is_managed(row) then return 'IGNORED' end
	local market = tonumber(R.market[key]) or 0
	if market <= 0 then return 'PRICE CHECK' end
	local own = tonumber(row.unit_buyout_price) or 0
	if own <= 0 then return 'NO BUYOUT' end
	local gap = market < own and ((own-market)*100/own) or 0
	if gap < (tonumber(AVM_DB.autoSellTriggerPct) or 1) then return 'OK' end
	local floor = floor_unit(row)
	local target = math.floor(market - (tonumber(AVM_DB.autoSellUndercutCopper) or 1))
	if floor <= 0 then return 'NO FLOOR' end
	if target < floor then return 'FLOOR' end
	return 'UNDERCUT'
end

local function refresh_ui(force)
	if not frame:IsShown() then return end
	ensure_db()
	enabledBox:SetChecked(AVM_DB.autoSellEnabled)
	allBox:SetChecked(AVM_DB.autoSellManageAll)
	-- AUX gui.editbox on WoW 1.12 tracks focus through its own .focused flag;
	-- the 1.12 EditBox API does not provide HasFocus().
	if not triggerBox.focused then triggerBox:SetText(tostring(AVM_DB.autoSellTriggerPct)) end
	if not histBox.focused then histBox:SetText(tostring(AVM_DB.autoSellMinHistPct)) end
	if not undercutBox.focused then undercutBox:SetText(tostring(AVM_DB.autoSellUndercutCopper)) end

	local rows = T.acquire()
	local shown = {}
	for i = 1, table.getn(R.owner or {}) do
		local r = R.owner[i]
		local key = tostring(r.item_key or '')
		local own = tonumber(r.unit_buyout_price) or 0
		local market = tonumber(R.market[key]) or 0
		local gap = own > 0 and market > 0 and market < own and ((own-market)*100/own) or 0
		local floor = floor_unit(r)
		table.insert(rows, T.map('cols', T.list(
			T.map('value', tostring(r.name or '')),
			T.map('value', money_text(own)),
			T.map('value', money_text(market)),
			T.map('value', gap > 0 and string.format('%.1f%%', gap) or ''),
			T.map('value', money_text(floor)),
			T.map('value', ui_state(r))
		), 'record', r))
		shown[key] = true
	end
	for key, p in pairs(AVM_DB.autoSellPending or {}) do
		if not shown[key] then
			table.insert(rows, T.map('cols', T.list(
				T.map('value', tostring(p.name or key)),
				T.map('value', money_text(p.originalUnit)),
				T.map('value', money_text(p.repostVerifiedUnit or p.marketUnit)),
				T.map('value', ''),
				T.map('value', money_text(p.floorUnit)),
				T.map('value', tostring(p.state or 'WAIT_MAIL'))
			), 'record', p))
		end
	end
	listing:SetData(rows)

	local st = AS.Status()
	local stats = AVM_DB.autoSellStats or {}
	status:set_text(
		(st.enabled and 'ON' or 'OFF') ..
		(st.manageAll and ' | ALL OWN' or ' | AVM FLIP/STACK') ..
		' | own ' .. tostring(st.owner) ..
		' | pending ' .. tostring(st.pending) ..
		' | cancels ' .. tostring(stats.cancels or 0) ..
		' | reposts ' .. tostring(stats.reposts or 0) ..
		(st.action ~= '' and (' | ' .. st.action) or '')
	)
end

frame:SetScript('OnUpdate', function()
	if GetTime() < R.nextUi then return end
	R.nextUi = GetTime() + .5
	refresh_ui(false)
end)

function tab.OPEN()
	ensure_db()
	install_market_hooks()
	frame:Show()
	refresh_ui(true)
end
function tab.CLOSE() frame:Hide() end

SLASH_AVMAUTOSELL1 = '/autosell'
SlashCmdList['AVMAUTOSELL'] = function(msg)
	ensure_db()
	msg = string.lower(tostring(msg or ''))
	if msg == 'on' then AVM_DB.autoSellEnabled = true
	elseif msg == 'off' then AVM_DB.autoSellEnabled = false
	elseif msg == 'all on' then AVM_DB.autoSellManageAll = true
	elseif msg == 'all off' then AVM_DB.autoSellManageAll = false
	end
	local st = AS.Status()
	DEFAULT_CHAT_FRAME:AddMessage('|cff60ff00[AutoSell]|r enabled=' .. tostring(st.enabled) ..
		' manageAll=' .. tostring(st.manageAll) .. ' own=' .. tostring(st.owner) ..
		' pending=' .. tostring(st.pending) .. ' action=' .. tostring(st.action))
end

ensure_db()
install_market_hooks()
diag_snapshot()
