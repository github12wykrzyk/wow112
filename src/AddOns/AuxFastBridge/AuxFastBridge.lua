-- AuxFastBridge v2.4
-- Original AUX GUI/state machine with native 0x025C response correlation.
-- The next list query is allowed only after the previous real server response has
-- passed through the verified WoW 5875 auction result handler.
AuxFastBridgeDB = AuxFastBridgeDB or {}

local originalCanSendAuctionQuery = CanSendAuctionQuery
local originalQueryAuctionItems = QueryAuctionItems
local okScan, scan = pcall(require, "aux.core.scan")
local okSearchTab, searchTab = pcall(require, "aux.tabs.search")
local auxCore = require "aux"

local busy = 0
local startedAt = 0
local hookInstalled = false

local uiEvents = 0
local bypassChecks = 0
local queryCount = 0
local nativeSeq = 0
local nativeResults = 0
local nativeCount = 0
local nativeAt = 0
local matchedResults = 0
local nativeTimeouts = 0
local ownerGraceAccepts = 0
local nativeStockSentTotal = 0
local nativeStockSentBase = 0
local nativeLastStockPage = -1
local browseDetached = false
local nativeCooldownMs = -1
local nativeCooldownPatched = false
local gateBlockedChecks = 0
local pauseRequested = false
local pausePage = -1
local resumeRequested = false

local awaitNativeSeq = 0
local querySentAt = 0
local queryPage = -1
local NATIVE_WAIT_TIMEOUT = 1.50
local OWNER_GRACE_SECONDS = 0.10

