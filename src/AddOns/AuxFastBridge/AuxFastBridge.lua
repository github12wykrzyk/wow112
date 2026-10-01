-- AuxFastBridge v1.3
-- Original AUX GUI/state machine with native 0x025C response correlation.
-- The next list query is allowed only after the previous real server response has
-- passed through the verified WoW 5875 auction result handler.
AuxFastBridgeDB = AuxFastBridgeDB or {}

local originalCanSendAuctionQuery = CanSendAuctionQuery
local originalQueryAuctionItems = QueryAuctionItems
local okScan, scan = pcall(require, "aux.core.scan")
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

local awaitNativeSeq = 0
local querySentAt = 0
local queryPage = -1
local NATIVE_WAIT_TIMEOUT = 1.50

local function out(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ff99[AUX FAST]|r " .. tostring(msg))
	end
end

local function avm_busy()
	return AVM and (
		AVM.queryInFlight or AVM.pending or AVM.unknown or
		(AVM.market and (AVM.market.active or AVM.market.requested)) or
		(AVM.vendor and (AVM.vendor.active or AVM.vendor.requested))
	)
end

function AUXFAST_IsBusy()
	return busy > 0
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
		local oldComplete = params.on_complete
		local oldAbort = params.on_abort
		local released = false

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
				AuxFastBridgeDB.lastBypassChecks = bypassChecks
				AuxFastBridgeDB.lastDuration = startedAt > 0 and (GetTime() - startedAt) or 0
			end
		end

		params.on_complete = function()
			release()
			if oldComplete then return oldComplete() end
		end
		params.on_abort = function()
			release()
			if oldAbort then return oldAbort() end
		end

		if busy == 0 then
			uiEvents = 0
			bypassChecks = 0
			queryCount = 0
			nativeResults = 0
			matchedResults = 0
			nativeTimeouts = 0
			queryPage = -1
			startedAt = GetTime()
		end

		busy = busy + 1
		return originalStart(params)
	end

	wait_for_list_results = function()
		local expectedSeq = awaitNativeSeq
		local sentAt = querySentAt
		local ignoreOwner = get_state().params.ignore_owner or auxCore.account_data.ignore_owner

		return auxCore.when(function()
			if nativeSeq > expectedSeq then
				if ignoreOwner or owner_data_complete() then
					return true
				end
				-- Preserve original owner-resolution tolerance for the uncommon
				-- mode that explicitly requires seller names.
				if nativeAt > 0 and GetTime() - nativeAt >= 5 then
					return true
				end
			end
			if sentAt > 0 and GetTime() - sentAt >= NATIVE_WAIT_TIMEOUT then
				return true
			end
		end, function()
			if nativeSeq > expectedSeq then
				matchedResults = matchedResults + 1
				return accept_results()
			end

			-- Native correlation should normally resolve first. If the verified
			-- callback is unavailable, fall back to upstream AUX semantics rather
			-- than issuing overlapping/reordered requests.
			nativeTimeouts = nativeTimeouts + 1
			return originalWaitForListResults()
		end)
	end

	hookInstalled = true
	return true
end

if not install_scan_hook() then
	out("ERROR: aux.core.scan unavailable; fast transport disabled")
end

CanSendAuctionQuery = function(...)
	local ready = true
	if originalCanSendAuctionQuery then
		ready = originalCanSendAuctionQuery(unpack(arg or {}))
	end
	if busy > 0 and not avm_busy() then
		if not ready then bypassChecks = bypassChecks + 1 end
		return true
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
		" timeouts=" .. tostring(nativeTimeouts))
	out("uiEvents=" .. tostring(uiEvents) ..
		" bypass=" .. tostring(bypassChecks) ..
		" page=" .. tostring(queryPage) ..
		" elapsed=" .. string.format("%.1f", duration) .. "s" ..
		" avmBusy=" .. tostring(avm_busy() and true or false))
end

out("v1.3 loaded: original AUX + native response correlation; hook=" .. tostring(hookInstalled))
