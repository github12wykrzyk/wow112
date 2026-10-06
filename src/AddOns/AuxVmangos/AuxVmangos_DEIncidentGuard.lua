-- AuxVmangos DE incident guard v1.
-- Fail-closed live-DE controller added after the 2026-10-05 Nether Essence price-shock incident.
-- Vendor BUY is intentionally untouched: this module gates only DE economics by controlling
-- AVM_DB.deMinProfit / bidDeEnabled and by observing DE material prices.

AVM_DE_INCIDENT_GUARD_VERSION = "1.0"

local AVM_DE_GUARD_SENTINEL = 2147483647
local AVM_DE_GUARD_TICK = 0.10
local AVM_DE_GUARD_MATERIALS = {
	[10940]=true,[10938]=true,[10939]=true,[10978]=true,[10998]=true,
	[11083]=true,[11082]=true,[11084]=true,[11134]=true,[11138]=true,
	[11137]=true,[11135]=true,[11139]=true,[11174]=true,[11177]=true,
	[11176]=true,[11175]=true,[11178]=true,[16202]=true,[14343]=true,
	[16204]=true,[16203]=true,[14344]=true,[20725]=true,
}

local AVM_DE_GUARD_HISTORY_OK, AVM_DE_GUARD_HISTORY = pcall(require, "aux.core.history")
local AVM_DE_GUARD_RUNTIME = {
	nextTick = 0,
	liveBook = {},
	lastScanToken = 0,
	lastWarmSeen = {},
	lastExactSerial = {},
	wrapped = false,
	original = {},
}

local function avm_de_guard_epoch()
	if type(time) == "function" then return tonumber(time()) or 0 end
	return 0
end

local function avm_de_guard_now()
	return tonumber(GetTime()) or 0
end

local function avm_de_guard_money(v)
	v = math.floor(tonumber(v) or 0)
	local g = math.floor(v / 10000)
	local s = math.floor(math.mod(v, 10000) / 100)
	local c = math.mod(v, 100)
	if g > 0 then return tostring(g) .. "g" .. tostring(s) .. "s" .. tostring(c) .. "c" end
	if s > 0 then return tostring(s) .. "s" .. tostring(c) .. "c" end
	return tostring(c) .. "c"
end

local function avm_de_guard_log(msg)
	local text = "|cffffb000[AVM-DE-GUARD]|r " .. tostring(msg)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(text) end
	if AVM_DB then
		AVM_DB.diag = AVM_DB.diag or { seq = 0, events = {}, state = {} }
		AVM_DB.diag.events = AVM_DB.diag.events or {}
		AVM_DB.diag.seq = (tonumber(AVM_DB.diag.seq) or 0) + 1
		table.insert(AVM_DB.diag.events,
			tostring(AVM_DB.diag.seq) .. "@" .. tostring(math.floor(avm_de_guard_now() * 1000)) ..
			" DE_GUARD " .. tostring(msg))
		while table.getn(AVM_DB.diag.events) > 80 do table.remove(AVM_DB.diag.events, 1) end
	end
end

local function avm_de_guard_defaults()
	if not AVM_DB then AVM_DB = {} end
	local g = AVM_DB.deIncidentGuard
	if type(g) ~= "table" then g = {}; AVM_DB.deIncidentGuard = g end

	if g.schema == nil then g.schema = 1 end
	if g.armed == nil then g.armed = false end
	if g.shockPct == nil then g.shockPct = 20 end
	if g.confirmBandPct == nil then g.confirmBandPct = 10 end
	if g.confirmGapSeconds == nil then g.confirmGapSeconds = 900 end
	if g.confirmRequired == nil then g.confirmRequired = 3 end
	if g.minDepth == nil then g.minDepth = 10 end
	if g.staleSeconds == nil then g.staleSeconds = 180 end
	if g.maxSessionBuys == nil then g.maxSessionBuys = 10 end
	if g.maxSessionSpend == nil then g.maxSessionSpend = 150000 end -- 15g
	if g.maxPerDeId == nil then g.maxPerDeId = 3 end
	if g.maxCandidates == nil then g.maxCandidates = 100 end
	if g.trusted == nil then g.trusted = {} end
	if g.session == nil then g.session = {} end
	if g.lastReason == nil then g.lastReason = "not-armed" end
	if g.gateApplied == nil then g.gateApplied = false end

	if g.desiredMinProfit == nil then
		local current = tonumber(AVM_DB.deMinProfit)
		if current and current > 0 and current < AVM_DE_GUARD_SENTINEL then
			g.desiredMinProfit = current
		else
			g.desiredMinProfit = 5000
		end
	end
	if g.desiredBidDeEnabled == nil then
		g.desiredBidDeEnabled = AVM_DB.bidDeEnabled ~= false
	end
	return g
