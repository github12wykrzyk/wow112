-- AuxVmangos AutoSell lifecycle hardening for WoW 1.12.1 / AUX.
-- Keeps user loop intent separate from an in-flight scan/transaction and adds
-- fail-closed recovery/telemetry around the canonical AutoSell state machine.

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local scan = require 'aux.core.scan'
local post = require 'aux.core.post'

AVM_AUTOSELL_LIFECYCLE = AVM_AUTOSELL_LIFECYCLE or {}
local L = AVM_AUTOSELL_LIFECYCLE
L.slashInstalled = L.slashInstalled and true or false
L.tickInstalled = L.tickInstalled and true or false
L.scanWrapped = L.scanWrapped and true or false
L.cancelWrapped = L.cancelWrapped and true or false
L.postWrapped = L.postWrapped and true or false
L.bridgeWrapped = L.bridgeWrapped and true or false
L.pendingNormalized = L.pendingNormalized and true or false
L.nextTick = 0
L.sessionEpoch = tonumber(L.sessionEpoch) or 0
if L.sessionEpoch <= 0 then
	L.sessionEpoch = type(time) == 'function' and (tonumber(time()) or 0) or 0
end

local FLOOR_RETRY_SECONDS = 30
local PROBE_RETRY_SECONDS = 5
local POST_RECOVER_REFRESH_SECONDS = 10

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
	AVM_DB.autoSellStats = AVM_DB.autoSellStats or { cancels = 0, reposts = 0, probes = 0 }
	AVM_DB.autoSellHistory = AVM_DB.autoSellHistory or {}
	AVM_DB.autoSellLastMailEventAt = tonumber(AVM_DB.autoSellLastMailEventAt) or 0
	if AVM_DB.autoSellStats.cancelRequests == nil then
		AVM_DB.autoSellStats.cancelRequests = tonumber(AVM_DB.autoSellStats.cancels) or 0
	end
	if AVM_DB.autoSellStats.cancelConfirmed == nil then
		AVM_DB.autoSellStats.cancelConfirmed = tonumber(AVM_DB.autoSellStats.cancels) or 0
	end
	AVM_DB.autoSellStats.repostsRecovered = tonumber(AVM_DB.autoSellStats.repostsRecovered) or 0
	AVM_DB.autoSellStats.probeRetries = tonumber(AVM_DB.autoSellStats.probeRetries) or 0
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

local function find_pending_state(state)
	ensure_db()
	for key, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' and tostring(p.state or '') == tostring(state or '') then
			return tostring(key), p
		end
	end
	return nil, nil
end

local function map_persisted_cancel_clock(p)
	local epoch = tonumber(p.cancelRequestEpoch) or tonumber(p.createdAt) or 0
	if epoch <= 0 then return end
	p.cancelRequestEpoch = epoch
	local age = now_epoch() - epoch
	if age < 0 then age = 0 end
	if age > 604800 then age = 604800 end
	p.cancelAt = GetTime() - age
	p.cancelClockSession = L.sessionEpoch
end

local function normalize_pending_session()
	if L.pendingNormalized then return end
	ensure_db()
	for _, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' then
			p.cancelCounted = true -- existing counters are a historical baseline; do not double-count after update
			map_persisted_cancel_clock(p)
			local state = tostring(p.state or '')
			if state == 'REPRICE' then
				p.state = 'WAIT_REPRICE'
				p.repostVerifiedUnit = nil
				p.repostTargetUnit = nil
				p.retryAt = GetTime() + 1
				p.recovery = 'reload-reprice-retry'
			elseif state == 'POSTING' then
				p.state = 'POST_RECOVER'
				p.ownerGone = false
				p.postRecoverNeedsOwner = true
				p.postRecoverRequestedAt = 0
				p.retryAt = GetTime() + 1
				p.recovery = 'reload-posting-reconcile-owner'
			elseif state == 'FLOOR' then
				p.retryAt = GetTime() + FLOOR_RETRY_SECONDS
				p.floorRetryEpoch = now_epoch() + FLOOR_RETRY_SECONDS
			end
		end
	end
	L.pendingNormalized = true
end

