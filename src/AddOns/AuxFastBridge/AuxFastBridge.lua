-- AuxFastBridge v3.6 list/owner busy separation; service-handoff pause; upvalue-safe headless state
-- Original AUX GUI/state machine with native 0x025C response correlation.
-- The next list query is allowed only after the previous real server response has
-- passed through the verified WoW 5875 auction result handler.
AuxFastBridgeDB = AuxFastBridgeDB or {}

-- Runtime routing stays behind helper functions so the large M.start closure
-- does not capture extra file-scope locals. WoW 1.12 Lua has a hard 32-upvalue
-- limit; v3.2 exceeded it after adding six lexical headless-state captures.
local headlessState = {
	pending = false,
	source = "",
	active = false,
	records = 0,
	pages = 0,
	serial = 0,
}

local originalCanSendAuctionQuery = CanSendAuctionQuery
local originalQueryAuctionItems = QueryAuctionItems
local okScan, scan = pcall(require, "aux.core.scan")
local okSearchTab, searchTab = pcall(require, "aux.tabs.search")
local auxCore = require "aux"

local busy = 0

-- "busy" intentionally remains the all-AUX-scan counter used by service handoff.
-- Search continuation must not be blocked by an independent owner/bidder scan,
-- because aux.core.scan keeps separate state machines per query type. Keep the
-- list occupancy in global runtime state so M.start does not capture another
-- file-scope upvalue (WoW 1.12 Lua has the 32-upvalue ceiling noted above).
AUXFAST_RUNTIME = AUXFAST_RUNTIME or {}
AUXFAST_RUNTIME.searchBusy = 0

function AUXFAST_SearchBusy()
	return tonumber(AUXFAST_RUNTIME.searchBusy) or 0
end

function AUXFAST_SearchScanEnter(scanType)
	if scanType == "list" then
		AUXFAST_RUNTIME.searchBusy = AUXFAST_SearchBusy() + 1
	end
end

function AUXFAST_SearchScanLeave(scanType)
	if scanType ~= "list" then return end
	local n = AUXFAST_SearchBusy() - 1
	if n < 0 then n = 0 end
	AUXFAST_RUNTIME.searchBusy = n
end

function AUXFAST_IsSearchBusy()
	return AUXFAST_SearchBusy() > 0
end

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

-- MarketWorker service handoff is deliberately independent of the arbitrage
-- candidate pause path. It pauses only at an AUX submit boundary, after the
-- current real AH response has been consumed, so closing the AH cannot split
-- a query/result pair.
local servicePauseRequested = false
local servicePaused = false
local servicePauseHadScan = false

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

function AUXFAST_ArmHeadless(source)
	headlessState.pending = true
	headlessState.source = tostring(source or "auto")
end

function AUXFAST_ClearHeadlessArm()
	headlessState.pending = false
	headlessState.source = ""
	headlessState.active = false
end

function AUXFAST_BeginScan(fullSearchScan, isResume)
	local source = headlessState.source
	local headless = fullSearchScan and headlessState.pending and true or false
	headlessState.pending = false
	headlessState.source = ""
	headlessState.active = headless
	if headless and not isResume then
		headlessState.records = 0
		headlessState.pages = 0
	end
	if fullSearchScan then
		headlessState.serial = headlessState.serial + 1
		out("SCAN_MODE id=" .. tostring(headlessState.serial) ..
			" source=" .. tostring(source ~= "" and source or "manual") ..
			" headless=" .. tostring(headless) ..
			" resume=" .. tostring(isResume and true or false))
	end
	return headless, source, headlessState.serial
end

function AUXFAST_HeadlessRecord()
	headlessState.records = (headlessState.records or 0) + 1
end

function AUXFAST_HeadlessPage()
	headlessState.pages = (headlessState.pages or 0) + 1
end

function AUXFAST_EndScan(scanId, source, headless, aborted, paused)
	AuxFastBridgeDB.lastScanId = tonumber(scanId) or 0
	AuxFastBridgeDB.lastScanSource = source ~= "" and source or "manual"
	AuxFastBridgeDB.lastScanHeadless = headless and true or false
	AuxFastBridgeDB.lastHeadlessRecords = headlessState.records or 0
	AuxFastBridgeDB.lastHeadlessPages = headlessState.pages or 0
	out((aborted and "SCAN_ABORT" or "SCAN_DONE") ..
		" id=" .. tostring(AuxFastBridgeDB.lastScanId) ..
		" source=" .. tostring(AuxFastBridgeDB.lastScanSource) ..
		" headless=" .. tostring(headless and true or false) ..
		(aborted and (" pause=" .. tostring(paused and true or false)) or "") ..
		" hPages=" .. tostring(headlessState.pages or 0) ..
		" hRecords=" .. tostring(headlessState.records or 0))
	headlessState.active = false
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