local function out(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ff99[AUX FAST]|r " .. tostring(msg))
	end
end

local function detach_blizzard_browse()
	if browseDetached then return end
	if AuctionFrameBrowse and AuctionFrameBrowse.UnregisterEvent then
		AuctionFrameBrowse:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
		browseDetached = true
	end
end

local function restore_blizzard_browse()
	if not browseDetached then return end
	if AuctionFrameBrowse and AuctionFrameBrowse.RegisterEvent then
		AuctionFrameBrowse:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
	end
	browseDetached = false
end

local function native_stock_sent()
	local n = nativeStockSentTotal - nativeStockSentBase
	if n < 0 then return 0 end
	return n
end

local function avm_busy()
	if not AVM then return false end
	local arb = AVM.auxArb or {}
	local phase = AVM.phase or "IDLE"
	return AVM.queryInFlight or AVM.pending or AVM.unknown or AVM.candidate or
		arb.deVerify or arb.flipVerify or arb.postscanCandidate or arb.paused or arb.pausePending or
		phase == "DE_MAT_REVALIDATE" or phase == "FLIP_MARKET_REVALIDATE" or
		phase == "REVALIDATE" or phase == "BUY_PENDING" or phase == "UNKNOWN_HOLD" or
		(AVM.market and (AVM.market.active or AVM.market.requested)) or
		(AVM.vendor and (AVM.vendor.active or AVM.vendor.requested))
end

function AUXFAST_IsBusy()
	return busy > 0 or avm_busy()
end

-- Called by WoWAHThrottleNative after the verified stock 0x025C handler returns.
-- At this point GetAuctionItemInfo("list", ...) contains the response just received.
function AUXFAST_NativeAuctionResult(count, nativeTick)
	nativeSeq = nativeSeq + 1
	nativeCount = tonumber(count) or 0
	nativeAt = GetTime()
	if busy > 0 and not avm_busy() then
		nativeResults = nativeResults + 1
	end
end

-- Published from the native ClientServices::Send hook on the timer thread after
-- a real CMSG_AUCTION_LIST_ITEMS packet has actually left the Lua/UI path.
function AUXFAST_NativeQueryObserved(total, page, nativeTick, cooldownMs, cooldownPatched)
	nativeStockSentTotal = tonumber(total) or nativeStockSentTotal
	nativeLastStockPage = tonumber(page) or nativeLastStockPage
	nativeCooldownMs = tonumber(cooldownMs) or nativeCooldownMs
	nativeCooldownPatched = tonumber(cooldownPatched) == 1
end

function AUXFAST_Status()
	return {
		busy = busy > 0,
		uiEvents = uiEvents,
		bypassChecks = bypassChecks,
		queryCount = queryCount,
		nativeSeq = nativeSeq,
		nativeResults = nativeResults,
		nativeCount = nativeCount,
		matchedResults = matchedResults,
		nativeTimeouts = nativeTimeouts,
		ownerGraceAccepts = ownerGraceAccepts,
		nativeStockSent = native_stock_sent(),
		nativeLastStockPage = nativeLastStockPage,
		browseDetached = browseDetached,
		nativeCooldownMs = nativeCooldownMs,
		nativeCooldownPatched = nativeCooldownPatched,
		gateBlockedChecks = gateBlockedChecks,
		pauseRequested = pauseRequested,
		pausePage = pausePage,
		queryPage = queryPage,
		startedAt = startedAt,
		hookInstalled = hookInstalled,
	}
end

-- Snapshot the native response generation immediately before each original AUX
-- QueryAuctionItems call. This lets the scan wait for a response newer than the
-- exact request, rather than treating duplicate UI events as page completion.
QueryAuctionItems = function(...)
	local a = arg or {}
	if busy > 0 and not avm_busy() then
		queryCount = queryCount + 1
		awaitNativeSeq = nativeSeq
		querySentAt = GetTime()
		queryPage = tonumber(a[7]) or -1
	end
	return originalQueryAuctionItems(unpack(a))
end

local function install_scan_hook()
	if not okScan or not scan or not scan.start then return false end
	local originalStart = scan.start

	-- aux-addon-vanilla require() returns a read-only export proxy. Enter the
	-- actual module environment so both M.start and the internal result wait
	-- function are replaced in the state machine that Search really uses.
	module "aux.core.scan"
	local originalWaitForListResults = wait_for_list_results

	M.start = function(params)
		params = params or {}
		-- Original AUX Search always supplies validator functions even when no
		-- saved automatic rule is enabled, so function presence cannot classify
		-- the scan. Detect the normal full Search by its callback shape instead.
		local fullSearchScan = params.type == "list" and
			params.on_scan_start and params.on_start_query and
			params.on_page_scanned and params.on_auction and true or false
		local auxArbAttached = fullSearchScan and AVM_DB and AVM_DB.auxArbEnabled and
			AVM_AuxArbScanStart and AVM_AuxArbAuction and AVM_AuxArbPageDone and true or false
		if fullSearchScan then
			params.ignore_owner = true
		end
		if auxArbAttached then
			params.auto_buy_validator = nil
			params.auto_bid_validator = nil
		end
		local activeFilter = ""
		if params.queries then
			local parts = {}
			for i = 1, table.getn(params.queries) do
				local q = params.queries[i]
				local label = q and q.prettified or nil
				if not label or label == "" then
					local bq = q and q.blizzard_query or nil
					label = bq and bq.name or ""
				end
				table.insert(parts, tostring(label or ""))
			end
			activeFilter = table.concat(parts, ";")
		end

		local oldScanStart = params.on_scan_start
		local oldAuction = params.on_auction
		local oldPageScanned = params.on_page_scanned
		local oldComplete = params.on_complete
		local oldAbort = params.on_abort
		local released = false

		local arbResume = resumeRequested
		resumeRequested = false
		params.on_scan_start = function()
			if oldScanStart then oldScanStart() end
			if auxArbAttached and AVM_AuxArbScanStart then pcall(AVM_AuxArbScanStart, arbResume, activeFilter) end
		end

		params.on_auction = function(record)
			if oldAuction then oldAuction(record) end
			if auxArbAttached and AVM_AuxArbAuction then pcall(AVM_AuxArbAuction, record) end
		end

		params.on_page_scanned = function()
			if oldPageScanned then oldPageScanned() end
			if auxArbAttached and AVM_AuxArbPageDone then
				local state = get_state()
				local page = state and state.page or queryPage
				local last = page
				if state and state.total_auctions then
					local okLast, value = pcall(last_page, state.total_auctions)
					if okLast and value then last = value end
				end
				local okPause, wantPause = pcall(AVM_AuxArbPageDone, page, last)
				if okPause and wantPause then
					pauseRequested = true
					pausePage = page or -1
				end
			end
		end

		local function release()
			if released then return end
			released = true
			if busy > 0 then busy = busy - 1 end
			if busy == 0 then
				AuxFastBridgeDB.lastUiEvents = uiEvents
				AuxFastBridgeDB.lastQueries = queryCount
				AuxFastBridgeDB.lastNativeResults = nativeResults
				AuxFastBridgeDB.lastMatchedResults = matchedResults
				AuxFastBridgeDB.lastNativeTimeouts = nativeTimeouts
				AuxFastBridgeDB.lastOwnerGraceAccepts = ownerGraceAccepts
				AuxFastBridgeDB.lastNativeStockSent = native_stock_sent()
				AuxFastBridgeDB.lastNativeLastStockPage = nativeLastStockPage
				AuxFastBridgeDB.lastBypassChecks = bypassChecks
				AuxFastBridgeDB.lastDuration = startedAt > 0 and (GetTime() - startedAt) or 0
				restore_blizzard_browse()
			end
		end

		params.on_complete = function()
			release()
			local result
			if oldComplete then result = oldComplete() end
			if auxArbAttached and AVM_AuxArbScanDone then pcall(AVM_AuxArbScanDone) end
			pauseRequested = false
			pausePage = -1
			return result
		end
		params.on_abort = function()
			local arbPause = pauseRequested
			release()
			local result
			if oldAbort then result = oldAbort() end
			pauseRequested = false
			if arbPause and auxArbAttached and AVM_AuxArbPaused then
				pcall(AVM_AuxArbPaused, pausePage)
			end
			pausePage = -1
			return result
		end

		if busy == 0 then
			pauseRequested = false
			pausePage = -1
			uiEvents = 0
			bypassChecks = 0
			gateBlockedChecks = 0
			queryCount = 0
			nativeResults = 0
			matchedResults = 0
			nativeTimeouts = 0
			ownerGraceAccepts = 0
			nativeStockSentBase = nativeStockSentTotal
			nativeLastStockPage = -1
			queryPage = -1
			startedAt = GetTime()
		end

		busy = busy + 1
		if fullSearchScan then detach_blizzard_browse() end
		return originalStart(params)
	end

	wait_for_list_results = function()
		local expectedSeq = awaitNativeSeq
		local sentAt = querySentAt
		local ignoreOwner = get_state().params.ignore_owner or auxCore.account_data.ignore_owner
		local usedOwnerGrace = false

		return auxCore.when(function()
			if nativeSeq > expectedSeq then
				if ignoreOwner or owner_data_complete() then
					return true
				end

				-- Seller-name resolution can emit delayed owner updates for seconds.
				-- The auction page itself is already authoritative once the verified
				-- native 0x025C response completed, so give owners only a tiny grace
				-- window and never let them reintroduce the upstream 5-second cadence.
				if nativeAt > 0 and GetTime() - nativeAt >= OWNER_GRACE_SECONDS then
					usedOwnerGrace = true
					return true
				end
			end
			if sentAt > 0 and GetTime() - sentAt >= NATIVE_WAIT_TIMEOUT then
				return true
			end
		end, function()
			if nativeSeq > expectedSeq then
				matchedResults = matchedResults + 1
				if usedOwnerGrace then ownerGraceAccepts = ownerGraceAccepts + 1 end
				return accept_results()
			end

			-- Native correlation should normally resolve first. If the verified
			-- callback is unavailable, fall back to upstream AUX semantics rather
			-- than issuing overlapping/reordered requests.
			nativeTimeouts = nativeTimeouts + 1
			return originalWaitForListResults()
		end)
	end

	-- A live arbitrage candidate is selected only after the whole current page
	-- has been scanned. Abort at the next submit boundary so upstream Search can
	-- save a correct continuation without invalidating the current scan stack.
	local originalSubmitQuery = submit_query
	submit_query = function()
		if pauseRequested then
			local state = get_state()
			if state and state.id then abort(state.id) end
			return
		end
		return originalSubmitQuery()
	end

	hookInstalled = true
	return true
end

if not install_scan_hook() then
	out("ERROR: aux.core.scan unavailable; fast transport disabled")
end

function AUXFAST_ResumeSearch()
	if busy > 0 then
		out("resume deferred: original AUX scan is still busy")
		return false
	end
	if not okSearchTab or not searchTab or not searchTab.execute then
		out("resume failed: aux.tabs.search unavailable")
		return false
	end
	resumeRequested = true
	local ok, err = pcall(searchTab.execute, true)
	if not ok then
		resumeRequested = false
		out("resume failed: " .. tostring(err))
		return false
	end
	out("resumed original AUX search continuation")
	return true
end

function AUXFAST_RestartSearch()
	if busy > 0 then
		out("restart deferred: original AUX scan is still busy")
		return false
	end
	if avm_busy() then
		out("restart deferred: AVM owns AH scheduler")
		return false
	end
	if not okSearchTab or not searchTab or not searchTab.execute then
		out("restart failed: aux.tabs.search unavailable")
		return false
	end
	resumeRequested = false
	local ok, err = pcall(searchTab.execute, false, false)
	if not ok then
		out("restart failed: " .. tostring(err))
		return false
	end
	if busy <= 0 then
		out("restart did not start a Search (check current AUX filter)")
		return false
	end
	out("restarted original AUX Search from page 0")
	return true
end

CanSendAuctionQuery = function(...)
	local ready = true
	if originalCanSendAuctionQuery then
		ready = originalCanSendAuctionQuery(unpack(arg or {}))
	end
	-- v1.6 no longer lies to AUX about the client gate. The native companion
	-- changes the exact 5875 QueryAuctionItems cooldown from 5000 ms to 25 ms,
	-- so both CanSendAuctionQuery and QueryAuctionItems share the same short gate.
	if busy > 0 and not avm_busy() and not ready then
		gateBlockedChecks = gateBlockedChecks + 1
	end
	return ready
end

local f = CreateFrame("Frame")
f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
f:SetScript("OnEvent", function()
	if busy > 0 then uiEvents = uiEvents + 1 end
end)

SLASH_AUXFAST1 = "/auxfast"
SlashCmdList["AUXFAST"] = function()
	local duration = startedAt > 0 and (GetTime() - startedAt) or 0
	out("hook=" .. tostring(hookInstalled) ..
		" busy=" .. tostring(busy > 0) ..
		" queries=" .. tostring(queryCount) ..
		" native=" .. tostring(nativeResults) ..
		" matched=" .. tostring(matchedResults) ..
		" timeouts=" .. tostring(nativeTimeouts) ..
		" ownerGrace=" .. tostring(ownerGraceAccepts) ..
		" stockSent=" .. tostring(native_stock_sent()) ..
		" cdPatch=" .. tostring(nativeCooldownPatched) ..
		" cdMs=" .. tostring(nativeCooldownMs))
	out("uiEvents=" .. tostring(uiEvents) ..
		" bypass=" .. tostring(bypassChecks) ..
		" page=" .. tostring(queryPage) ..
		" stockPage=" .. tostring(nativeLastStockPage) ..
		" uiIso=" .. tostring(browseDetached) ..
		" elapsed=" .. string.format("%.1f", duration) .. "s" ..
		" avmBusy=" .. tostring(avm_busy() and true or false))
end

out("v2.4 loaded: midscan DE pause/resume + postscan transaction lock + Filter Builder/AUX_ARB continuous Search; hook=" .. tostring(hookInstalled))
