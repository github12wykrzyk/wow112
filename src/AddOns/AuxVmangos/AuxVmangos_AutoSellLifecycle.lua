-- AuxVmangos AutoSell lifecycle hardening for WoW 1.12.1 / AUX.
-- Keeps user loop intent separate from an in-flight scan/transaction and adds
-- concrete pending-auction/mail-retrieval evidence without creating a second
-- scanner, scheduler, or AutoSell state machine.

local T = require 'T'
local info = require 'aux.util.info'

AVM_AUTOSELL_LIFECYCLE = AVM_AUTOSELL_LIFECYCLE or {}
local L = AVM_AUTOSELL_LIFECYCLE
L.slashInstalled = L.slashInstalled and true or false
L.tickInstalled = L.tickInstalled and true or false
L.nextTick = 0

local function now_epoch()
	if type(time) == 'function' then return tonumber(time()) or 0 end
	return 0
end

local function ensure_db()
	AVM_DB = AVM_DB or {}
	if AVM_DB.auxLoopRequested == nil then
		AVM_DB.auxLoopRequested = AVM_DB.auxLoopEnabled ~= false
	end
	AVM_DB.autoSellPending = AVM_DB.autoSellPending or {}
	AVM_DB.autoSellLastMailEventAt = tonumber(AVM_DB.autoSellLastMailEventAt) or 0
end

local function chat(text)
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage('|cff60ff00[AVM Lifecycle]|r ' .. tostring(text or ''))
	end
end

local function trim(text)
	text = tostring(text or '')
	text = string.gsub(text, '^%s+', '')
	text = string.gsub(text, '%s+$', '')
	return text
end

local function bag_quantity(key)
	local total = 0
	if not key or key == '' then return 0 end
	for slot in info.inventory() do
		local ii = info.container_item(unpack(slot))
		if ii then
			if tostring(ii.item_key or '') == tostring(key) then
				total = total + (tonumber(ii.aux_quantity) or tonumber(ii.count) or 0)
			end
			T.release(ii)
		end
	end
	return total
end

local function scan_or_transaction_active()
	if not AVM then return false end
	if AVM.pending or AVM.unknown or AVM.queryInFlight or AVM.candidate or AVM.bidPending or AVM.bidCandidate then return true end
	if AVM.deExposure and AVM.deExposure.active then return true end
	if AVM.market and (AVM.market.active or AVM.market.requested) then return true end
	if AVM.vendor and (AVM.vendor.active or AVM.vendor.requested) then return true end
	local a = AVM.auxArb or {}
	if a.active or a.paused or a.pausePending or a.resumePending or a.candidate or a.deVerify or a.flipVerify or a.postscanCandidate then return true end
	local phase = tostring(AVM.phase or '')
	if phase ~= '' and phase ~= 'IDLE' and phase ~= 'WAIT_RULE' then return true end
	if AUXFAST_IsBusy then
		local ok, busy = pcall(AUXFAST_IsBusy)
		if ok and busy then return true end
	end
	return false
end

local function apply_loop_intent()
	ensure_db()
	if AVM_DB.auxLoopRequested ~= false then return false end
	if scan_or_transaction_active() then return false end
	local changed = AVM_DB.auxLoopEnabled ~= false
	AVM_DB.auxLoopEnabled = false
	if AVM and AVM.auxLoop then
		AVM.auxLoop.nextAt = 0
		AVM.auxLoop.waitingForMarket = false
		AVM.auxLoop.lastAction = 'loop-off-requested'
	end
	return changed
end

local function pending_signature(slot, p)
	return tostring(p.itemKey or slot or '') .. '|' ..
		tostring(tonumber(p.count) or 0) .. '|' ..
		tostring(tonumber(p.originalBuyout) or 0) .. '|' ..
		tostring(tonumber(p.sameCountBefore) or 0) .. '|' ..
		tostring(tonumber(p.createdAt) or 0)
end