local function avm_hard_stopped()
	return AVM and AVM.hardStop and true or false
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

-- Upstream AUX execute(true) assumes current_search().filter_string is always a
-- string and passes it straight to EditBox:SetText. The initial Search object is
-- created with a nil filter, so an automatic loop restart can hit SetText(nil)
-- before a manual Search has normalized that state. Enter the real module
-- environment (require() exposes only the read-only export proxy) and repair the
-- internal field without replacing/resetting the Search result table.
local function ensure_search_resume_filter()
	module "aux.tabs.search"
	local search = current_search and current_search()
	if not search then return false, "current search unavailable" end
	if type(search.filter_string) ~= "string" then
		local filter = ""
		if search_box and search_box.GetText then
			filter = search_box:GetText() or ""
		end
		if type(filter) ~= "string" then filter = tostring(filter or "") end
		search.filter_string = filter
	end
	return true, search.filter_string
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
		searchBusy = AUXFAST_SearchBusy() > 0,
		searchBusyCount = AUXFAST_SearchBusy(),
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
		headlessLoop = headlessState.active and true or false,
		headlessRecords = headlessState.records or 0,
		headlessPages = headlessState.pages or 0,
	}
end

-- Snapshot the native response generation immediately before each original AUX
-- QueryAuctionItems call. This lets the scan wait for a response newer than the
-- exact request, rather than treating duplicate UI events as page completion.
QueryAuctionItems = function(...)
	local a = arg or {}
	if busy > 0 and avm_hard_stopped() then
		out("QUERY_SUPPRESSED reason=hard-stop page=" .. tostring(tonumber(a[7]) or -1))
		return
	end
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
		-- Every AVM-driven restart/resume is headless. Manual Search has no arm.
		-- AUXFAST_BeginScan is a global helper on purpose: after module("aux.core.scan")
		-- this closure resolves it through _G without capturing more file-scope locals.
		local headlessLoop, armedSource, scanId =
			AUXFAST_BeginScan(fullSearchScan, resumeRequested)
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
			if headlessLoop then
				AUXFAST_HeadlessRecord()
			elseif oldAuction then
				oldAuction(record)
			end
			if auxArbAttached and AVM_AuxArbAuction then pcall(AVM_AuxArbAuction, record) end
		end

		params.on_page_scanned = function()
			if headlessLoop then
				AUXFAST_HeadlessPage()
			elseif oldPageScanned then
				oldPageScanned()
			end
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
			AUXFAST_SearchScanLeave(params.type)
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
			if fullSearchScan then
				AUXFAST_EndScan(scanId, armedSource, headlessLoop, false, false)
			end
			pauseRequested = false
			pausePage = -1
			return result
		end
		params.on_abort = function()
			local arbPause = pauseRequested
			local workerPause = servicePauseRequested
			release()
			local result
			if oldAbort then result = oldAbort() end
			if fullSearchScan then
				AUXFAST_EndScan(scanId, armedSource, headlessLoop, true, arbPause)
			end
			pauseRequested = false
			if workerPause then
				servicePauseRequested = false
				servicePaused = true
				out("SERVICE_HANDOFF_PAUSED page=" .. tostring(queryPage) ..
					" hadScan=" .. tostring(servicePauseHadScan and true or false))
			end
			if arbPause and not workerPause and auxArbAttached and AVM_AuxArbPaused then
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
		AUXFAST_SearchScanEnter(params.type)
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
		if servicePauseRequested or servicePaused then
			local state = get_state()
			if state and state.id then abort(state.id) end
			return
		end
		if avm_hard_stopped() then
			local state = get_state()
			if state and state.id then abort(state.id) end
			return
		end
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

function AUXFAST_ServiceWorkerPause()
	if avm_hard_stopped() then return false, "hard-stop" end
	if servicePaused then return true, "paused" end

	-- Never tear down AH while a purchase/revalidation/AVM-owned transaction is
	-- outside the original AUX Search scan. The worker retries until it reaches
	-- a clean handoff point.
	if busy <= 0 and avm_busy() then
		return false, "avm-transaction"
	end

	if busy > 0 then
		servicePauseHadScan = true
		servicePauseRequested = true
		return false, "pending-submit-boundary"
	end

	servicePauseHadScan = false
	servicePauseRequested = false
	servicePaused = true
	out("SERVICE_HANDOFF_PAUSED idle=true")
	return true, "idle"
end