local function pending_diag_rows()
	local rows = {}
	for key, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' then
			table.insert(rows, {
				key = tostring(key),
				signature = tostring(p.auctionSignature or ''),
				state = tostring(p.state or ''),
				count = tonumber(p.count) or 0,
				ownerGone = p.ownerGone and true or false,
				auctionGoneConfirmed = p.auctionGoneConfirmed and true or false,
				mailReady = p.mailReady and true or false,
				mailBagBaseline = tonumber(p.mailBagBaseline) or 0,
				mailBagCurrent = tonumber(p.mailBagCurrent) or 0,
				mailBagDelta = tonumber(p.mailBagDelta) or 0,
				lastProbeOutcome = tostring(p.lastProbeOutcome or ''),
				lastProbeReason = tostring(p.lastProbeReason or ''),
				cancelRequestEpoch = tonumber(p.cancelRequestEpoch) or 0,
				cancelConfirmedEpoch = tonumber(p.cancelConfirmedEpoch) or 0,
				postStartedEpoch = tonumber(p.postStartedEpoch) or 0,
				recovery = tostring(p.recovery or ''),
			})
		end
	end
	return rows
end

local function pending_prepare()
	ensure_db()
	normalize_pending_session()
	local pendingCount, guarded, ready, recovering = 0, 0, 0, 0
	for slot, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' then
			pendingCount = pendingCount + 1
			local itemKey = tostring(p.itemKey or slot or '')
			local count = tonumber(p.count) or 0
			if not p.auctionSignature or tostring(p.auctionSignature) == '' then
				p.auctionSignature = pending_signature(slot, p)
			end

			local state = tostring(p.state or '')
			if p.cancelClockSession ~= L.sessionEpoch and
			   (state == 'CANCELING' or state == 'CANCEL_SENT' or state == 'WAIT_MAIL') then
				map_persisted_cancel_clock(p)
			end

			if p.mailBagBaseline == nil and not p.ownerGone and
			   (state == 'CANCELING' or state == 'CANCEL_SENT' or state == 'WAIT_MAIL') then
				p.mailBagBaseline = bag_quantity(itemKey)
				p.mailGateEpoch = now_epoch()
				p.mailReady = false
			end

			if p.ownerGone then p.auctionGoneConfirmed = true end
			if p.auctionGoneConfirmed and p.cancelCounted == false then
				AVM_DB.autoSellStats.cancels = (tonumber(AVM_DB.autoSellStats.cancels) or 0) + 1
				AVM_DB.autoSellStats.cancelConfirmed = (tonumber(AVM_DB.autoSellStats.cancelConfirmed) or 0) + 1
				p.cancelCounted = true
				p.cancelConfirmedEpoch = now_epoch()
			end

			-- Preserve cancellation evidence separately. AutoSell's canonical engine
			-- may set ownerGone as soon as the own-auction snapshot confirms removal;
			-- lifecycle gating withholds that flag until mailbox + bag delta prove that
			-- the canceled stack became available for reposting. Per-auction mailbox
			-- identity is intentionally left for the next architecture iteration.
			if state ~= 'POST_RECOVER' and state ~= 'POST_RECOVER_BLOCKED' then
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

			state = tostring(p.state or '')
			if state == 'FLOOR' then
				local retryAt = tonumber(p.retryAt) or 0
				if retryAt <= 0 then
					p.retryAt = GetTime() + FLOOR_RETRY_SECONDS
					p.floorRetryEpoch = now_epoch() + FLOOR_RETRY_SECONDS
				end
			elseif state == 'POST_RECOVER' or state == 'POST_RECOVER_BLOCKED' then
				recovering = recovering + 1
				if state == 'POST_RECOVER_BLOCKED' and bag_quantity(itemKey) >= count and count > 0 then
					p.state = 'WAIT_REPRICE'
					p.ownerGone = true
					p.mailReady = true
					p.retryAt = GetTime() + 1
					p.recovery = 'post-recover-item-returned'
				else
					local last = tonumber(p.postRecoverRequestedAt) or 0
					if AVM_AUTOSELL and AVM_AUTOSELL.RequestOwnerRefresh and GetTime() - last >= POST_RECOVER_REFRESH_SECONDS then
						p.postRecoverRequestedAt = GetTime()
						p.postRecoverNeedsOwner = true
						AVM_AUTOSELL.RequestOwnerRefresh('post-recover')
					end
				end
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
		recovering = recovering,
		lastMailEventAt = tonumber(AVM_DB.autoSellLastMailEventAt) or 0,
		pendingRows = pending_diag_rows(),
		stats = {
			cancelRequests = tonumber(AVM_DB.autoSellStats.cancelRequests) or 0,
			cancelConfirmed = tonumber(AVM_DB.autoSellStats.cancelConfirmed) or 0,
			repostsRecovered = tonumber(AVM_DB.autoSellStats.repostsRecovered) or 0,
			probeRetries = tonumber(AVM_DB.autoSellStats.probeRetries) or 0,
		},
	}
end

