-- AuxVmangos DE incident guard v2 overlay.
-- Tightens v1 without touching Vendor/core: history-backed anchors need >=3 AUX
-- data points, and every AUX callback is checked again after core has run.

AVM_DE_INCIDENT_GUARD_V2_VERSION = "2.0"

local AVM_DE_GUARD_V2_SENTINEL = 2147483647
local AVM_DE_GUARD_V2_MIN_HISTORY_POINTS = 3
local AVM_DE_GUARD_V2_HISTORY_OK, AVM_DE_GUARD_V2_HISTORY = pcall(require, "aux.core.history")
local AVM_DE_GUARD_V2 = { wrapped = false, nextTick = 0, original = {} }

local function avm_de_guard_v2_log(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff9000[AVM-DE-GUARD-V2]|r " .. tostring(msg))
	end
	if AVM_DB then
		AVM_DB.diag = AVM_DB.diag or { seq = 0, events = {}, state = {} }
		AVM_DB.diag.events = AVM_DB.diag.events or {}
		AVM_DB.diag.seq = (tonumber(AVM_DB.diag.seq) or 0) + 1
		table.insert(AVM_DB.diag.events,
			tostring(AVM_DB.diag.seq) .. "@" .. tostring(math.floor((GetTime() or 0) * 1000)) ..
			" DE_GUARD_V2 " .. tostring(msg))
		while table.getn(AVM_DB.diag.events) > 80 do table.remove(AVM_DB.diag.events, 1) end
	end
end

local function avm_de_guard_v2_history_points(key)
	if not key or key == "" or not AVM_DE_GUARD_V2_HISTORY_OK or not AVM_DE_GUARD_V2_HISTORY or
	   type(AVM_DE_GUARD_V2_HISTORY.data_points) ~= "function" then return 0 end
	local ok, points = pcall(AVM_DE_GUARD_V2_HISTORY.data_points, key)
	if not ok or type(points) ~= "table" then return 0 end
	return table.getn(points)
end

local function avm_de_guard_v2_block(reason)
	if not AVM_DB then return false end
	local g = AVM_DB.deIncidentGuard
	if type(g) ~= "table" then return false end
	local changed = not g.tripped or tostring(g.tripReason or "") ~= tostring(reason or "v2-block")
	g.tripped = true
	g.tripReason = tostring(reason or "v2-block")
	g.lastReason = g.tripReason
	g.gateApplied = true
	AVM_DB.deMinProfit = AVM_DE_GUARD_V2_SENTINEL
	AVM_DB.bidDeEnabled = false
	if changed then avm_de_guard_v2_log("BLOCK reason=" .. g.tripReason) end
	return false
end

local function avm_de_guard_v2_candidate()
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

local function avm_de_guard_v2_check_anchor(itemId)
	if not AVM_DB or type(AVM_DB.deIncidentGuard) ~= "table" then return true end
	local g = AVM_DB.deIncidentGuard
	local t = g.trusted and g.trusted[tonumber(itemId)] or nil
	if type(t) ~= "table" or (tonumber(t.anchor) or 0) <= 0 then
		return avm_de_guard_v2_block("history-missing:" .. tostring(itemId))
	end
	if tostring(t.anchorSource or "") == "aux-history" then
		local n = avm_de_guard_v2_history_points(t.historyKey)
		t.historyPoints = n
		if n < AVM_DE_GUARD_V2_MIN_HISTORY_POINTS then
			return avm_de_guard_v2_block("history-too-short:" .. tostring(itemId) .. ":n=" .. tostring(n))
		end
	end
	if t.quarantined then
		return avm_de_guard_v2_block(tostring(t.reason or "quarantine") .. ":" .. tostring(itemId))
	end
	return true
end

local function avm_de_guard_v2_check()
	if not AVM_DB or type(AVM_DB.deIncidentGuard) ~= "table" then return true end
	local g = AVM_DB.deIncidentGuard
	if not g.armed then return true end

	-- Validate every already-observed trusted material. This catches a warm/exact
	-- material shock even before a DE candidate reaches final revalidation.
	for itemId, t in pairs(g.trusted or {}) do
		if type(t) == "table" and (tonumber(t.anchor) or 0) > 0 then
			if not avm_de_guard_v2_check_anchor(itemId) then return false end
		end
	end

	-- Candidate-specific fail closed: every material used by the DE model must
	-- have a sufficiently-supported non-quarantined anchor.
	local c = avm_de_guard_v2_candidate()
	if c then
		for i = 1, table.getn(c.materials or {}) do
			local itemId = tonumber(c.materials[i] and c.materials[i].itemId)
			if itemId and not avm_de_guard_v2_check_anchor(itemId) then return false end
		end
	end
	return true
end

local function avm_de_guard_v2_wrap()
	if AVM_DE_GUARD_V2.wrapped then return end

	if type(AVM_AuxArbScanStart) == "function" then
		AVM_DE_GUARD_V2.original.ScanStart = AVM_AuxArbScanStart
		AVM_AuxArbScanStart = function(resume, filterString)
			avm_de_guard_v2_check()
			local result = AVM_DE_GUARD_V2.original.ScanStart(resume, filterString)
			avm_de_guard_v2_check()
			return result
		end
	end
	if type(AVM_AuxArbAuction) == "function" then
		AVM_DE_GUARD_V2.original.Auction = AVM_AuxArbAuction
		AVM_AuxArbAuction = function(record)
			avm_de_guard_v2_check()
			local result = AVM_DE_GUARD_V2.original.Auction(record)
			avm_de_guard_v2_check()
			return result
		end
	end
	if type(AVM_AuxArbPageDone) == "function" then
		AVM_DE_GUARD_V2.original.PageDone = AVM_AuxArbPageDone
		AVM_AuxArbPageDone = function(page, lastPage)
			avm_de_guard_v2_check()
			local result = AVM_DE_GUARD_V2.original.PageDone(page, lastPage)
			avm_de_guard_v2_check()
			return result
		end
	end
	if type(AVM_AuxArbScanDone) == "function" then
		AVM_DE_GUARD_V2.original.ScanDone = AVM_AuxArbScanDone
		AVM_AuxArbScanDone = function()
			avm_de_guard_v2_check()
			local result = AVM_DE_GUARD_V2.original.ScanDone()
			avm_de_guard_v2_check()
			return result
		end
	end

	-- V1 owns /avmde. Recheck immediately after ARM/RESET so an unsupported
	-- historical anchor can never remain open until the next OnUpdate tick.
	if SlashCmdList and type(SlashCmdList["AVMDEGUARD"]) == "function" then
		AVM_DE_GUARD_V2.original.Slash = SlashCmdList["AVMDEGUARD"]
		SlashCmdList["AVMDEGUARD"] = function(msg)
			local result = AVM_DE_GUARD_V2.original.Slash(msg)
			avm_de_guard_v2_check()
			return result
		end
	end
	AVM_DE_GUARD_V2.wrapped = true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
	if (event == "ADDON_LOADED" and arg1 == "AuxVmangos") or event == "PLAYER_LOGIN" then
		avm_de_guard_v2_wrap()
		avm_de_guard_v2_check()
	end
end)
frame:SetScript("OnUpdate", function()
	local now = tonumber(GetTime()) or 0
	if now < (AVM_DE_GUARD_V2.nextTick or 0) then return end
	AVM_DE_GUARD_V2.nextTick = now + 0.05
	avm_de_guard_v2_check()
end)