function AUXFAST_ServiceWorkerStatus()
	return {
		paused = servicePaused and true or false,
		pending = servicePauseRequested and true or false,
		busy = busy > 0,
		avmBusy = avm_busy() and true or false,
		hadScan = servicePauseHadScan and true or false,
	}
end

function AUXFAST_ServiceWorkerRelease()
	servicePauseRequested = false
	servicePaused = false
	servicePauseHadScan = false
	out("SERVICE_HANDOFF_RELEASED")
	return true
end

function AUXFAST_HardStop()
	AUXFAST_ClearHeadlessArm()
	resumeRequested = false
	pauseRequested = false
	servicePauseRequested = false
	servicePaused = false
	servicePauseHadScan = false
	pausePage = -1
	local aborted = false
	local state = get_state()
	if state and state.id then
		local ok = pcall(abort, state.id)
		aborted = ok and true or false
	end
	out("AH_HARD_STOP bridge busy=" .. tostring(busy > 0) .. " aborted=" .. tostring(aborted))
	return true
end

function AUXFAST_ResumeSearch()
	if avm_hard_stopped() then
		out("RESUME_SUPPRESSED reason=hard-stop source=resume")
		return false, "hard-stop"
	end
	if AUXFAST_SearchBusy() > 0 then
		out("resume deferred: original AUX Search scan is still busy")
		return false, "search-busy"
	end
	if not okSearchTab or not searchTab or not searchTab.execute then
		out("resume failed: aux.tabs.search unavailable")
		return false, "search-unavailable"
	end
	local stateOk, stateErr = ensure_search_resume_filter()
	if not stateOk then
		out("resume failed: " .. tostring(stateErr))
		return false, "filter:" .. tostring(stateErr)
	end
	resumeRequested = true
	-- Resume is AVM automation too. Re-arm headless explicitly so a post-scan
	-- transaction cannot fall back into upstream result rendering after the prior
	-- completed scan cleared headlessActive.
	AUXFAST_ArmHeadless("resume")
	local ok, err = pcall(searchTab.execute, true)
	if not ok then
		resumeRequested = false
		AUXFAST_ClearHeadlessArm()
		out("resume failed: " .. tostring(err))
		return false, "execute:" .. tostring(err)
	end
	if AUXFAST_SearchBusy() <= 0 then
		resumeRequested = false
		AUXFAST_ClearHeadlessArm()
		out("resume did not start a Search (check current AUX filter)")
		return false, "no-search"
	end
	out("resumed AVM search continuation headless")
	return true, "ok"
end

function AUXFAST_RestartSearch()
	if avm_hard_stopped() then
		out("RESUME_SUPPRESSED reason=hard-stop source=restart")
		return false
	end
	if AUXFAST_SearchBusy() > 0 then
		out("restart deferred: original AUX Search scan is still busy")
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
	local stateOk, stateErr = ensure_search_resume_filter()
	if not stateOk then
		out("restart failed: " .. tostring(stateErr))
		return false
	end
	resumeRequested = false
	AUXFAST_ArmHeadless("restart")
	-- Upstream execute(true) preserves the completed Search result table. With no
	-- continuation after a normal completion it still starts from page 0; the
	-- bridge's headless callbacks keep that UI snapshot while AVM evaluates fresh rows.
	local ok, err = pcall(searchTab.execute, true)
	if not ok then
		AUXFAST_ClearHeadlessArm()
		out("restart failed: " .. tostring(err))
		return false
	end
	if AUXFAST_SearchBusy() <= 0 then
		AUXFAST_ClearHeadlessArm()
		out("restart did not start a Search (check current AUX filter)")
		return false
	end
	out("restarted AUX loop headless from page 0; Search UI snapshot preserved")
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
		" avmBusy=" .. tostring(avm_busy() and true or false) ..
		" headless=" .. tostring(headlessState.active and true or false) ..
		" hPages=" .. tostring(headlessState.pages or 0) ..
		" hRecords=" .. tostring(headlessState.records or 0))
	out("lastScan id=" .. tostring(AuxFastBridgeDB.lastScanId or 0) ..
		" source=" .. tostring(AuxFastBridgeDB.lastScanSource or "none") ..
		" headless=" .. tostring(AuxFastBridgeDB.lastScanHeadless and true or false) ..
		" hPages=" .. tostring(AuxFastBridgeDB.lastHeadlessPages or 0) ..
		" hRecords=" .. tostring(AuxFastBridgeDB.lastHeadlessRecords or 0))
end

out("v3.6 loaded: list/owner busy separation + safe service handoff + headless resume; hook=" .. tostring(hookInstalled))