local function install_scan_wrapper()
	if L.scanWrapped or not scan or type(scan.start) ~= 'function' then return L.scanWrapped end
	local rawStart = scan.start
	scan.start = function(opts)
		local key, p = find_pending_state('REPRICE')
		if key and p and type(opts) == 'table' then
			p.probeAttemptSerial = (tonumber(p.probeAttemptSerial) or 0) + 1
			p.lastProbeOutcome = 'running'
			p.lastProbeReason = ''
			local rawComplete = opts.on_complete
			local rawAbort = opts.on_abort
			if rawComplete then
				opts.on_complete = function()
					local current = AVM_DB and AVM_DB.autoSellPending and AVM_DB.autoSellPending[key]
					if current then
						current.lastProbeOutcome = 'complete'
						current.lastProbeReason = 'complete'
						current.probeCompleteEpoch = now_epoch()
					end
					return rawComplete()
				end
			end
			if rawAbort then
				opts.on_abort = function()
					local current = AVM_DB and AVM_DB.autoSellPending and AVM_DB.autoSellPending[key]
					if current then
						current.lastProbeOutcome = 'aborted'
						current.lastProbeReason = 'aborted'
						current.probeAbortEpoch = now_epoch()
					end
					return rawAbort()
				end
			end
		end
		return rawStart(opts)
	end
	L.scanWrapped = true
	return true
end

local function install_cancel_wrapper()
	if L.cancelWrapped or not aux or type(aux.cancel_auction) ~= 'function' then return L.cancelWrapped end
	local rawCancel = aux.cancel_auction
	aux.cancel_auction = function(index, callback)
		local key, p = find_pending_state('CANCEL_SENT')
		if p then
			ensure_db()
			p.cancelRequestEpoch = now_epoch()
			p.cancelAt = GetTime()
			p.cancelClockSession = L.sessionEpoch
			p.cancelCounted = false
			AVM_DB.autoSellStats.cancelRequests = (tonumber(AVM_DB.autoSellStats.cancelRequests) or 0) + 1
		end
		local wrapped = callback
		if callback and p then
			wrapped = function()
				ensure_db()
				local before = tonumber(AVM_DB.autoSellStats.cancels) or 0
				local result = callback()
				local after = tonumber(AVM_DB.autoSellStats.cancels) or 0
				-- Canonical AutoSell currently increments on the AUX callback. Restore
				-- the counter here; only owner-snapshot disappearance is confirmation.
				if after > before then AVM_DB.autoSellStats.cancels = before end
				local current = AVM_DB.autoSellPending and AVM_DB.autoSellPending[key]
				if current then current.cancelCallbackEpoch = now_epoch() end
				return result
			end
		end
		return rawCancel(index, wrapped)
	end
	L.cancelWrapped = true
	return true
end

local function install_post_wrapper()
	if L.postWrapped or not post or type(post.start) ~= 'function' then return L.postWrapped end
	local rawPost = post.start
	post.start = function(key, count, duration, startUnit, target, stacks, callback)
		local p = AVM_DB and AVM_DB.autoSellPending and AVM_DB.autoSellPending[tostring(key or '')]
		if type(p) == 'table' and tostring(p.state or '') == 'POSTING' then
			p.postStartedEpoch = now_epoch()
			p.postStartedCount = tonumber(count) or 0
			p.postStartedTarget = tonumber(target) or 0
		end
		return rawPost(key, count, duration, startUnit, target, stacks, callback)
	end
	L.postWrapped = true
	return true
end

local function owner_record_matches_post(p, record)
	if not p or not record then return false end
	if tostring(record.item_key or '') ~= tostring(p.itemKey or '') then return false end
	local count = tonumber(record.aux_quantity) or tonumber(record.count) or 0
	if count ~= (tonumber(p.count) or 0) then return false end
	local target = tonumber(p.repostTargetUnit) or tonumber(p.postStartedTarget) or 0
	if target <= 0 then return false end
	local buyout = tonumber(record.buyout_price) or 0
	local unit = tonumber(record.unit_buyout_price) or 0
	if unit <= 0 and buyout > 0 and count > 0 then unit = buyout / count end
	if math.abs(unit - target) < .5 then return true end
	local wanted = math.floor(target * count + .5)
	return wanted > 0 and buyout == wanted
end

