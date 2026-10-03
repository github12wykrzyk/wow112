-- AUX Turbo Probe v2.0
-- Completely separate raw AH throughput probe.
-- It does not call aux.core.scan, search.execute, AUXFAST_ResumeSearch or AVM buying.
-- AuxFastBridge is used read-only for the verified native 0x025C sequence counter.

AuxTurboProbeDB = AuxTurboProbeDB or {}
AuxTurboProbeDB.runs = tonumber(AuxTurboProbeDB.runs) or 0

AUXTURBO_RUNTIME = AUXTURBO_RUNTIME or {}

local MAX_PAGE = 2000
local RESPONSE_TIMEOUT = 2.0

local function out(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffaa33[AUX TURBO PROBE]|r " .. tostring(msg))
	end
end

local function reset_runtime()
	AUXTURBO_RUNTIME.active = false
	AUXTURBO_RUNTIME.phase = "idle"
	AUXTURBO_RUNTIME.page = 0
	AUXTURBO_RUNTIME.sent = 0
	AUXTURBO_RUNTIME.received = 0
	AUXTURBO_RUNTIME.expectedSeq = 0
	AUXTURBO_RUNTIME.sentAt = 0
	AUXTURBO_RUNTIME.startedAt = 0
	AUXTURBO_RUNTIME.total = 0
	AUXTURBO_RUNTIME.lastPage = -1
	AUXTURBO_RUNTIME.samples = {}
	AUXTURBO_RUNTIME.browseDetached = false
	AUXTURBO_RUNTIME.stopReason = ""
end

if AUXTURBO_RUNTIME.active == nil then reset_runtime() end

local function fast_status()
	if not AUXFAST_Status then return nil end
	local ok, s = pcall(AUXFAST_Status)
	if not ok or type(s) ~= "table" then return nil end
	return s
end

local function avm_busy()
	if not AVM then return false end
	local arb = AVM.auxArb or {}
	return AVM.queryInFlight or AVM.pending or AVM.unknown or AVM.candidate or
		(AVM.market and (AVM.market.active or AVM.market.requested)) or
		(AVM.vendor and (AVM.vendor.active or AVM.vendor.requested)) or
		arb.deVerify or arb.flipVerify or arb.postscanCandidate or arb.paused or arb.pausePending
end

local function detach_browse()
	if AUXTURBO_RUNTIME.browseDetached then return end
	if AuctionFrameBrowse and AuctionFrameBrowse.UnregisterEvent then
		AuctionFrameBrowse:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
		AUXTURBO_RUNTIME.browseDetached = true
	end
end

local function restore_browse()
	if not AUXTURBO_RUNTIME.browseDetached then return end
	if AuctionFrameBrowse and AuctionFrameBrowse.RegisterEvent then
		AuctionFrameBrowse:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
	end
	AUXTURBO_RUNTIME.browseDetached = false
end

local function percentile(samples, fraction)
	local n = table.getn(samples)
	if n < 1 then return 0 end
	local copy = {}
	local i
	for i = 1, n do copy[i] = samples[i] end
	table.sort(copy)
	local idx = math.floor((n - 1) * fraction + 1.5)
	if idx < 1 then idx = 1 end
	if idx > n then idx = n end
	return tonumber(copy[idx]) or 0
end

local function finish(reason)
	if not AUXTURBO_RUNTIME.active then return end
	local now = GetTime and GetTime() or 0
	local duration = AUXTURBO_RUNTIME.startedAt > 0 and (now - AUXTURBO_RUNTIME.startedAt) or 0
	local pages = tonumber(AUXTURBO_RUNTIME.received) or 0
	local pps = duration > 0 and pages / duration or 0
	local wallMs = pages > 0 and duration * 1000 / pages or 0
	local samples = AUXTURBO_RUNTIME.samples or {}
	local sum, minMs, maxMs = 0, 0, 0
	local i
	for i = 1, table.getn(samples) do
		local v = tonumber(samples[i]) or 0
		sum = sum + v
		if minMs == 0 or v < minMs then minMs = v end
		if v > maxMs then maxMs = v end
	end
	local responseAvg = table.getn(samples) > 0 and sum / table.getn(samples) or 0
	local p50 = percentile(samples, 0.50)
	local p95 = percentile(samples, 0.95)

	restore_browse()
	AUXTURBO_RUNTIME.active = false
	AUXTURBO_RUNTIME.phase = "idle"
	AUXTURBO_RUNTIME.stopReason = tostring(reason or "done")

	AuxTurboProbeDB.lastResult = AUXTURBO_RUNTIME.stopReason
	AuxTurboProbeDB.lastPages = pages
	AuxTurboProbeDB.lastDuration = duration
	AuxTurboProbeDB.lastPagesPerSec = pps
	AuxTurboProbeDB.lastWallMsPerPage = wallMs
	AuxTurboProbeDB.lastResponseAvgMs = responseAvg
	AuxTurboProbeDB.lastResponseP50Ms = p50
	AuxTurboProbeDB.lastResponseP95Ms = p95
	AuxTurboProbeDB.lastTotal = AUXTURBO_RUNTIME.total or 0

	out("done reason=" .. AUXTURBO_RUNTIME.stopReason ..
		" pages=" .. tostring(pages) ..
		" total=" .. tostring(AUXTURBO_RUNTIME.total or 0) ..
		" time=" .. string.format("%.3f", duration) .. "s" ..
		" pps=" .. string.format("%.1f", pps) ..
		" wall=" .. string.format("%.1f", wallMs) .. "ms/page" ..
		" rxAvg=" .. string.format("%.1f", responseAvg) .. "ms" ..
		" p50=" .. string.format("%.1f", p50) .. "ms" ..
		" p95=" .. string.format("%.1f", p95) .. "ms")
end

local function gate_ready()
	if not CanSendAuctionQuery then return true end
	local ok, ready = pcall(CanSendAuctionQuery)
	if not ok then return false end
	return ready and true or false
end

local function send_page()
	if not AUXTURBO_RUNTIME.active or AUXTURBO_RUNTIME.phase ~= "gate" then return end
	if not gate_ready() then return end
	local s = fast_status()
	if not s then finish("NO_NATIVE_STATUS") return end

	local page = tonumber(AUXTURBO_RUNTIME.page) or 0
	AUXTURBO_RUNTIME.expectedSeq = tonumber(s.nativeSeq) or 0
	AUXTURBO_RUNTIME.sentAt = GetTime and GetTime() or 0
	AUXTURBO_RUNTIME.phase = "response"
	AUXTURBO_RUNTIME.sent = (tonumber(AUXTURBO_RUNTIME.sent) or 0) + 1

	local ok, err = pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, page, false, 0, false)
	if not ok then
		finish("QUERY_ERROR:" .. tostring(err))
	end