end

local function avm_de_guard_history_value(itemId)
	if not AVM_DE_GUARD_HISTORY_OK or not AVM_DE_GUARD_HISTORY or
	   type(AVM_DE_GUARD_HISTORY.value) ~= "function" then return 0, "" end
	local keys = {
		tostring(itemId) .. ":0",
		tostring(itemId) .. ":0:0",
		"item:" .. tostring(itemId) .. ":0:0:0",
	}
	for i = 1, table.getn(keys) do
		local ok, value = pcall(AVM_DE_GUARD_HISTORY.value, keys[i])
		value = ok and tonumber(value) or 0
		if value and value > 0 then return math.floor(value), keys[i] end
	end
	return 0, ""
end

local function avm_de_guard_seed_anchor(g, itemId)
	local t = g.trusted[itemId]
	if type(t) ~= "table" then t = {}; g.trusted[itemId] = t end
	if (tonumber(t.anchor) or 0) > 0 then return t end
	local hist, key = avm_de_guard_history_value(itemId)
	if hist > 0 then
		t.anchor = hist
		t.anchorSource = "aux-history"
		t.historyKey = key
		t.seedAt = avm_de_guard_epoch()
		t.confirmations = 0
		t.quarantined = false
	end
	return t
end

local function avm_de_guard_observe(itemId, floor, source, canConfirm)
	local g = avm_de_guard_defaults()
	itemId = tonumber(itemId)
	floor = math.floor(tonumber(floor) or 0)
	if not itemId or not AVM_DE_GUARD_MATERIALS[itemId] or floor <= 0 then return end
	local t = avm_de_guard_seed_anchor(g, itemId)
	t.lastFloor = floor
	t.lastSource = tostring(source or "")
	t.lastSeenAt = avm_de_guard_epoch()

	local anchor = tonumber(t.anchor) or 0
	if anchor <= 0 then
		t.quarantined = true
		t.reason = "history-missing"
		return
	end

	local shockPct = tonumber(g.shockPct) or 20
	local highLimit = anchor * (100 + shockPct) / 100
	if floor <= highLimit then
		-- Downward movement is conservative for DE valuation, so trust it immediately.
		if floor < anchor then
			t.anchor = floor
			t.anchorSource = tostring(source or "live") .. "-down"
		end
		t.quarantined = false
		t.reason = ""
		t.candidate = 0
		t.confirmations = 0
		t.lastConfirmAt = 0
		return
	end

	t.quarantined = true
	t.reason = "price-shock"
	local candidate = tonumber(t.candidate) or 0
	local band = tonumber(g.confirmBandPct) or 10
	local sameBand = false
	if candidate > 0 then
		local lo = candidate * (100 - band) / 100
		local hi = candidate * (100 + band) / 100
		sameBand = floor >= lo and floor <= hi
	end

	if not canConfirm then
		if candidate <= 0 then t.candidate = floor end
		return
	end

	local epoch = avm_de_guard_epoch()
	local gap = tonumber(g.confirmGapSeconds) or 900
	if candidate <= 0 or not sameBand then
		t.candidate = floor
		t.confirmations = 1
		t.lastConfirmAt = epoch
	elseif epoch > 0 and epoch - (tonumber(t.lastConfirmAt) or 0) >= gap then
		t.confirmations = (tonumber(t.confirmations) or 0) + 1
		t.lastConfirmAt = epoch
		t.candidate = math.floor((candidate + floor) / 2)
	end

	if (tonumber(t.confirmations) or 0) >= (tonumber(g.confirmRequired) or 3) then
		t.anchor = math.floor(tonumber(t.candidate) or floor)
		t.anchorSource = "independent-live-confirmations"
		t.promotedAt = epoch
		t.quarantined = false
		t.reason = ""
		t.candidate = 0
		t.confirmations = 0
		t.lastConfirmAt = 0
		avm_de_guard_log("ANCHOR_PROMOTED item=" .. tostring(itemId) ..
			" anchor=" .. avm_de_guard_money(t.anchor))
	end