local function reconcile_post_recovery(records)
	ensure_db()
	local remove = {}
	for key, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' and (p.state == 'POST_RECOVER' or p.state == 'POST_RECOVER_BLOCKED') then
			local found = false
			for i = 1, table.getn(records or {}) do
				if owner_record_matches_post(p, records[i]) then found = true; break end
			end
			if found then
				AVM_DB.autoSellStats.reposts = (tonumber(AVM_DB.autoSellStats.reposts) or 0) + 1
				AVM_DB.autoSellStats.repostsRecovered = (tonumber(AVM_DB.autoSellStats.repostsRecovered) or 0) + 1
				p.recovery = 'post-found-on-owner-snapshot'
				table.insert(remove, key)
			elseif bag_quantity(tostring(p.itemKey or key)) >= (tonumber(p.count) or 0) and (tonumber(p.count) or 0) > 0 then
				p.state = 'WAIT_REPRICE'
				p.ownerGone = true
				p.mailReady = true
				p.retryAt = GetTime() + 1
				p.postRecoverNeedsOwner = false
				p.recovery = 'post-not-found-item-still-in-bag'
			else
				p.state = 'POST_RECOVER_BLOCKED'
				p.ownerGone = false
				p.postRecoverNeedsOwner = true
				p.recovery = 'post-not-found-item-not-in-bag'
			end
		end
	end
	for i = 1, table.getn(remove) do AVM_DB.autoSellPending[remove[i]] = nil end
end

local function install_bridge_wrapper()
	if L.bridgeWrapped then return true end
	if not AVM_OWNER_SCAN_BRIDGE or type(AVM_OWNER_SCAN_BRIDGE.FeedAutoSellOwnerRecords) ~= 'function' then return false end
	local rawFeed = AVM_OWNER_SCAN_BRIDGE.FeedAutoSellOwnerRecords
	AVM_OWNER_SCAN_BRIDGE.FeedAutoSellOwnerRecords = function(records)
		local result = rawFeed(records)
		reconcile_post_recovery(records or {})
		pending_prepare()
		return result
	end
	L.bridgeWrapped = true
	return true
end

local function guard_probe_outcomes(before)
	ensure_db()
	for key, p in pairs(AVM_DB.autoSellPending or {}) do
		if type(p) == 'table' then
			local b = before and before[key]
			if b then
				local serial = tonumber(p.probeAttemptSerial) or 0
				local afterState = tostring(p.state or '')
				local transitioned = b.state ~= 'POST_READY' and b.state ~= 'FLOOR' and
					(afterState == 'POST_READY' or afterState == 'FLOOR')
				local attempted = serial > (tonumber(b.serial) or 0)
				if (attempted or transitioned) and afterState ~= 'REPRICE' and
				   tostring(p.lastProbeOutcome or '') ~= 'complete' then
					p.state = 'WAIT_REPRICE'
					p.repostVerifiedUnit = nil
					p.repostTargetUnit = nil
					p.retryAt = GetTime() + PROBE_RETRY_SECONDS
					p.recovery = 'probe-' .. tostring(p.lastProbeOutcome or 'unavailable') .. '-retry'
					p.lastProbeReason = tostring(p.lastProbeOutcome or 'query-unavailable')
					AVM_DB.autoSellStats.probeRetries = (tonumber(AVM_DB.autoSellStats.probeRetries) or 0) + 1
				end
			end
		end
	end
end

local function install_autosell_tick_wrapper()
	if L.tickInstalled then return true end
	if not AVM_AUTOSELL or type(AVM_AUTOSELL.Tick) ~= 'function' then return false end
	local oldTick = AVM_AUTOSELL.Tick
	AVM_AUTOSELL.Tick = function(now)
		pending_prepare()
		local before = {}
		for key, p in pairs(AVM_DB.autoSellPending or {}) do
			if type(p) == 'table' then
				before[key] = { state = tostring(p.state or ''), serial = tonumber(p.probeAttemptSerial) or 0 }
			end
		end
		local result = oldTick(now)
		guard_probe_outcomes(before)
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
L.Snapshot = function()
	pending_prepare()
	return AVM_DB and AVM_DB.diag and AVM_DB.diag.autoSellLifecycle or nil
end
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
	install_scan_wrapper()
	install_cancel_wrapper()
	install_post_wrapper()
	install_autosell_tick_wrapper()
	install_bridge_wrapper()
	install_slash_wrapper()
	if event == 'AUCTION_HOUSE_SHOW' then apply_loop_intent() end
end)
events:SetScript('OnUpdate', function()
	if GetTime() < (tonumber(L.nextTick) or 0) then return end
	L.nextTick = GetTime() + .10
	install_scan_wrapper()
	install_cancel_wrapper()
	install_post_wrapper()
	install_autosell_tick_wrapper()
	install_bridge_wrapper()
	install_slash_wrapper()
	pending_prepare()
	apply_loop_intent()
end)

ensure_db()
normalize_pending_session()
install_scan_wrapper()
install_cancel_wrapper()
install_post_wrapper()
install_autosell_tick_wrapper()
install_bridge_wrapper()
install_slash_wrapper()
pending_prepare()
