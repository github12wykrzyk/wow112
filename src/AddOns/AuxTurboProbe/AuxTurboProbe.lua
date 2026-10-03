-- AUX Turbo Probe v1.0
-- Deliberately isolated from AuxFastBridge production code.
-- No permanent wrappers/hooks are installed. A probe run arms exactly one
-- headless full Search through the stable AuxFastBridge v3.7 public helpers.

AuxTurboProbeDB = AuxTurboProbeDB or {}
AuxTurboProbeDB.runs = tonumber(AuxTurboProbeDB.runs) or 0

AUXTURBO_RUNTIME = AUXTURBO_RUNTIME or {
	active = false,
	seenBusy = false,
	startedAt = 0,
	lastPoll = 0,
}

local function out(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffaa33[AUX TURBO PROBE]|r " .. tostring(msg))
	end
end

local function status_snapshot()
	local fast = AUXFAST_Status and AUXFAST_Status() or {}
	return {
		active = AUXTURBO_RUNTIME.active and true or false,
		seenBusy = AUXTURBO_RUNTIME.seenBusy and true or false,
		searchBusy = fast.searchBusy and true or false,
		searchBusyCount = tonumber(fast.searchBusyCount) or 0,
		busy = fast.busy and true or false,
		scanPages = tonumber(fast.scanPages) or 0,
		lastScanPages = tonumber(AuxFastBridgeDB and AuxFastBridgeDB.lastScanPages) or 0,
		lastScanDuration = tonumber(AuxFastBridgeDB and AuxFastBridgeDB.lastScanDuration) or 0,
		lastScanPagesPerSec = tonumber(AuxFastBridgeDB and AuxFastBridgeDB.lastScanPagesPerSec) or 0,
	}
end

function AUXTURBO_Status()
	return status_snapshot()
end

local function finish_probe(reason)
	local now = GetTime and GetTime() or 0
	local duration = AUXTURBO_RUNTIME.startedAt > 0 and (now - AUXTURBO_RUNTIME.startedAt) or 0
	local fastPages = tonumber(AuxFastBridgeDB and AuxFastBridgeDB.lastScanPages) or 0
	local fastDuration = tonumber(AuxFastBridgeDB and AuxFastBridgeDB.lastScanDuration) or 0
	local pps = tonumber(AuxFastBridgeDB and AuxFastBridgeDB.lastScanPagesPerSec) or 0

	AUXTURBO_RUNTIME.active = false
	AUXTURBO_RUNTIME.seenBusy = false
	AUXTURBO_RUNTIME.startedAt = 0
	AUXTURBO_RUNTIME.lastPoll = 0

	AuxTurboProbeDB.lastResult = tostring(reason or "done")
	AuxTurboProbeDB.lastWallDuration = duration
	AuxTurboProbeDB.lastScanPages = fastPages
	AuxTurboProbeDB.lastScanDuration = fastDuration
	AuxTurboProbeDB.lastScanPagesPerSec = pps

	out("done reason=" .. tostring(reason or "done") ..
		" pages=" .. tostring(fastPages) ..
		" scan=" .. string.format("%.3f", fastDuration) .. "s" ..
		" pps=" .. string.format("%.1f", pps))
end

local function clear_probe_arm()
	if AUXFAST_ClearHeadlessArm then
		pcall(AUXFAST_ClearHeadlessArm)
	end
end

local function get_search_runtime()
	local ok, searchTab = pcall(require, "aux.tabs.search")
	if not ok or not searchTab or not searchTab.execute then
		return nil, nil, "aux.tabs.search unavailable"
	end
	local env = getfenv(searchTab.execute)
	if not env then
		return nil, nil, "search runtime unavailable"
	end
	return searchTab, env, nil
end

function AUXTURBO_Run()
	if AUXTURBO_RUNTIME.active then
		out("probe already active")
		return false, "already-active"
	end
	if not AUXFAST_ArmHeadless or not AUXFAST_Status then
		out("AuxFastBridge v3.7 helpers unavailable")
		return false, "auxfast-unavailable"
	end

	local searchTab, env, err = get_search_runtime()
	if not searchTab then
		out(err)
		return false, err
	end

	local search = env.current_search and env.current_search() or nil
	if not search then
		out("current Search unavailable; open AUX Search first")
		return false, "search-unavailable"
	end

	-- One-shot routing only. We set the current Search to the normal full-search
	-- mode for this explicit run, but we do not replace search.execute and do not
	-- alter any AuxFastBridge function.
	search.real_time = false
	if env.update_real_time then
		pcall(env.update_real_time, false)
	end

	AUXFAST_ArmHeadless("turbo-probe")
	AUXTURBO_RUNTIME.active = true
	AUXTURBO_RUNTIME.seenBusy = false
	AUXTURBO_RUNTIME.startedAt = GetTime and GetTime() or 0
	AUXTURBO_RUNTIME.lastPoll = 0
	AuxTurboProbeDB.runs = (tonumber(AuxTurboProbeDB.runs) or 0) + 1
	AuxTurboProbeDB.lastResult = "started"

	local okExec, execErr = pcall(searchTab.execute, false, false)
	if not okExec then
		clear_probe_arm()
		AUXTURBO_RUNTIME.active = false
		AuxTurboProbeDB.lastResult = "execute-error"
		out("execute failed: " .. tostring(execErr))
		return false, tostring(execErr)
	end

	out("started run=" .. tostring(AuxTurboProbeDB.runs) ..
		"; isolated one-shot full Search, no production wrappers")
	return true, "started"
end

local monitor = CreateFrame("Frame", "AuxTurboProbeMonitorFrame")
monitor:SetScript("OnUpdate", function()
	if not AUXTURBO_RUNTIME.active then return end
	local now = GetTime and GetTime() or 0
	if now - (AUXTURBO_RUNTIME.lastPoll or 0) < 0.10 then return end
	AUXTURBO_RUNTIME.lastPoll = now

	local s = status_snapshot()
	if s.searchBusy or s.busy then
		AUXTURBO_RUNTIME.seenBusy = true
		return
	end

	if AUXTURBO_RUNTIME.seenBusy then
		finish_probe("scan-complete")
		return
	end

	-- Fail closed if execute never transitions into a scan. Clear only our pending
	-- one-shot headless arm so the next ordinary AUX Search cannot inherit it.
	if AUXTURBO_RUNTIME.startedAt > 0 and now - AUXTURBO_RUNTIME.startedAt > 3.0 then
		clear_probe_arm()
		finish_probe("scan-not-started")
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
	if msg == "status" then
		local s = status_snapshot()
		out("active=" .. tostring(s.active) ..
			" busy=" .. tostring(s.busy) ..
			" searchBusy=" .. tostring(s.searchBusy) ..
			" pages=" .. tostring(s.lastScanPages) ..
			" duration=" .. string.format("%.3f", s.lastScanDuration) .. "s" ..
			" pps=" .. string.format("%.1f", s.lastScanPagesPerSec))
		return
	end
	out("commands: /auxturbo run | /auxturbo status")
end

out("v1.0 loaded; inert until /auxturbo run")