end

local function avm_de_guard_book_add(record)
	if not record then return end
	local itemId = tonumber(record.item_id or record.itemId)
	if not itemId or not AVM_DE_GUARD_MATERIALS[itemId] then return end
	local count = tonumber(record.count or record.aux_quantity) or 0
	local buyout = tonumber(record.buyout_price or record.buyout) or 0
	if count <= 0 or buyout <= 0 then return end
	if record.owner and record.owner == UnitName("player") then return end

	local b = AVM_DE_GUARD_RUNTIME.liveBook[itemId]
	if not b then b = { units = 0, offers = {} }; AVM_DE_GUARD_RUNTIME.liveBook[itemId] = b end
	local unit = math.floor(buyout / count)
	if unit <= 0 then return end
	table.insert(b.offers, { unit = unit, count = count })
	b.units = b.units + count

	local g = avm_de_guard_defaults()
	local depth = math.max(1, math.floor(tonumber(g.minDepth) or 10))
	if b.units < depth then return end
	table.sort(b.offers, function(a, c)
		if a.unit ~= c.unit then return a.unit < c.unit end
		return a.count > c.count
	end)
	local units = 0
	for i = 1, table.getn(b.offers) do
		units = units + (tonumber(b.offers[i].count) or 0)
		if units >= depth then
			avm_de_guard_observe(itemId, b.offers[i].unit, "aux-live-external", true)
			return
		end
	end
end

local function avm_de_guard_observe_core_books()
	local g = avm_de_guard_defaults()

	-- Warm book is useful for detecting shocks/staleness but is not trusted for
	-- upward confirmations because core warm depth can include own auctions.
	local warm = AVM_DB and AVM_DB.deWarmMaterialBook or nil
	if type(warm) == "table" then
		for itemId, row in pairs(warm) do
			itemId = tonumber(itemId)
			if itemId and AVM_DE_GUARD_MATERIALS[itemId] and type(row) == "table" then
				local seenAt = tonumber(row.seenAt) or 0
				if seenAt > 0 and AVM_DE_GUARD_RUNTIME.lastWarmSeen[itemId] ~= seenAt then
					AVM_DE_GUARD_RUNTIME.lastWarmSeen[itemId] = seenAt
					if (tonumber(row.depth) or 0) >= (tonumber(g.minDepth) or 10) then
						avm_de_guard_observe(itemId, row.floor, "core-warm", false)
					end
				end
			end
		end
	end

	-- Exact-cache prices are also block-only evidence: they are fresh but core
	-- exact material queries do not retain owner identity.
	local a = AVM and AVM.auxArb or nil
	local exact = a and a.deExactCache or nil
	if type(exact) == "table" then
		for itemId, row in pairs(exact) do
			itemId = tonumber(itemId)
			if itemId and AVM_DE_GUARD_MATERIALS[itemId] and type(row) == "table" then
				local serial = tonumber(row.serial) or 0
				if serial > 0 and AVM_DE_GUARD_RUNTIME.lastExactSerial[itemId] ~= serial then
					AVM_DE_GUARD_RUNTIME.lastExactSerial[itemId] = serial
					if (tonumber(row.depth) or 0) >= (tonumber(g.minDepth) or 10) then
						avm_de_guard_observe(itemId, row.floor, "core-exact", false)
					end
				end
			end
		end
	end