local function pending_prepare()
	ensure_db()
	local pendingCount, guarded, ready = 0, 0, 0
	for slot, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' then
			pendingCount = pendingCount + 1
			local itemKey = tostring(p.itemKey or slot or '')
			local count = tonumber(p.count) or 0
			if not p.auctionSignature or tostring(p.auctionSignature) == '' then
				p.auctionSignature = pending_signature(slot, p)
			end

			local state = tostring(p.state or '')
			if p.mailBagBaseline == nil and not p.ownerGone and
			   (state == 'CANCELING' or state == 'CANCEL_SENT' or state == 'WAIT_MAIL') then
				p.mailBagBaseline = bag_quantity(itemKey)
				p.mailGateEpoch = now_epoch()
				p.mailReady = false
			end

			-- Preserve cancellation evidence separately. AutoSell's canonical engine
			-- may set ownerGone as soon as the own-auction snapshot confirms removal;
			-- lifecycle gating withholds that flag until mailbox + bag delta prove that
			-- the exact canceled stack became available for reposting.
			if p.ownerGone then p.auctionGoneConfirmed = true end
			if p.auctionGoneConfirmed and p.mailBagBaseline ~= nil and count > 0 then
				guarded = guarded + 1
				local current = bag_quantity(itemKey)
				p.mailBagCurrent = current
				p.mailBagDelta = current - (tonumber(p.mailBagBaseline) or 0)
				local mailSeen = (tonumber(AVM_DB.autoSellLastMailEventAt) or 0) >= (tonumber(p.mailGateEpoch) or 0)
				if mailSeen and p.mailBagDelta >= count then
					p.mailReady = true
					p.ownerGone = true
					ready = ready + 1
				else
					p.mailReady = false
					p.ownerGone = false
				end
			elseif p.mailReady then
				p.ownerGone = true
				ready = ready + 1
			end
		end
	end
	AVM_DB.diag = AVM_DB.diag or { seq = 0, events = {}, state = {} }
	AVM_DB.diag.autoSellLifecycle = {
		loopRequested = AVM_DB.auxLoopRequested ~= false,
		scanActive = scan_or_transaction_active(),
		pending = pendingCount,
		mailGuarded = guarded,
		mailReady = ready,
		lastMailEventAt = tonumber(AVM_DB.autoSellLastMailEventAt) or 0,
	}
end

local function install_autosell_tick_wrapper()
	if L.tickInstalled then return true end
	if not AVM_AUTOSELL or type(AVM_AUTOSELL.Tick) ~= 'function' then return false end
	local oldTick = AVM_AUTOSELL.Tick
	AVM_AUTOSELL.Tick = function(now)
		pending_prepare()
		local result = oldTick(now)
		pending_prepare()
		apply_loop_intent()
		return result
	end
	L.tickInstalled = true
	return true
end

local function install_slash_wrapper()
	if L.slashInstalled then return true end
	if not SlashCmdList or type(SlashCmdList['AUXVMANGOS']) ~= 'function' then return false end
	local oldSlash = SlashCmdList['AUXVMANGOS']
	SlashCmdList['AUXVMANGOS'] = function(msg)
		ensure_db()
		local normalized = string.lower(trim(msg))
		if normalized == 'loop off' then
			AVM_DB.auxLoopRequested = false
			if scan_or_transaction_active() then
				chat('LOOP OFF zapisany; bieżący scan/transaction kończy się normalnie, bez kolejnego restartu.')
			else
				apply_loop_intent()
				chat('LOOP OFF zapisany; brak automatycznego restartu.')
			end
			return
		elseif normalized == 'loop on' then
			AVM_DB.auxLoopRequested = true
			oldSlash(msg)
			return
		elseif normalized == 'off' then
			AVM_DB.auxLoopRequested = false
			oldSlash(msg)
			return
		elseif normalized == 'on' then
			AVM_DB.auxLoopRequested = true
			oldSlash(msg)
			return
		elseif normalized == 'auxarb off' then
			AVM_DB.auxLoopRequested = false
			oldSlash(msg)
			return
		elseif normalized == 'loop status' then
			oldSlash(msg)
			chat('loopRequested=' .. tostring(AVM_DB.auxLoopRequested ~= false) ..
				' scanActive=' .. tostring(scan_or_transaction_active()))
			return
		end
		oldSlash(msg)
		apply_loop_intent()
	end
	L.slashInstalled = true
	return true
end

L.ScanActive = scan_or_transaction_active
L.ApplyLoopIntent = apply_loop_intent
L.PendingPrepare = pending_prepare
L.Status = function()
	ensure_db()
	return {
		loopRequested = AVM_DB.auxLoopRequested ~= false,
		loopEnabled = AVM_DB.auxLoopEnabled and true or false,
		scanActive = scan_or_transaction_active(),
	}
end

local events = CreateFrame('Frame', 'AuxVmangosAutoSellLifecycleEvents')
events:RegisterEvent('ADDON_LOADED')
events:RegisterEvent('PLAYER_LOGIN')
events:RegisterEvent('AUCTION_HOUSE_SHOW')
events:RegisterEvent('MAIL_INBOX_UPDATE')
events:SetScript('OnEvent', function()
	ensure_db()
	if event == 'MAIL_INBOX_UPDATE' then
		AVM_DB.autoSellLastMailEventAt = now_epoch()
		pending_prepare()
		return
	end
	install_autosell_tick_wrapper()
	install_slash_wrapper()
	if event == 'AUCTION_HOUSE_SHOW' then apply_loop_intent() end
end)
events:SetScript('OnUpdate', function()
	if GetTime() < (tonumber(L.nextTick) or 0) then return end
	L.nextTick = GetTime() + .10
	install_autosell_tick_wrapper()
	install_slash_wrapper()
	pending_prepare()
	apply_loop_intent()
end)

ensure_db()
install_autosell_tick_wrapper()
install_slash_wrapper()
pending_prepare()
