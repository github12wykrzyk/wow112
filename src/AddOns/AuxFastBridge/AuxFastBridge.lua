-- AuxFastBridge v1.1
-- Keeps the original Aux state machine/GUI intact and removes only its client-side
-- CanSendAuctionQuery wait while an Aux scan is active. Aux itself advances only
-- after AUCTION_ITEM_LIST_UPDATE, so transport remains one-response-per-next-query.
AuxFastBridgeDB = AuxFastBridgeDB or {}

local originalCanSendAuctionQuery = CanSendAuctionQuery
local okScan, scan = pcall(require, "aux.core.scan")
local busy = 0
local pageEvents = 0
local startedAt = 0
local bypassChecks = 0
local hookInstalled = false

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

function AUXFAST_Status()
	return {
		busy = busy > 0,
		pageEvents = pageEvents,
		bypassChecks = bypassChecks,
		startedAt = startedAt,
		hookInstalled = hookInstalled,
	}
end

local function install_scan_hook()
	if not okScan or not scan or not scan.start then return false end
	local originalStart = scan.start

	-- aux-addon-vanilla exports modules through a read-only interface proxy:
	-- assigning scan.start directly is silently ignored by libs/package.lua.
	-- Enter the real module environment and publish through M.start instead.
	module "aux.core.scan"
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
				AuxFastBridgeDB.lastPages = pageEvents
				AuxFastBridgeDB.lastDuration = startedAt > 0 and (GetTime() - startedAt) or 0
				AuxFastBridgeDB.lastBypassChecks = bypassChecks
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
			pageEvents = 0
			bypassChecks = 0
			startedAt = GetTime()
		end
		busy = busy + 1
		return originalStart(params)
	end
	hookInstalled = true
	return true
end

if not install_scan_hook() then
	out("ERROR: aux.core.scan unavailable; fast transport disabled")
end

CanSendAuctionQuery = function(...)
	if busy > 0 and not avm_busy() then
		bypassChecks = bypassChecks + 1
		return true
	end
	if originalCanSendAuctionQuery then
		return originalCanSendAuctionQuery(unpack(arg or {}))
	end
	return true
end

local f = CreateFrame("Frame")
f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
f:SetScript("OnEvent", function()
	if busy > 0 then pageEvents = pageEvents + 1 end
end)

SLASH_AUXFAST1 = "/auxfast"
SlashCmdList["AUXFAST"] = function()
	local duration = startedAt > 0 and (GetTime() - startedAt) or 0
	out("hook=" .. tostring(hookInstalled) ..
		" busy=" .. tostring(busy > 0) ..
		" pages=" .. tostring(pageEvents) ..
		" bypass=" .. tostring(bypassChecks) ..
		" elapsed=" .. string.format("%.1f", duration) .. "s" ..
		" avmBusy=" .. tostring(avm_busy() and true or false))
end

out("v1.1 loaded: original Aux GUI/state machine + response-paced query gate bypass; hook=" .. tostring(hookInstalled))