end

local function response_ready()
	local s = fast_status()
	if not s then return false, nil end
	local seq = tonumber(s.nativeSeq) or 0
	local page = tonumber(AUXTURBO_RUNTIME.page) or 0
	local nativePage = tonumber(s.nativeLastStockPage) or -1
	if seq > (tonumber(AUXTURBO_RUNTIME.expectedSeq) or 0) and nativePage == page then
		return true, s
	end
	return false, s
end

local function accept_response()
	local now = GetTime and GetTime() or 0
	local elapsedMs = AUXTURBO_RUNTIME.sentAt > 0 and (now - AUXTURBO_RUNTIME.sentAt) * 1000 or 0
	table.insert(AUXTURBO_RUNTIME.samples, elapsedMs)
	AUXTURBO_RUNTIME.received = (tonumber(AUXTURBO_RUNTIME.received) or 0) + 1

	local rows, total = GetNumAuctionItems("list")
	rows = tonumber(rows) or 0
	total = tonumber(total) or 0
	AUXTURBO_RUNTIME.total = total
	local lastPage = total > 0 and math.floor((total - 1) / 50) or 0
	AUXTURBO_RUNTIME.lastPage = lastPage

	local page = tonumber(AUXTURBO_RUNTIME.page) or 0
	if rows < 50 or page >= lastPage or page >= MAX_PAGE then
		finish(rows < 50 and "COMPLETE_SHORT_PAGE" or (page >= lastPage and "COMPLETE" or "MAX_PAGE"))
		return
	end

	AUXTURBO_RUNTIME.page = page + 1
	AUXTURBO_RUNTIME.phase = "gate"
end