end

local function avm_de_guard_candidate()
	if AVM and AVM.candidate and
	   (AVM.candidate.mode == "auxarb_de" or AVM.candidate.route == "disenchant") then
		return AVM.candidate
	end
	local a = AVM and AVM.auxArb or nil
	if a and a.deVerify and a.deVerify.candidate then return a.deVerify.candidate end
	if a and a.candidate and
	   (a.candidate.mode == "auxarb_de" or a.candidate.route == "disenchant") then
		return a.candidate
	end
	return nil
end

local function avm_de_guard_candidate_health()
	local g = avm_de_guard_defaults()
	local c = avm_de_guard_candidate()
	if not c then return true, "" end
	local mats = c.materials or {}
	for i = 1, table.getn(mats) do
		local itemId = tonumber(mats[i] and mats[i].itemId)
		if itemId and AVM_DE_GUARD_MATERIALS[itemId] then
			local t = avm_de_guard_seed_anchor(g, itemId)
			if (tonumber(t.anchor) or 0) <= 0 then
				return false, "history-missing:" .. tostring(itemId)
			end
			if t.quarantined then
				return false, tostring(t.reason or "quarantine") .. ":" .. tostring(itemId)
			end
			local warm = AVM_DB.deWarmMaterialBook and AVM_DB.deWarmMaterialBook[itemId] or nil
			if warm and tonumber(warm.seenAt) and avm_de_guard_epoch() > 0 then
				local age = avm_de_guard_epoch() - tonumber(warm.seenAt)
				if age > (tonumber(g.staleSeconds) or 180) then
					return false, "stale-material:" .. tostring(itemId)
				end
			end
		end
	end
	return true, ""
end

local function avm_de_guard_sync_session()
	local g = avm_de_guard_defaults()
	local s = g.session
	if s.startedSeq == nil then s.startedSeq = tonumber(AVM_DB.purchaseHistorySeq) or 0 end
	if s.lastSeq == nil then s.lastSeq = s.startedSeq end
	if s.buys == nil then s.buys = 0 end
	if s.spend == nil then s.spend = 0 end
	if s.deids == nil then s.deids = {} end

	local h = AVM_DB.purchaseHistory or {}
	for i = 1, table.getn(h) do
		local row = h[i]
		local seq = tonumber(row and row.seq) or 0
		if seq > (tonumber(s.lastSeq) or 0) then
			if tostring(row.confirmation or "") == "confirmed" and
			   tostring(row.route or "") == "disenchant" then
				s.buys = (tonumber(s.buys) or 0) + 1
				s.spend = (tonumber(s.spend) or 0) + (tonumber(row.buyout) or 0)
				local did = tonumber(row.disenchantId) or 0
				s.deids[did] = (tonumber(s.deids[did]) or 0) + 1
			end
			if seq > (tonumber(s.lastSeq) or 0) then s.lastSeq = seq end
		end
	end

	if (tonumber(g.maxSessionBuys) or 0) > 0 and
	   (tonumber(s.buys) or 0) >= tonumber(g.maxSessionBuys) then
		g.tripped = true
		g.tripReason = "session-buy-cap"
	end
	if (tonumber(g.maxSessionSpend) or 0) > 0 and
	   (tonumber(s.spend) or 0) >= tonumber(g.maxSessionSpend) then
		g.tripped = true
		g.tripReason = "session-spend-cap"
	end
	local per = tonumber(g.maxPerDeId) or 0
	if per > 0 then
		for did, n in pairs(s.deids) do
			if tonumber(did) and tonumber(did) > 0 and (tonumber(n) or 0) >= per then
				g.tripped = true
				g.tripReason = "deid-cap:" .. tostring(did)
			end
		end
	end
end

local function avm_de_guard_health()
	local g = avm_de_guard_defaults()
	if not g.armed then return false, "not-armed" end
	if g.tripped then return false, tostring(g.tripReason or "tripped") end
	local a = AVM and AVM.auxArb or nil
	if a then
		local candidates = tonumber(a.deCandidates) or 0
		local raw = table.getn(a.deRawCandidates or {})
		local n = candidates
		if raw > n then n = raw end
		if (tonumber(g.maxCandidates) or 0) > 0 and n > tonumber(g.maxCandidates) then
			return false, "candidate-explosion:" .. tostring(n)
		end
	end
	for itemId, t in pairs(g.trusted or {}) do
		if AVM_DE_GUARD_MATERIALS[tonumber(itemId)] and type(t) == "table" and t.quarantined then
			return false, tostring(t.reason or "quarantine") .. ":" .. tostring(itemId)
		end
	end
	return avm_de_guard_candidate_health()
end

local function avm_de_guard_apply()
	local g = avm_de_guard_defaults()
	local current = tonumber(AVM_DB.deMinProfit)
	if g.gateApplied then
		-- Preserve explicit user threshold changes made while the safety gate is closed.
		if current and current > 0 and current < AVM_DE_GUARD_SENTINEL then
			g.desiredMinProfit = current
		end
	else
		if current and current > 0 and current < AVM_DE_GUARD_SENTINEL then
			g.desiredMinProfit = current
		end
		g.desiredBidDeEnabled = AVM_DB.bidDeEnabled ~= false
	end

	local ok, reason = avm_de_guard_health()
	if not ok then
		if not g.gateApplied then
			avm_de_guard_log("BLOCK reason=" .. tostring(reason))
		end
		g.lastReason = reason
		g.gateApplied = true
		AVM_DB.deMinProfit = AVM_DE_GUARD_SENTINEL
		AVM_DB.bidDeEnabled = false
		return false, reason
	end

	if g.gateApplied then
		AVM_DB.deMinProfit = tonumber(g.desiredMinProfit) or 5000
		AVM_DB.bidDeEnabled = g.desiredBidDeEnabled and true or false
		g.gateApplied = false
		g.lastReason = "healthy"
		avm_de_guard_log("ALLOW minProfit=" .. avm_de_guard_money(AVM_DB.deMinProfit))
	end
	return true, "healthy"
end

local function avm_de_guard_reset_session()
	local g = avm_de_guard_defaults()
	g.tripped = false
	g.tripReason = ""
	g.session = {
		startedSeq = tonumber(AVM_DB.purchaseHistorySeq) or 0,
		lastSeq = tonumber(AVM_DB.purchaseHistorySeq) or 0,
		buys = 0, spend = 0, deids = {},
	}
end

local function avm_de_guard_arm()
	local g = avm_de_guard_defaults()
	g.armed = true
	avm_de_guard_reset_session()
	avm_de_guard_observe_core_books()
	local ok, reason = avm_de_guard_apply()
	if ok then
		avm_de_guard_log("ARMED healthy")
	else
		avm_de_guard_log("ARMED_BUT_BLOCKED reason=" .. tostring(reason))
	end
end

local function avm_de_guard_disarm(reason)
	local g = avm_de_guard_defaults()
	g.armed = false
	g.tripped = false
	g.tripReason = ""
	avm_de_guard_apply()
	avm_de_guard_log("DISARMED reason=" .. tostring(reason or "manual"))
end

local function avm_de_guard_status()
	local g = avm_de_guard_defaults()
	local s = g.session or {}
	local ok, reason = avm_de_guard_health()
	avm_de_guard_log("STATUS armed=" .. tostring(g.armed and true or false) ..
		" gate=" .. tostring(ok and "OPEN" or "BLOCKED") ..
		" reason=" .. tostring(reason) ..
		" deMin=" .. avm_de_guard_money(g.desiredMinProfit or 0) ..
		" buys=" .. tostring(s.buys or 0) .. "/" .. tostring(g.maxSessionBuys or 0) ..
		" spend=" .. avm_de_guard_money(s.spend or 0) .. "/" .. avm_de_guard_money(g.maxSessionSpend or 0))
end