function AUXTURBO_Run()
	if AUXTURBO_RUNTIME.active then
		out("raw probe already active")
		return false, "already-active"
	end
	local s = fast_status()
	if not s then
		out("verified native AUX status unavailable")
		return false, "native-status-unavailable"
	end
	if s.busy or s.searchBusy or avm_busy() then
		out("blocked: AUX/AVM is busy; finish current AH work first")
		return false, "ah-busy"
	end
	if tonumber(s.nativeCooldownMs) ~= 25 or not s.nativeCooldownPatched then
		out("blocked: native 25ms cooldown patch not confirmed (cooldown=" .. tostring(s.nativeCooldownMs) .. ")")
		return false, "native-25ms-unconfirmed"
	end

	reset_runtime()
	AUXTURBO_RUNTIME.active = true
	AUXTURBO_RUNTIME.phase = "gate"
	AUXTURBO_RUNTIME.startedAt = GetTime and GetTime() or 0
	AuxTurboProbeDB.runs = (tonumber(AuxTurboProbeDB.runs) or 0) + 1
	AuxTurboProbeDB.lastResult = "running"
	detach_browse()

	out("RAW run=" .. tostring(AuxTurboProbeDB.runs) ..
		" started; page-by-page native-correlated scan, AUX Search/AVM untouched")
	return true, "started"
end

function AUXTURBO_Stop()
	if not AUXTURBO_RUNTIME.active then return false end
	finish("USER_STOP")
	return true
end

function AUXTURBO_Status()
	local now = GetTime and GetTime() or 0
	local duration = AUXTURBO_RUNTIME.active and AUXTURBO_RUNTIME.startedAt > 0 and (now - AUXTURBO_RUNTIME.startedAt) or (tonumber(AuxTurboProbeDB.lastDuration) or 0)
	local pages = AUXTURBO_RUNTIME.active and (tonumber(AUXTURBO_RUNTIME.received) or 0) or (tonumber(AuxTurboProbeDB.lastPages) or 0)
	return {
		active = AUXTURBO_RUNTIME.active and true or false,
		phase = AUXTURBO_RUNTIME.phase or "idle",
		page = tonumber(AUXTURBO_RUNTIME.page) or 0,
		pages = pages,
		duration = duration,
		pps = duration > 0 and pages / duration or 0,
		wallMs = pages > 0 and duration * 1000 / pages or 0,
		lastResult = AuxTurboProbeDB.lastResult or "none",
	}
end

local monitor = CreateFrame("Frame", "AuxTurboProbeMonitorFrame")
monitor:SetScript("OnUpdate", function()
	if not AUXTURBO_RUNTIME.active then return end
	if AUXTURBO_RUNTIME.phase == "gate" then
		send_page()
		return
	end
	if AUXTURBO_RUNTIME.phase == "response" then
		local ready = response_ready()
		if ready then
			accept_response()
			return
		end
		local now = GetTime and GetTime() or 0
		if AUXTURBO_RUNTIME.sentAt > 0 and now - AUXTURBO_RUNTIME.sentAt >= RESPONSE_TIMEOUT then
			finish("PAGE_TIMEOUT_" .. tostring(AUXTURBO_RUNTIME.page or 0))
		end
	end
end)

SLASH_AUXTURBOPROBE1 = "/auxturbo"
SLASH_AUXTURBOPROBE2 = "/atp"
SlashCmdList.AUXTURBOPROBE = function(msg)
	msg = string.lower(tostring(msg or ""))
	if msg == "run" or msg == "start" or msg == "go" or msg == "" then
		AUXTURBO_Run()
		return
	end
	if msg == "stop" then
		AUXTURBO_Stop()
		return
	end
	if msg == "status" then
		local s = AUXTURBO_Status()
		out("active=" .. tostring(s.active) ..
			" phase=" .. tostring(s.phase) ..
			" page=" .. tostring(s.page) ..
			" pages=" .. tostring(s.pages) ..
			" time=" .. string.format("%.3f", s.duration) .. "s" ..
			" pps=" .. string.format("%.1f", s.pps) ..
			" wall=" .. string.format("%.1f", s.wallMs) .. "ms/page" ..
			" result=" .. tostring(s.lastResult))
		return
	end
	out("commands: /atp run | /atp status | /atp stop")
end

out("v2.0 loaded; inert until /atp run; raw scanner does not drive AUX Search")