local function avm_de_guard_wrap()
	if AVM_DE_GUARD_RUNTIME.wrapped then return end
	if type(AVM_AuxArbScanStart) == "function" then
		AVM_DE_GUARD_RUNTIME.original.ScanStart = AVM_AuxArbScanStart
		AVM_AuxArbScanStart = function(resume, filterString)
			AVM_DE_GUARD_RUNTIME.liveBook = {}
			AVM_DE_GUARD_RUNTIME.lastScanToken = AVM_DE_GUARD_RUNTIME.lastScanToken + 1
			avm_de_guard_observe_core_books()
			avm_de_guard_apply()
			return AVM_DE_GUARD_RUNTIME.original.ScanStart(resume, filterString)
		end
	end
	if type(AVM_AuxArbAuction) == "function" then
		AVM_DE_GUARD_RUNTIME.original.Auction = AVM_AuxArbAuction
		AVM_AuxArbAuction = function(record)
			avm_de_guard_book_add(record)
			avm_de_guard_observe_core_books()
			avm_de_guard_apply()
			return AVM_DE_GUARD_RUNTIME.original.Auction(record)
		end
	end
	if type(AVM_AuxArbPageDone) == "function" then
		AVM_DE_GUARD_RUNTIME.original.PageDone = AVM_AuxArbPageDone
		AVM_AuxArbPageDone = function(page, lastPage)
			avm_de_guard_observe_core_books()
			avm_de_guard_apply()
			return AVM_DE_GUARD_RUNTIME.original.PageDone(page, lastPage)
		end
	end
	if type(AVM_AuxArbScanDone) == "function" then
		AVM_DE_GUARD_RUNTIME.original.ScanDone = AVM_AuxArbScanDone
		AVM_AuxArbScanDone = function()
			avm_de_guard_observe_core_books()
			avm_de_guard_apply()
			return AVM_DE_GUARD_RUNTIME.original.ScanDone()
		end
	end
	AVM_DE_GUARD_RUNTIME.wrapped = true
end

SLASH_AVMDEGUARD1 = "/avmde"
SlashCmdList["AVMDEGUARD"] = function(msg)
	local text = string.lower(tostring(msg or ""))
	local _,_,cmd = string.find(text, "^%s*(%S+)")
	if cmd == "arm" or cmd == "on" then
		avm_de_guard_arm()
	elseif cmd == "off" or cmd == "disarm" then
		avm_de_guard_disarm("manual")
	elseif cmd == "reset" then
		avm_de_guard_reset_session()
		avm_de_guard_apply()
		avm_de_guard_status()
	else
		avm_de_guard_status()
		avm_de_guard_log("commands: /avmde arm | off | reset | status")
	end
end

local avm_de_guard_frame = CreateFrame("Frame")
avm_de_guard_frame:RegisterEvent("ADDON_LOADED")
avm_de_guard_frame:RegisterEvent("PLAYER_LOGIN")
avm_de_guard_frame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "AuxVmangos" then
		local g = avm_de_guard_defaults()
		-- Every client/reload starts fail-closed. Explicit arm is session-local.
		g.armed = false
		g.tripped = false
		g.tripReason = ""
		avm_de_guard_wrap()
		avm_de_guard_observe_core_books()
		avm_de_guard_apply()
	elseif event == "PLAYER_LOGIN" then
		local g = avm_de_guard_defaults()
		g.armed = false
		g.tripped = false
		g.tripReason = ""
		avm_de_guard_wrap()
		avm_de_guard_observe_core_books()
		avm_de_guard_apply()
	end
end)
avm_de_guard_frame:SetScript("OnUpdate", function()
	local now = avm_de_guard_now()
	if now < (AVM_DE_GUARD_RUNTIME.nextTick or 0) then return end
	AVM_DE_GUARD_RUNTIME.nextTick = now + AVM_DE_GUARD_TICK
	avm_de_guard_defaults()
	avm_de_guard_sync_session()
	avm_de_guard_observe_core_books()
	avm_de_guard_apply()
end)
